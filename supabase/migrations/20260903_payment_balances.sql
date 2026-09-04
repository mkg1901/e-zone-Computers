-- Apply after the earlier migrations. No balances/history are rewritten.
-- Prevent negative CURRENT balances, including edits/deletes and opening changes.
begin;

-- One private row serializes balance-changing transactions across devices.
create table if not exists public.ezr_balance_guard (
  id boolean primary key default true check (id),
  revision bigint not null default 0
);
insert into public.ezr_balance_guard(id) values (true) on conflict do nothing;
alter table public.ezr_balance_guard enable row level security;
revoke all on public.ezr_balance_guard from public, anon, authenticated;

create or replace function public.ezr_lock_balances() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  update public.ezr_balance_guard set revision = revision + 1 where id = true;
  return null;
end;
$$;
revoke all on function public.ezr_lock_balances() from public, anon, authenticated;

-- Definer access is read-only here, to count ALL ledger rows irrespective of RLS.
-- Actual writes still run under the caller's existing table policies.
create or replace function public.ezr_check_balances() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  opening numeric;
  current_cash numeric;
  bad_bank text;
begin
  select coalesce((select value::numeric from public.settings where key='cash_opening'),0) into opening;
  select opening + coalesce(sum(amount),0) into current_cash from public.ledger where mode='Cash';
  if opening < 0 or current_cash < 0 or opening::text in ('NaN','Infinity','-Infinity') or current_cash::text in ('NaN','Infinity','-Infinity') then
    raise exception 'Insufficient cash balance. This change would make cash negative.';
  end if;
  select b.name into bad_bank from public.banks b
    left join public.ledger l on l.bank_id=b.id and l.mode='Bank'
    group by b.id,b.name,b.opening_balance
    having coalesce(b.opening_balance,0)<0
      or coalesce(b.opening_balance,0)+coalesce(sum(l.amount),0)<0
      or (coalesce(b.opening_balance,0)+coalesce(sum(l.amount),0))::text in ('NaN','Infinity','-Infinity')
    limit 1;
  if found then
    raise exception 'Insufficient bank balance in %. This change would make the balance negative.',bad_bank;
  end if;
  if exists(select 1 from public.ledger l where l.mode='Bank' and not exists(select 1 from public.banks b where b.id=l.bank_id)) then
    raise exception 'Bank ledger entries must reference an existing bank account.';
  end if;
  return null;
end;
$$;
revoke all on function public.ezr_check_balances() from public, anon, authenticated;

-- Deferred checks allow atomic replacements/transfers to validate their final state.
drop trigger if exists ezr_lock_balances on public.ledger;
create trigger ezr_lock_balances before insert or update or delete on public.ledger
  for each statement execute function public.ezr_lock_balances();
drop trigger if exists ezr_check_balances on public.ledger;
create constraint trigger ezr_check_balances after insert or update or delete on public.ledger
  deferrable initially deferred for each row execute function public.ezr_check_balances();
drop trigger if exists ezr_lock_balances on public.banks;
create trigger ezr_lock_balances before insert or update or delete on public.banks
  for each statement execute function public.ezr_lock_balances();
drop trigger if exists ezr_check_balances on public.banks;
create constraint trigger ezr_check_balances after insert or update or delete on public.banks
  deferrable initially deferred for each row execute function public.ezr_check_balances();
drop trigger if exists ezr_lock_balances on public.settings;
create trigger ezr_lock_balances before insert or update or delete on public.settings
  for each statement execute function public.ezr_lock_balances();
drop trigger if exists ezr_check_balances on public.settings;
create constraint trigger ezr_check_balances after insert or update or delete on public.settings
  deferrable initially deferred for each row execute function public.ezr_check_balances();

create or replace function public.replace_reference_ledger(p_ref_type text,p_ref_id text,p_entry jsonb)
returns void language plpgsql security invoker set search_path=public as $$
declare movement public.ledger%rowtype;
begin
  if auth.uid() is null or p_ref_type not in ('sale','purchase','expense') or nullif(p_ref_id,'') is null then
    raise exception 'Invalid payment reference.';
  end if;
  if p_entry is not null then
    movement:=jsonb_populate_record(null::public.ledger,p_entry);
    if movement.ref_type is distinct from p_ref_type or movement.ref_id::text is distinct from p_ref_id
       or movement.created_by is distinct from auth.uid() then raise exception 'Invalid payment details.'; end if;
  end if;
  delete from public.ledger where ref_type=p_ref_type and ref_id::text=p_ref_id;
  if p_entry is not null then
    insert into public.ledger(date,type,mode,bank_id,amount,ref_type,ref_id,note,created_by,created_by_name)
    values(movement.date,movement.type,movement.mode,movement.bank_id,movement.amount,movement.ref_type,movement.ref_id,movement.note,movement.created_by,movement.created_by_name);
  end if;
