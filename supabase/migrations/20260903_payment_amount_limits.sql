-- Apply after the earlier payment migrations. Existing rows are not rewritten.
begin;

do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.sales'::regclass and conname='sales_received_within_total') then
    alter table public.sales add constraint sales_received_within_total
      check(sale_price>=0 and amount_received>=0 and amount_received<=sale_price
        and sale_price::text not in ('NaN','Infinity','-Infinity')
        and amount_received::text not in ('NaN','Infinity','-Infinity')) not valid;
  end if;
end; $$;

-- Lock the invoice/purchase, validate its CURRENT due, update it and post the ledger together.
create or replace function public.pay_outstanding_due(
 p_ref_type text,p_ref_id text,p_amount numeric,p_date date,p_mode text,p_bank_id text default null
) returns void language plpgsql security invoker set search_path=public as $$
declare
 actor public.profiles%rowtype;
 sale public.sales%rowtype;
 purchase public.purchases%rowtype;
 bank public.banks%rowtype;
 movement public.ledger%rowtype;
 outstanding numeric;
 updated_id text;
begin
 select * into actor from public.profiles where id=auth.uid();
 if not found then raise exception 'Sign in before recording a payment.'; end if;
 if p_ref_type is null or p_ref_type not in ('sale','purchase') or nullif(p_ref_id,'') is null then
   raise exception 'Invalid payment reference.';
 end if;
 if p_amount is null or p_amount<=0 or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount<>round(p_amount,2) then
   raise exception 'Enter a positive amount with at most two decimal places.';
 end if;
 if p_date is null or p_date>(now() at time zone 'Asia/Kolkata')::date then raise exception 'Future dates are not allowed.'; end if;
 if p_mode is null or p_mode not in ('Cash','Online') then raise exception 'Select Cash or Online.'; end if;
 if p_mode='Online' then
   select * into bank from public.banks where id::text=p_bank_id;
   if not found then raise exception 'Select an existing bank account.'; end if;
 end if;
 if p_ref_type='sale' then
   select * into sale from public.sales where id::text=p_ref_id for update;
   if not found then raise exception 'Sale not found or payment access denied.'; end if;
   outstanding:=sale.due;
 else
   select * into purchase from public.purchases where id::text=p_ref_id for update;
   if not found then raise exception 'Purchase not found or payment access denied.'; end if;
   outstanding:=purchase.due;
 end if;
 if outstanding is null or outstanding<=0 or outstanding::text in ('NaN','Infinity','-Infinity') then
   raise exception 'This record has no valid outstanding balance.';
 end if;
 if p_amount>outstanding then
   raise exception 'Amount cannot exceed the current outstanding balance of %.',outstanding;
 end if;
 if p_ref_type='sale' then
   if coalesce(sale.amount_received,0)+p_amount>sale.sale_price then raise exception 'Amount received cannot exceed the selling total.'; end if;
   update public.sales set amount_received=coalesce(sale.amount_received,0)+p_amount,due=outstanding-p_amount
     where id=sale.id returning id::text into updated_id;
 else
   if coalesce(purchase.amount_paid,0)+p_amount>purchase.purchase_price*purchase.qty then raise exception 'Amount paid cannot exceed the purchase total.'; end if;
   update public.purchases set amount_paid=coalesce(purchase.amount_paid,0)+p_amount,due=outstanding-p_amount
     where id=purchase.id returning id::text into updated_id;
 end if;
 if updated_id is null then raise exception 'Payment update was denied.'; end if;
 movement:=jsonb_populate_record(null::public.ledger,jsonb_build_object(
   'date',p_date,'type',case when p_ref_type='sale' then 'Payment Received' else 'Payment' end,
   'mode',case when p_mode='Online' then 'Bank' else 'Cash' end,
   'bank_id',case when p_mode='Online' then bank.id else null end,
   'amount',case when p_ref_type='sale' then p_amount else -p_amount end,
   'ref_type',p_ref_type,'ref_id',p_ref_id,'note','Due payment for '||p_ref_id,
   'created_by',actor.id,'created_by_name',actor.full_name));
 insert into public.ledger(date,type,mode,bank_id,amount,ref_type,ref_id,note,created_by,created_by_name)
   values(movement.date,movement.type,movement.mode,movement.bank_id,movement.amount,movement.ref_type,movement.ref_id,movement.note,movement.created_by,movement.created_by_name);
end;
$$;
revoke all on function public.pay_outstanding_due(text,text,numeric,date,text,text) from public;
grant execute on function public.pay_outstanding_due(text,text,numeric,date,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
