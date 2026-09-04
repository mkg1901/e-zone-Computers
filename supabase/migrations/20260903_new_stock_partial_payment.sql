-- Apply after 20260903_new_stock_serial_tracking.sql. Preserves existing purchases.
begin;
create or replace function public.create_new_stock_purchase(
  p_product jsonb,
  p_purchase jsonb,
  p_serials text[],
  p_ledger jsonb
) returns text
language plpgsql
security invoker
set search_path = public
as $$
declare
  product public.new_stock_products%rowtype;
  purchase public.purchases%rowtype;
  movement public.ledger%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Sign in before adding stock.';
  end if;
  product := jsonb_populate_record(null::public.new_stock_products, p_product);
  purchase := jsonb_populate_record(null::public.purchases, p_purchase);
  movement := jsonb_populate_record(null::public.ledger, p_ledger);

  if product.created_by is distinct from auth.uid()
     or purchase.created_by is distinct from auth.uid()
     or purchase.new_product_id is distinct from product.id
     or purchase.stock_id is not null
     or product.quantity is null or product.quantity < 1
     or product.initial_quantity is distinct from product.quantity
     or purchase.qty is distinct from product.quantity
     or purchase.purchase_price is distinct from product.purchase_price
     or product.purchase_price is null or product.purchase_price<0
     or product.purchase_price::text in ('NaN','Infinity','-Infinity')
     or purchase.amount_paid is null or purchase.amount_paid<0
     or purchase.amount_paid>product.quantity * product.purchase_price
     or purchase.amount_paid::text in ('NaN','Infinity','-Infinity') then
    raise exception 'Invalid new-stock purchase details.';
  end if;
  -- Calculate the outstanding balance from the accepted payment, never a supplied due.
  purchase.due := product.quantity * product.purchase_price - purchase.amount_paid;
  if purchase.seller_id is null or purchase.seller_id is distinct from product.seller_id then
    raise exception 'Select the same seller for stock and purchase.';
  end if;
  if product.serial_required is null then
    raise exception 'Specify whether this item has serial numbers.';
  end if;
  if product.serial_required and coalesce(cardinality(p_serials),0) <> product.quantity then
    raise exception 'Enter one serial number for every unit.';
  end if;
  if not product.serial_required and coalesce(cardinality(p_serials),0)>0 then
    raise exception 'Enable serial tracking for items with serial numbers.';
  end if;
  -- Serialize batch serial checks, including against historical serials.
  lock table public.new_stock_serials in share row exclusive mode;
  if exists(select 1 from unnest(p_serials) s where s is null or btrim(s)='')
     or (select count(*) from unnest(p_serials)) <> (select count(distinct lower(btrim(s))) from unnest(p_serials) s)
     or exists(select 1 from public.new_stock_serials n join unnest(p_serials) s on lower(btrim(n.serial_number))=lower(btrim(s))) then
    raise exception 'Serial numbers must be nonblank and unique across stock.';
  end if;
  if coalesce(cardinality(p_serials), 0) > product.quantity then
    raise exception 'Serial number count cannot exceed quantity.';
  end if;
  if purchase.amount_paid > 0 then
    if p_ledger is null or movement.created_by is distinct from auth.uid()
       or movement.ref_type is distinct from 'purchase'
       or movement.ref_id::text is distinct from purchase.id::text
       or movement.amount is distinct from -purchase.amount_paid then
      raise exception 'Invalid purchase ledger details.';
    end if;
  elsif p_ledger is not null then
    raise exception 'An unpaid purchase must not contain a payment.';
  end if;

  insert into public.new_stock_products (
    id, accessory_type, brand, model_no, quantity, initial_quantity, serial_required,
    purchase_price, purchase_date, seller_id, seller_name, payment_mode,
    bank_id, created_by, created_by_name
  ) values (
    product.id, product.accessory_type, product.brand, product.model_no,
    product.quantity, product.initial_quantity, product.serial_required, product.purchase_price,
    product.purchase_date, product.seller_id, product.seller_name,
    product.payment_mode, product.bank_id, product.created_by, product.created_by_name
  );

  insert into public.new_stock_serials (product_id, serial_number)
    select product.id, btrim(serial) from unnest(coalesce(p_serials, '{}'::text[])) as serial;

  insert into public.purchases (
    id, stock_id, new_product_id, seller_id, seller_name, product_label,
    purchase_price, qty, date, payment_mode, bank_id, amount_paid, due,
    created_by, created_by_name
  ) values (
    purchase.id, null, product.id, purchase.seller_id, purchase.seller_name,
    purchase.product_label, purchase.purchase_price, purchase.qty, purchase.date,
    purchase.payment_mode, purchase.bank_id, purchase.amount_paid, purchase.due,
    purchase.created_by, purchase.created_by_name
  );

  if p_ledger is not null then
    insert into public.ledger (
      date, type, mode, bank_id, amount, ref_type, ref_id, note, created_by, created_by_name
    ) values (
      movement.date, movement.type, movement.mode, movement.bank_id, movement.amount,
      movement.ref_type, movement.ref_id, movement.note, movement.created_by, movement.created_by_name
    );
  end if;
  return product.id;
end;
$$;

revoke all on function public.create_new_stock_purchase(jsonb, jsonb, text[], jsonb) from public;
grant execute on function public.create_new_stock_purchase(jsonb, jsonb, text[], jsonb) to authenticated;

notify pgrst,'reload schema';
commit;
