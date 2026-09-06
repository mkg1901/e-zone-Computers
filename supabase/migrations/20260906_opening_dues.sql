-- Adds carry-forward dues without creating sales, purchases, stock or account entries.
-- Apply after 20260903_person_due_payments.sql.
begin;

create table if not exists public.opening_dues (
 id uuid primary key,
 party_kind text not null check (party_kind in ('customer','seller')),
 party_id text not null,
 party_name text not null,
 amount numeric(14,2) not null check (amount>0),
 paid_amount numeric(14,2) not null default 0 check (paid_amount>=0 and paid_amount<=amount),
 date date not null,
 note text not null default '',
 created_by uuid not null references public.profiles(id),
 created_by_name text not null default '',
 created_at timestamptz not null default now()
);
create index if not exists opening_dues_party_idx on public.opening_dues(party_kind,party_id,date,id);
alter table public.opening_dues enable row level security;

drop policy if exists opening_dues_select_staff on public.opening_dues;
create policy opening_dues_select_staff on public.opening_dues for select to authenticated using (
 exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in ('Admin','Staff'))
);
drop policy if exists opening_dues_insert_admin on public.opening_dues;
create policy opening_dues_insert_admin on public.opening_dues for insert to authenticated with check (
 created_by=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='Admin')
);
drop policy if exists opening_dues_update_staff on public.opening_dues;
create policy opening_dues_update_staff on public.opening_dues for update to authenticated using (
 exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in ('Admin','Staff'))
) with check (
 exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in ('Admin','Staff'))
);
drop policy if exists opening_dues_delete_admin on public.opening_dues;
create policy opening_dues_delete_admin on public.opening_dues for delete to authenticated using (
 exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='Admin')
);

create or replace function public.create_opening_due(p_id uuid,p_party_kind text,p_party_id text,p_amount numeric,p_date date,p_note text default '')
returns void language plpgsql security invoker set search_path=public as $$
declare actor public.profiles%rowtype; person_name text;
begin
 select * into actor from public.profiles where id=auth.uid();
 if not found or actor.role<>'Admin' then raise exception 'Only an Admin can add an opening due.'; end if;
 if p_id is null or p_party_kind not in ('customer','seller') or nullif(btrim(p_party_id),'') is null then raise exception 'Select an existing customer or seller.'; end if;
 if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_amount::text in ('NaN','Infinity','-Infinity') then raise exception 'Enter a positive amount with at most two decimal places.'; end if;
 if p_date is null or p_date>(now() at time zone 'Asia/Kolkata')::date then raise exception 'Future dates are not allowed.'; end if;
 if p_party_kind='customer' then select name into person_name from public.customers where id::text=p_party_id;
 else select name into person_name from public.sellers where id::text=p_party_id; end if;
 if not found then raise exception 'The selected person no longer exists.'; end if;
 insert into public.opening_dues(id,party_kind,party_id,party_name,amount,date,note,created_by,created_by_name)
 values(p_id,p_party_kind,p_party_id,person_name,p_amount,p_date,coalesce(btrim(p_note),''),actor.id,actor.full_name)
 on conflict(id) do nothing;
end;
$$;
revoke all on function public.create_opening_due(uuid,text,text,numeric,date,text) from public;
grant execute on function public.create_opening_due(uuid,text,text,numeric,date,text) to authenticated;

create or replace function public.pay_person_outstanding_due(
 p_request_id uuid,p_party_kind text,p_party_id text,p_amount numeric,p_date date,p_mode text,p_bank_id text default null
) returns void language plpgsql security invoker set search_path=public as $$
declare
 actor public.profiles%rowtype; bank public.banks%rowtype; prior public.person_due_payments%rowtype;
 item record; remaining numeric; outstanding numeric:=0; portion numeric; affected integer; person_name text;
