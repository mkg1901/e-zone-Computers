-- Central expense types shared by Transactions and Expenses.
begin;

create table if not exists public.expense_types (
 name text primary key check (nullif(btrim(name),'') is not null),
 created_at timestamptz not null default now()
);

insert into public.expense_types(name)
values ('Rent'),('Electricity'),('Internet'),('Salary'),('Office Expense'),('Miscellaneous')
on conflict(name) do nothing;
insert into public.expense_types(name)
select distinct btrim(category) from public.expenses where nullif(btrim(category),'') is not null
on conflict(name) do nothing;

alter table public.expense_types enable row level security;
drop policy if exists expense_types_select_staff on public.expense_types;
create policy expense_types_select_staff on public.expense_types for select to authenticated using (
 exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in ('Admin','Staff'))
);
drop policy if exists expense_types_insert_admin on public.expense_types;
create policy expense_types_insert_admin on public.expense_types for insert to authenticated with check (
 exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='Admin')
);
drop policy if exists expense_types_delete_admin on public.expense_types;
create policy expense_types_delete_admin on public.expense_types for delete to authenticated using (
 exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='Admin')
);

do $$ begin
 if not exists(select 1 from pg_constraint where conname='expenses_category_expense_types_fk' and conrelid='public.expenses'::regclass) then
  alter table public.expenses add constraint expenses_category_expense_types_fk foreign key(category) references public.expense_types(name) on update cascade on delete restrict;
 end if;
end $$;

notify pgrst,'reload schema';
commit;
