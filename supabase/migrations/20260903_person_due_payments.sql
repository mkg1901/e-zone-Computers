-- Apply after 20260903_payment_amount_limits.sql. Existing sales, purchases and payments are preserved.
begin;

create table if not exists public.person_due_payments (
 request_id uuid primary key,
 party_kind text not null check (party_kind in ('customer','seller')),
 party_id text not null,
 amount numeric(14,2) not null check (amount>0),
 date date not null,
 payment_mode text not null check (payment_mode in ('Cash','Online')),
 bank_id text null references public.banks(id),
 created_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now()
);
alter table public.person_due_payments enable row level security;
do $$ begin
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='person_due_payments' and policyname='person_due_payments_select_own') then
  create policy person_due_payments_select_own on public.person_due_payments for select to authenticated using(created_by=auth.uid());
 end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='person_due_payments' and policyname='person_due_payments_insert_own') then
  create policy person_due_payments_insert_own on public.person_due_payments for insert to authenticated with check(created_by=auth.uid());
 end if;
end $$;

create or replace function public.pay_person_outstanding_due(
 p_request_id uuid,p_party_kind text,p_party_id text,p_amount numeric,p_date date,p_mode text,p_bank_id text default null
) returns void language plpgsql security invoker set search_path=public as $$
declare
 actor public.profiles%rowtype; bank public.banks%rowtype; prior public.person_due_payments%rowtype;
 sale_row public.sales%rowtype; purchase_row public.purchases%rowtype;
 remaining numeric; outstanding numeric:=0; portion numeric; affected integer; person_name text;
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
  perform id from public.sales where buyer_id::text=p_party_id and due>0 order by date,id for update;
  select coalesce(sum(due),0) into outstanding from public.sales where buyer_id::text=p_party_id and due>0;
 else
  select name into person_name from public.sellers where id::text=p_party_id;
  if not found then raise exception 'Seller not found.'; end if;
  perform id from public.purchases where seller_id::text=p_party_id and due>0 order by date,id for update;
  select coalesce(sum(due),0) into outstanding from public.purchases where seller_id::text=p_party_id and due>0;
 end if;
 if outstanding<=0 then raise exception 'This person has no outstanding balance.'; end if;
 if p_amount>outstanding then raise exception 'Amount cannot exceed the current total outstanding balance of %.',outstanding; end if;
 remaining:=p_amount;
 if p_party_kind='customer' then
  for sale_row in select * from public.sales where buyer_id::text=p_party_id and due>0 order by date,id for update loop
   exit when remaining<=0; portion:=least(remaining,sale_row.due);
   if coalesce(sale_row.amount_received,0)+portion>sale_row.sale_price then raise exception 'Payment would exceed invoice % total.',sale_row.id; end if;
   update public.sales set amount_received=coalesce(amount_received,0)+portion,due=due-portion where id=sale_row.id;
   get diagnostics affected=row_count; if affected<>1 then raise exception 'Invoice payment update was denied.'; end if; remaining:=remaining-portion;
  end loop;
 else
  for purchase_row in select * from public.purchases where seller_id::text=p_party_id and due>0 order by date,id for update loop
   exit when remaining<=0; portion:=least(remaining,purchase_row.due);
   if coalesce(purchase_row.amount_paid,0)+portion>purchase_row.purchase_price*purchase_row.qty then raise exception 'Payment would exceed purchase % total.',purchase_row.id; end if;
   update public.purchases set amount_paid=coalesce(amount_paid,0)+portion,due=due-portion where id=purchase_row.id;
   get diagnostics affected=row_count; if affected<>1 then raise exception 'Purchase payment update was denied.'; end if; remaining:=remaining-portion;
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
