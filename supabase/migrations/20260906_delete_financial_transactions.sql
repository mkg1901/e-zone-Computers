-- Delete user-created financial transactions and their account effects atomically.
-- Sales and purchases remain managed by their dedicated workflows because they
-- also affect inventory and dues.

create or replace function public.delete_financial_transaction(p_kind text, p_id text)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  actor public.profiles%rowtype;
  affected integer;
begin
  select * into actor from public.profiles where id = auth.uid();
  if actor.id is null or actor.role <> 'Admin' then
    raise exception 'Only an Admin can delete transactions.';
  end if;

  if p_kind = 'manual' then
    delete from public.ledger
    where id::text = p_id
      and ref_type = 'manual'
      and ref_id is null;
    get diagnostics affected = row_count;

  elsif p_kind = 'expense' then
    delete from public.ledger
    where ref_type = 'expense' and ref_id = p_id;

    delete from public.expenses where id = p_id;
    get diagnostics affected = row_count;

  elsif p_kind = 'transfer' then
    delete from public.ledger
    where ref_type = 'manual' and ref_id = p_id;

    delete from public.cash_bank_transfers where id::text = p_id;
    get diagnostics affected = row_count;

  elsif p_kind = 'stock' then
    if exists (select 1 from public.stock where id = p_id) then
      raise exception 'Delete this entry from Old Stock so all related records are removed.';
    end if;

    -- Cleanup for historical stock deletions that left their purchase ledger row.
    delete from public.ledger
    where ref_type = 'stock' and ref_id = p_id;
    get diagnostics affected = row_count;

  else
    raise exception 'This transaction type must be deleted from its source page.';
  end if;

  if affected = 0 then
    raise exception 'Transaction not found or already deleted.';
  end if;
end;
$$;

revoke all on function public.delete_financial_transaction(text, text) from public;
grant execute on function public.delete_financial_transaction(text, text) to authenticated;

-- Delete an unsold Old Stock record and every financial/audit record created for it.
create or replace function public.delete_old_stock_record(p_stock_id text)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  actor public.profiles%rowtype;
  stock_status text;
begin
  select * into actor from public.profiles where id = auth.uid();
  if actor.id is null or actor.role <> 'Admin' then
    raise exception 'Only an Admin can delete stock.';
  end if;

  select status into stock_status
  from public.stock
  where id = p_stock_id
  for update;

  if stock_status is null then
    raise exception 'Stock record not found or already deleted.';
  end if;
  if stock_status = 'Blocked' then
    raise exception 'Blocked accessory must be removed from its parent first.';
  end if;
  if stock_status = 'Sold' then
    raise exception 'Restore or delete the sale before deleting this stock.';
  end if;
  if exists (select 1 from public.stock where blocked_for = p_stock_id) then
    raise exception 'Remove blocked parts before deleting this stock.';
  end if;

  delete from public.ledger
  where (ref_type = 'stock' and ref_id = p_stock_id)
     or (ref_type = 'purchase' and ref_id in (
       select id from public.purchases where stock_id = p_stock_id
     ));

  delete from public.stock_modifications where stock_id = p_stock_id;
  delete from public.purchases where stock_id = p_stock_id;
  delete from public.stock where id = p_stock_id;
end;
$$;

revoke all on function public.delete_old_stock_record(text) from public;
grant execute on function public.delete_old_stock_record(text) to authenticated;