end;
$$;
revoke all on function public.replace_reference_ledger(text,text,jsonb) from public;
grant execute on function public.replace_reference_ledger(text,text,jsonb) to authenticated;

-- Internal request IDs prevent duplicate transfer pairs if the same form is retried.
create table if not exists public.cash_bank_transfers (
  id uuid primary key,
  bank_id text not null,
  amount numeric(14,2) not null check(amount>0),
  date date not null,
  note text not null default '',
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);
alter table public.cash_bank_transfers enable row level security;
drop policy if exists "transfer read own or admin" on public.cash_bank_transfers;
create policy "transfer read own or admin" on public.cash_bank_transfers for select to authenticated
  using(created_by=auth.uid() or public.is_admin());
drop policy if exists "transfer insert own" on public.cash_bank_transfers;
create policy "transfer insert own" on public.cash_bank_transfers for insert to authenticated
  with check(created_by=auth.uid() and exists(select 1 from public.profiles where id=auth.uid() and role in ('Admin','Staff')));
revoke all on public.cash_bank_transfers from public,anon,authenticated;
grant select,insert on public.cash_bank_transfers to authenticated;

create or replace function public.transfer_cash_to_bank(p_request_id uuid,p_bank_id text,p_amount numeric,p_date date,p_note text default '')
returns uuid language plpgsql security invoker set search_path=public as $$
declare
  actor public.profiles%rowtype;
  destination public.banks%rowtype;
  existing public.cash_bank_transfers%rowtype;
  outgoing public.ledger%rowtype;
  incoming public.ledger%rowtype;
  claimed uuid;
begin
  select * into actor from public.profiles where id=auth.uid();
  if not found or actor.role not in ('Admin','Staff') then raise exception 'Staff or Admin login is required.'; end if;
  if p_request_id is null or p_amount is null or p_amount<=0 or p_amount::text in ('NaN','Infinity','-Infinity')
     or p_amount<>round(p_amount,2) or p_date is null or p_date>(now() at time zone 'Asia/Kolkata')::date then
    raise exception 'Enter a positive amount with at most two decimals and a valid date.';
  end if;
  select * into destination from public.banks where id::text=p_bank_id;
  if not found then raise exception 'Select an existing bank account.'; end if;
  insert into public.cash_bank_transfers(id,bank_id,amount,date,note,created_by)
    values(p_request_id,p_bank_id,p_amount,p_date,coalesce(p_note,''),actor.id)
    on conflict(id) do nothing returning id into claimed;
  if claimed is null then
    select * into existing from public.cash_bank_transfers where id=p_request_id;
    if not found or existing.created_by is distinct from actor.id or existing.bank_id is distinct from p_bank_id
       or existing.amount is distinct from p_amount or existing.date is distinct from p_date or existing.note is distinct from coalesce(p_note,'') then
      raise exception 'This transfer request already has different details. Reopen the transfer form.';
    end if;
    return p_request_id;
  end if;
  -- Existing supported ledger types/ref type; notes identify both transfer sides.
  outgoing:=jsonb_populate_record(null::public.ledger,jsonb_build_object('date',p_date,'type','Payment','mode','Cash','bank_id',null,'amount',-p_amount,'ref_type','manual','ref_id',p_request_id::text,'note','Cash to bank transfer - '||destination.name||' - '||coalesce(p_note,''),'created_by',actor.id,'created_by_name',actor.full_name));
  incoming:=jsonb_populate_record(null::public.ledger,jsonb_build_object('date',p_date,'type','Payment Received','mode','Bank','bank_id',destination.id,'amount',p_amount,'ref_type','manual','ref_id',p_request_id::text,'note','Cash to bank transfer - '||destination.name||' - '||coalesce(p_note,''),'created_by',actor.id,'created_by_name',actor.full_name));
  insert into public.ledger(date,type,mode,bank_id,amount,ref_type,ref_id,note,created_by,created_by_name)
    values(outgoing.date,outgoing.type,outgoing.mode,outgoing.bank_id,outgoing.amount,outgoing.ref_type,outgoing.ref_id,outgoing.note,outgoing.created_by,outgoing.created_by_name),
          (incoming.date,incoming.type,incoming.mode,incoming.bank_id,incoming.amount,incoming.ref_type,incoming.ref_id,incoming.note,incoming.created_by,incoming.created_by_name);
  return p_request_id;
end;
$$;
revoke all on function public.transfer_cash_to_bank(uuid,text,numeric,date,text) from public;
grant execute on function public.transfer_cash_to_bank(uuid,text,numeric,date,text) to authenticated;
notify pgrst,'reload schema';
commit;
