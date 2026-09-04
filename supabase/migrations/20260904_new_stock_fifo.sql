-- Apply after 20260903_new_stock_serial_tracking.sql and its prerequisites.
-- Keeps purchase batches and cost snapshots; enforces FIFO for non-serial units.
begin;
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
 perform p.id from public.new_stock_products p where exists(
  select 1 from public.new_stock_products selected
  where selected.id in (select x->>'new_product_id' from jsonb_array_elements(p_items) x)
    and lower(btrim(p.accessory_type))=lower(btrim(selected.accessory_type))
    and lower(btrim(p.brand))=lower(btrim(selected.brand))
    and lower(btrim(p.model_no))=lower(btrim(selected.model_no))
 ) order by p.id for update;
 -- Non-serial quantities must consume older purchase batches before newer ones.
 -- Serial choices remain explicit; their owning batches are preserved.
 if exists(
  with requested as (
   select x->>'new_product_id' id,
    (x->>'quantity')::integer-jsonb_array_length(coalesce(x->'serial_numbers','[]'::jsonb)) units
   from jsonb_array_elements(p_items) x
  ), available as (
   select p.*,case when p.serial_required then 0 else greatest(0,p.quantity-
    (select count(*) from public.new_stock_serials s where s.product_id=p.id and not s.sold)) end untracked
   from public.new_stock_products p
  )
  select 1 from requested r join available p on p.id=r.id
  where r.units>0 and (r.units>p.untracked or exists(
   select 1 from available older left join requested used on used.id=older.id
   where lower(btrim(older.accessory_type))=lower(btrim(p.accessory_type))
    and lower(btrim(older.brand))=lower(btrim(p.brand))
    and lower(btrim(older.model_no))=lower(btrim(p.model_no))
    and (older.purchase_date,older.created_at,older.id)<(p.purchase_date,p.created_at,p.id)
    and older.untracked>coalesce(used.units,0)
  ))
 ) then raise exception 'Stock changed or an older batch is available. Refresh and add the item again; oldest stock must be sold first.'; end if;
 for item in select value from jsonb_array_elements(p_items) loop
  if (item->>'quantity') is null or (item->>'quantity')::numeric<>trunc((item->>'quantity')::numeric) then raise exception 'Quantity must be a whole number.'; end if;
  qty:=(item->>'quantity')::integer;rate:=(item->>'unit_price')::numeric;
  if qty<1 or rate is null or rate<0 or rate::text in ('NaN','Infinity','-Infinity') or rate<>round(rate,2) then raise exception 'Enter a valid quantity and unit price.'; end if;
  select * into product from public.new_stock_products where id=item->>'new_product_id';
  if not found or product.quantity<qty then raise exception 'One of the selected items has insufficient stock. Refresh and check quantities.'; end if;
  if jsonb_typeof(coalesce(item->'serial_numbers','[]'::jsonb))<>'array' then raise exception 'Invalid serial number selection.'; end if;
  select coalesce(array_agg(value),'{}'::text[]) into serials from jsonb_array_elements_text(coalesce(item->'serial_numbers','[]'::jsonb));
  if cardinality(serials)>qty or cardinality(serials)<>(select count(distinct s) from unnest(serials) s) then raise exception 'Check the selected serial count and duplicates.'; end if;
  if product.serial_required and cardinality(serials)<>qty then raise exception 'Select one serial number per unit for this item.'; end if;
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

revoke all on function public.create_new_stock_sale(jsonb,jsonb) from public;
grant execute on function public.create_new_stock_sale(jsonb,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