begin
 select * into actor from public.profiles where id=auth.uid();
 if not found then raise exception 'Sign in before recording a payment.'; end if;
 if p_request_id is null or p_party_kind not in ('customer','seller') or nullif(btrim(p_party_id),'') is null then raise exception 'Invalid person payment reference.'; end if;
 if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_amount::text in ('NaN','Infinity','-Infinity') then raise exception 'Enter a positive amount with at most two decimal places.'; end if;
 if p_date is null or p_date>(now() at time zone 'Asia/Kolkata')::date then raise exception 'Future dates are not allowed.'; end if;
 if p_mode not in ('Cash','Online') then raise exception 'Select Cash or Online.'; end if;
 if p_mode='Online' then select * into bank from public.banks where id::text=p_bank_id; if not found then raise exception 'Select an existing bank account.'; end if;
 else p_bank_id:=null; end if;
 perform pg_advisory_xact_lock(hashtext(p_request_id::text));
 select * into prior from public.person_due_payments where request_id=p_request_id;
 if found then
  if prior.created_by=actor.id and prior.party_kind=p_party_kind and prior.party_id=p_party_id and prior.amount=p_amount and prior.date=p_date and prior.payment_mode=p_mode and prior.bank_id is not distinct from p_bank_id then return; end if;
  raise exception 'This payment request ID was already used for different details.';
 end if;
 if p_party_kind='customer' then
  select name into person_name from public.customers where id::text=p_party_id;
  if not found then raise exception 'Buyer not found.'; end if;
  perform id from public.sales where buyer_id::text=p_party_id and due>0 for update;
  perform id from public.opening_dues where party_kind='customer' and party_id=p_party_id and paid_amount<amount for update;
  select coalesce((select sum(due) from public.sales where buyer_id::text=p_party_id and due>0),0)+coalesce((select sum(amount-paid_amount) from public.opening_dues where party_kind='customer' and party_id=p_party_id and paid_amount<amount),0) into outstanding;
 else
  select name into person_name from public.sellers where id::text=p_party_id;
  if not found then raise exception 'Seller not found.'; end if;
  perform id from public.purchases where seller_id::text=p_party_id and due>0 for update;
  perform id from public.opening_dues where party_kind='seller' and party_id=p_party_id and paid_amount<amount for update;
  select coalesce((select sum(due) from public.purchases where seller_id::text=p_party_id and due>0),0)+coalesce((select sum(amount-paid_amount) from public.opening_dues where party_kind='seller' and party_id=p_party_id and paid_amount<amount),0) into outstanding;
 end if;
 if outstanding<=0 then raise exception 'This person has no outstanding balance.'; end if;
 if p_amount>outstanding then raise exception 'Amount cannot exceed the current total outstanding balance of %.',outstanding; end if;
 remaining:=p_amount;
 if p_party_kind='customer' then
  for item in
   select 'sale'::text source,id::text item_id,date,due item_due from public.sales where buyer_id::text=p_party_id and due>0
   union all select 'opening',id::text,date,amount-paid_amount from public.opening_dues where party_kind='customer' and party_id=p_party_id and paid_amount<amount
   order by date,item_id
  loop
   exit when remaining<=0; portion:=least(remaining,item.item_due);
   if item.source='sale' then update public.sales set amount_received=coalesce(amount_received,0)+portion,due=due-portion where id::text=item.item_id;
   else update public.opening_dues set paid_amount=paid_amount+portion where id::text=item.item_id; end if;
   get diagnostics affected=row_count; if affected<>1 then raise exception 'Due payment update was denied.'; end if; remaining:=remaining-portion;
  end loop;
 else
  for item in
   select 'purchase'::text source,id::text item_id,date,due item_due from public.purchases where seller_id::text=p_party_id and due>0
   union all select 'opening',id::text,date,amount-paid_amount from public.opening_dues where party_kind='seller' and party_id=p_party_id and paid_amount<amount
   order by date,item_id
  loop
   exit when remaining<=0; portion:=least(remaining,item.item_due);
   if item.source='purchase' then update public.purchases set amount_paid=coalesce(amount_paid,0)+portion,due=due-portion where id::text=item.item_id;
   else update public.opening_dues set paid_amount=paid_amount+portion where id::text=item.item_id; end if;
   get diagnostics affected=row_count; if affected<>1 then raise exception 'Due payment update was denied.'; end if; remaining:=remaining-portion;
  end loop;
 end if;
 if remaining<>0 then raise exception 'The full payment could not be allocated.'; end if;
 insert into public.person_due_payments(request_id,party_kind,party_id,amount,date,payment_mode,bank_id,created_by) values(p_request_id,p_party_kind,p_party_id,p_amount,p_date,p_mode,p_bank_id,actor.id);
 insert into public.ledger(date,type,mode,bank_id,amount,ref_type,ref_id,note,created_by,created_by_name)
 values(p_date,case when p_party_kind='customer' then 'Payment Received' else 'Payment' end,case when p_mode='Online' then 'Bank' else 'Cash' end,case when p_mode='Online' then bank.id else null end,case when p_party_kind='customer' then p_amount else -p_amount end,case when p_party_kind='customer' then 'customer_due' else 'seller_due' end,p_party_id,case when p_party_kind='customer' then 'Payment received from ' else 'Payment paid to ' end||person_name,actor.id,actor.full_name);
end;
$$;
revoke all on function public.pay_person_outstanding_due(uuid,text,text,numeric,date,text,text) from public;
grant execute on function public.pay_person_outstanding_due(uuid,text,text,numeric,date,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
