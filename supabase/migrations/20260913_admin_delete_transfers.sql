-- Allow only Admin accounts to delete transfer audit records.
-- The existing delete_financial_transaction RPC then removes the transfer
-- and both matching ledger rows in one database transaction.
begin;

grant delete on public.cash_bank_transfers to authenticated;
drop policy if exists cash_bank_transfers_delete_admin on public.cash_bank_transfers;
create policy cash_bank_transfers_delete_admin
on public.cash_bank_transfers
for delete
to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'Admin'
  )
);

notify pgrst,'reload schema';
commit;
