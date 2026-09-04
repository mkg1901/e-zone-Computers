-- Apply after the earlier migrations. Old single-item bills remain readable.
begin;
alter table public.sales add column if not exists line_items jsonb not null default '[]'::jsonb;
alter table public.sales add column if not exists service_charge numeric(14,2) not null default 0;
do $$ begin
 if not exists(select 1 from pg_constraint where conrelid='public.sales'::regclass and conname='sales_line_items_array') then
  alter table public.sales add constraint sales_line_items_array check(jsonb_typeof(line_items)='array');
 end if;
 if not exists(select 1 from pg_constraint where conrelid='public.sales'::regclass and conname='sales_service_charge_valid') then
  alter table public.sales add constraint sales_service_charge_valid check(service_charge>=0 and service_charge::text not in ('NaN','Infinity','-Infinity'));
 end if;
end; $$;

create or replace function public.create_new_stock_sale(p_sale jsonb,p_items jsonb)
returns text language plpgsql security invoker set search_path=public as $$
declare
 actor public.profiles%rowtype;
 header public.sales%rowtype;
 buyer public.customers%rowtype;
 product public.new_stock_products%rowtype;
 bank public.banks%rowtype;
 movement public.ledger%rowtype;
 item jsonb;
 lines jsonb:='[]'::jsonb;
 serials text[];
 all_serials text[]:='{}';
 qty integer;
 rate numeric;
 service numeric;
 total numeric:=0;
 units integer:=0;
 affected integer;
 label text;
 labels text[]:='{}';
begin
 select * into actor from public.profiles where id=auth.uid();
 if not found then raise exception 'Sign in before creating a sale.'; end if;
 header:=jsonb_populate_record(null::public.sales,p_sale);
 service:=coalesce(header.service_charge,0);
 if nullif(header.id::text,'') is null or header.date is null or header.date>(now() at time zone 'Asia/Kolkata')::date then raise exception 'Enter a valid invoice and date.'; end if;
 if service<0 or service::text in ('NaN','Infinity','-Infinity') then raise exception 'Enter a valid service charge.'; end if;
 if header.payment_mode is null or header.payment_mode not in ('Cash','Online') then raise exception 'Select Cash or Online.'; end if;
 if header.payment_mode='Online' then
  select * into bank from public.banks where id=header.bank_id;
  if not found then raise exception 'Select an existing bank account.'; end if;
 else header.bank_id:=null;
 end if;
 select * into buyer from public.customers where id=header.buyer_id;
 if not found then raise exception 'Select an existing buyer.'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one item.'; end if;
 if exists(select 1 from jsonb_array_elements(p_items) x group by x->>'new_product_id' having count(*)>1) then raise exception 'Use one line per product and increase its quantity.'; end if;
 -- Consistent product locking order prevents different multi-item carts deadlocking.
 perform id from public.new_stock_products where id in (select x->>'new_product_id' from jsonb_array_elements(p_items) x) order by id for update;
 for item in select value from jsonb_array_elements(p_items) loop
  if (item->>'quantity') is null or (item->>'quantity')::numeric<>trunc((item->>'quantity')::numeric) then raise exception 'Quantity must be a whole number.'; end if;
  qty:=(item->>'quantity')::integer;rate:=(item->>'unit_price')::numeric;
  if qty<1 or rate is null or rate<0 or rate::text in ('NaN','Infinity','-Infinity') or rate<>round(rate,2) then raise exception 'Enter a valid quantity and unit price.'; end if;
  select * into product from public.new_stock_products where id=item->>'new_product_id';
  if not found or product.quantity<qty then raise exception 'One of the selected items has insufficient stock. Refresh and check quantities.'; end if;
  if jsonb_typeof(coalesce(item->'serial_numbers','[]'::jsonb))<>'array' then raise exception 'Invalid serial number selection.'; end if;
  select coalesce(array_agg(value),'{}'::text[]) into serials from jsonb_array_elements_text(coalesce(item->'serial_numbers','[]'::jsonb));
  if cardinality(serials)>qty or cardinality(serials)<>(select count(distinct s) from unnest(serials) s) then raise exception 'Check the selected serial count and duplicates.'; end if;
  perform id from public.new_stock_serials where product_id=product.id and serial_number=any(serials) and sold=false order by id for update;
  get diagnostics affected=row_count;
  if affected<>cardinality(serials) then raise exception 'A selected serial number is unavailable.'; end if;
  label:=concat_ws(' ',product.accessory_type,product.brand,product.model_no);
  lines:=lines||jsonb_build_array(jsonb_build_object('new_product_id',product.id,'stock_label',label,'quantity',qty,'unit_price',rate,'purchase_price',product.purchase_price,'serial_numbers',to_jsonb(serials)));
  labels:=array_append(labels,label);all_serials:=all_serials||serials;
  total:=total+rate*qty;units:=units+qty;
 end loop;
 total:=total+service;
 if header.amount_received is null or header.amount_received<0 or header.amount_received>total or header.amount_received::text in ('NaN','Infinity','-Infinity') then raise exception 'Amount received cannot exceed the bill total or be negative.'; end if;
 -- The existing invoice ID is reused by a form retry; the PK prevents a second bill.
 insert into public.sales(id,bill_no,stock_id,stock_label,buyer_id,buyer_name,sale_price,date,payment_mode,bank_id,amount_received,due,stock_source,new_product_id,quantity,unit_price,serial_numbers,created_by,created_by_name,line_items,service_charge)
 values(header.id,header.id,null,array_to_string(labels,'; '),buyer.id,buyer.name,total,header.date,header.payment_mode,header.bank_id,header.amount_received,total-header.amount_received,'new',case when jsonb_array_length(lines)=1 then lines->0->>'new_product_id' else null end,units,case when jsonb_array_length(lines)=1 then (lines->0->>'unit_price')::numeric else 0 end,all_serials,actor.id,actor.full_name,lines,service);
 for item in select value from jsonb_array_elements(lines) loop
  update public.new_stock_products set quantity=quantity-(item->>'quantity')::integer where id=item->>'new_product_id';
  get diagnostics affected=row_count;
  if affected<>1 then raise exception 'Stock update denied.'; end if;
  select coalesce(array_agg(value),'{}'::text[]) into serials from jsonb_array_elements_text(item->'serial_numbers');
  update public.new_stock_serials set sold=true,sale_id=header.id where product_id=item->>'new_product_id' and serial_number=any(serials) and sold=false;
  get diagnostics affected=row_count;
  if affected<>cardinality(serials) then raise exception 'Serial update denied.'; end if;
 end loop;
 if header.amount_received>0 then
  movement:=jsonb_populate_record(null::public.ledger,jsonb_build_object('date',header.date,'type','Sale','mode',case when header.payment_mode='Online' then 'Bank' else 'Cash' end,'bank_id',header.bank_id,'amount',header.amount_received,'ref_type','sale','ref_id',header.id,'note','Sale '||header.id,'created_by',actor.id,'created_by_name',actor.full_name));
  insert into public.ledger(date,type,mode,bank_id,amount,ref_type,ref_id,note,created_by,created_by_name) values(movement.date,movement.type,movement.mode,movement.bank_id,movement.amount,movement.ref_type,movement.ref_id,movement.note,movement.created_by,movement.created_by_name);
 end if;
 return header.id;
