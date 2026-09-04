-- Apply AFTER 20260903_payment_balances.sql. Existing transfers retain their direction.
begin;
alter table public.cash_bank_transfers add column if not exists direction text not null default 'cash_to_bank';
do $$ begin
 if not exists(select 1 from pg_constraint where conrelid='public.cash_bank_transfers'::regclass and conname='cash_bank_transfers_direction_check') then
  alter table public.cash_bank_transfers add constraint cash_bank_transfers_direction_check check(direction in ('cash_to_bank','bank_to_cash'));
 end if;
end; $$;
create or replace function public.transfer_cash_bank(p_request_id uuid,p_bank_id text,p_amount numeric,p_date date,p_direction text,p_note text default '')
returns uuid language plpgsql security invoker set search_path=public as $$
declare
  actor public.profiles%rowtype;
  destination public.banks%rowtype;
  existing public.cash_bank_transfers%rowtype;
  outgoing public.ledger%rowtype;
  incoming public.ledger%rowtype;
  claimed uuid;
begin
  if p_direction is null or p_direction not in ('cash_to_bank','bank_to_cash') then raise exception 'Select a valid transfer direction.'; end if;
  select * into actor from public.profiles where id=auth.uid();
  if not found or actor.role not in ('Admin','Staff') then raise exception 'Staff or Admin login is required.'; end if;
  if p_request_id is null or p_amount is null or p_amount<=0 or p_amount::text in ('NaN','Infinity','-Infinity')
     or p_amount<>round(p_amount,2) or p_date is null or p_date>(now() at time zone 'Asia/Kolkata')::date then
    raise exception 'Enter a positive amount with at most two decimals and a valid date.';
  end if;
  select * into destination from public.banks where id::text=p_bank_id;
  if not found then raise exception 'Select an existing bank account.'; end if;
  insert into public.cash_bank_transfers(id,bank_id,amount,date,note,created_by,direction)
    values(p_request_id,p_bank_id,p_amount,p_date,coalesce(p_note,''),actor.id,p_direction)
    on conflict(id) do nothing returning id into claimed;
  if claimed is null then
    select * into existing from public.cash_bank_transfers where id=p_request_id;
    if not found or existing.created_by is distinct from actor.id or existing.bank_id is distinct from p_bank_id
       or existing.direction is distinct from p_direction or existing.amount is distinct from p_amount or existing.date is distinct from p_date or existing.note is distinct from coalesce(p_note,'') then
      raise exception 'This transfer request already has different details. Reopen the transfer form.';
    end if;
    return p_request_id;
  end if;
  -- Existing supported ledger types/ref type; notes identify both transfer sides.
  outgoing:=jsonb_populate_record(null::public.ledger,jsonb_build_object('date',p_date,'type','Payment','mode',case when p_direction='cash_to_bank' then 'Cash' else 'Bank' end,'bank_id',case when p_direction='bank_to_cash' then destination.id else null end,'amount',-p_amount,'ref_type','manual','ref_id',p_request_id::text,'note',(case when p_direction='cash_to_bank' then 'Cash to bank transfer - ' else 'Bank to cash transfer - ' end)||destination.name||' - '||coalesce(p_note,''),'created_by',actor.id,'created_by_name',actor.full_name));
  incoming:=jsonb_populate_record(null::public.ledger,jsonb_build_object('date',p_date,'type','Payment Received','mode',case when p_direction='cash_to_bank' then 'Bank' else 'Cash' end,'bank_id',case when p_direction='cash_to_bank' then destination.id else null end,'amount',p_amount,'ref_type','manual','ref_id',p_request_id::text,'note',(case when p_direction='cash_to_bank' then 'Cash to bank transfer - ' else 'Bank to cash transfer - ' end)||destination.name||' - '||coalesce(p_note,''),'created_by',actor.id,'created_by_name',actor.full_name));
  insert into public.ledger(date,type,mode,bank_id,amount,ref_type,ref_id,note,created_by,created_by_name)
    values(outgoing.date,outgoing.type,outgoing.mode,outgoing.bank_id,outgoing.amount,outgoing.ref_type,outgoing.ref_id,outgoing.note,outgoing.created_by,outgoing.created_by_name),
          (incoming.date,incoming.type,incoming.mode,incoming.bank_id,incoming.amount,incoming.ref_type,incoming.ref_id,incoming.note,incoming.created_by,incoming.created_by_name);
  return p_request_id;
end;
$$;

revoke all on function public.transfer_cash_bank(uuid,text,numeric,date,text,text) from public;
grant execute on function public.transfer_cash_bank(uuid,text,numeric,date,text,text) to authenticated;

-- Preserve the existing API while sharing validation and atomic ledger writes.
create or replace function public.transfer_cash_to_bank(p_request_id uuid,p_bank_id text,p_amount numeric,p_date date,p_note text default '')
returns uuid language sql security invoker set search_path=public as $$
 select public.transfer_cash_bank(p_request_id,p_bank_id,p_amount,p_date,'cash_to_bank',p_note);
$$;
create or replace function public.transfer_bank_to_cash(p_request_id uuid,p_bank_id text,p_amount numeric,p_date date,p_note text default '')
returns uuid language sql security invoker set search_path=public as $$
 select public.transfer_cash_bank(p_request_id,p_bank_id,p_amount,p_date,'bank_to_cash',p_note);
$$;
revoke all on function public.transfer_cash_to_bank(uuid,text,numeric,date,text) from public;
revoke all on function public.transfer_bank_to_cash(uuid,text,numeric,date,text) from public;
grant execute on function public.transfer_cash_to_bank(uuid,text,numeric,date,text) to authenticated;
grant execute on function public.transfer_bank_to_cash(uuid,text,numeric,date,text) to authenticated;
notify pgrst,'reload schema';
commit;
