-- DESTRUCTIVE MANUAL OPERATION
-- Clears test/business records so the EZR system can start with real data.
-- Preserves auth.users, public.profiles, public.settings, public.accessory_types,
-- database schema, functions, policies, and migrations.
-- Run only in the intended Supabase project after reviewing the scope below.

begin;

truncate table
  public.invoice_whatsapp_deliveries,
  public.person_due_payments,
  public.cash_bank_transfers,
  public.stock_modifications,
  public.new_stock_serials,
  public.ledger,
  public.expenses,
  public.call_lodges,
  public.sales,
  public.purchases,
  public.stock,
  public.new_stock_products,
  public.customers,
  public.sellers,
  public.banks
restart identity cascade;

-- A clean ledger must start from a zero opening cash balance.
update public.settings
set value = '0'
where key = 'cash_opening';

-- Restart the human-readable business identifiers used by generate_id().
do $$
declare
  sequence_name text;
begin
  foreach sequence_name in array array[
    'stock_seq',
    'new_stock_seq',
    'purchase_seq',
    'invoice_seq',
    'expense_seq',
    'customer_seq',
    'seller_seq',
    'call_lodge_seq'
  ]
  loop
    if to_regclass('public.' || sequence_name) is not null then
      execute format('alter sequence public.%I restart with 1', sequence_name);
    end if;
  end loop;
end
$$;

commit;

-- Verification: every returned count should be zero.
select 'banks' as table_name, count(*) as remaining_rows from public.banks
union all select 'call_lodges', count(*) from public.call_lodges
union all select 'cash_bank_transfers', count(*) from public.cash_bank_transfers
union all select 'customers', count(*) from public.customers
union all select 'expenses', count(*) from public.expenses
union all select 'invoice_whatsapp_deliveries', count(*) from public.invoice_whatsapp_deliveries
union all select 'ledger', count(*) from public.ledger
union all select 'new_stock_products', count(*) from public.new_stock_products
union all select 'new_stock_serials', count(*) from public.new_stock_serials
union all select 'person_due_payments', count(*) from public.person_due_payments
union all select 'purchases', count(*) from public.purchases
union all select 'sales', count(*) from public.sales
union all select 'sellers', count(*) from public.sellers
union all select 'stock', count(*) from public.stock
union all select 'stock_modifications', count(*) from public.stock_modifications
order by table_name;