end;
$$;

create or replace function public.delete_new_stock_sale(p_sale_id text)
returns void language plpgsql security invoker set search_path=public as $$
declare header public.sales%rowtype; item jsonb; affected integer;
begin
 if auth.uid() is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
 select * into header from public.sales where id::text=p_sale_id for update;
 if not found then raise exception 'Sale not found.'; end if;
 if header.stock_source<>'new' or jsonb_array_length(header.line_items)=0 then raise exception 'This invoice does not contain multi-item stock details.'; end if;
 perform id from public.new_stock_products where id in (select x->>'new_product_id' from jsonb_array_elements(header.line_items) x) order by id for update;
 for item in select value from jsonb_array_elements(header.line_items) loop
  update public.new_stock_products set quantity=quantity+(item->>'quantity')::integer where id=item->>'new_product_id';
  get diagnostics affected=row_count;
  if affected<>1 then raise exception 'A product is missing or stock restoration was denied.'; end if;
 end loop;
 update public.new_stock_serials set sold=false,sale_id=null where sale_id=header.id;
 get diagnostics affected=row_count;
 if affected<>cardinality(header.serial_numbers) then raise exception 'Serial restoration was incomplete.'; end if;
 delete from public.ledger where ref_type='sale' and ref_id::text=p_sale_id;
 delete from public.sales where id=header.id;
 get diagnostics affected=row_count;
 if affected<>1 then raise exception 'Sale deletion denied.'; end if;
end;
$$;
revoke all on function public.create_new_stock_sale(jsonb,jsonb) from public;
revoke all on function public.delete_new_stock_sale(text) from public;
grant execute on function public.create_new_stock_sale(jsonb,jsonb) to authenticated;
grant execute on function public.delete_new_stock_sale(text) to authenticated;
notify pgrst,'reload schema';
commit;
