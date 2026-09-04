-- Run after 20260901_invoice_new_stock.sql in Supabase SQL Editor.
-- Preserve purchases_stock_id_fkey: stock_id continues to reference legacy stock.
-- No existing records are deleted or rewritten, and RLS remains enabled.
begin;

alter table public.purchases add column if not exists new_product_id text;
-- Quantity-stock purchases have no legacy stock row.
alter table public.purchases alter column stock_id drop not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.purchases'::regclass and conname = 'purchases_new_product_id_fkey') then
    alter table public.purchases add constraint purchases_new_product_id_fkey
      foreign key (new_product_id) references public.new_stock_products(id);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.purchases'::regclass and conname = 'purchases_single_stock_source') then
    alter table public.purchases add constraint purchases_single_stock_source
      check (new_product_id is null or stock_id is null);
  end if;
end;
$$;

create index if not exists idx_purchases_new_product on public.purchases(new_product_id);

-- Use the caller's existing RLS permissions; no service role or SECURITY DEFINER.
-- Typed records use the actual purchases/ledger column types from this database.
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
     or purchase.amount_paid is distinct from product.quantity * product.purchase_price
     or purchase.due is distinct from 0 then
    raise exception 'Invalid new-stock purchase details.';
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
    raise exception 'A zero-cost purchase must not contain a payment.';
  end if;

  insert into public.new_stock_products (
    id, accessory_type, brand, model_no, quantity, initial_quantity,
    purchase_price, purchase_date, seller_id, seller_name, payment_mode,
    bank_id, created_by, created_by_name
  ) values (
    product.id, product.accessory_type, product.brand, product.model_no,
    product.quantity, product.initial_quantity, product.purchase_price,
    product.purchase_date, product.seller_id, product.seller_name,
    product.payment_mode, product.bank_id, product.created_by, product.created_by_name
  );

  insert into public.new_stock_serials (product_id, serial_number)
    select product.id, serial from unnest(coalesce(p_serials, '{}'::text[])) as serial;

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

notify pgrst, 'reload schema';
commit;
