-- FEATURE 152
-- Separate accounting expense accounts from event activity/cost-center classifications.

begin;

create table if not exists public.financial_activity_categories (
  id uuid primary key default gen_random_uuid(),
  event_id text not null references public.events(id) on delete cascade,
  code text not null,
  name text not null,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (event_id, code)
);

alter table public.financial_activity_categories enable row level security;
revoke all on table public.financial_activity_categories from public, anon, authenticated;
grant all on table public.financial_activity_categories to service_role;

drop policy if exists "No direct financial activity category access" on public.financial_activity_categories;
create policy "No direct financial activity category access"
  on public.financial_activity_categories for all to anon, authenticated
  using (false) with check (false);

insert into public.financial_activity_categories (event_id, code, name, sort_order) values
  ('skm2026', 'GEN', 'General / Event-Wide', 10),
  ('skm2026', 'PLAN', 'Planning and Administration', 20),
  ('skm2026', 'SPON', 'Sponsorship and Partner Relations', 30),
  ('skm2026', 'MKT', 'Marketing and Communications', 40),
  ('skm2026', 'REG', 'Onsite Registration and Race Kit Claiming', 50),
  ('skm2026', 'KIT', 'Race Kit Production and Fulfillment', 60),
  ('skm2026', 'RACE', 'Race Day Operations', 70),
  ('skm2026', 'POST', 'Post-Race Operations', 80)
on conflict (event_id, code) do update set
  name = excluded.name,
  is_active = true,
  sort_order = excluded.sort_order;

alter table public.financial_journal_entries
  add column if not exists activity_category_id uuid references public.financial_activity_categories(id);

create index if not exists financial_journal_activity_idx
  on public.financial_journal_entries(activity_category_id, entry_date desc)
  where activity_category_id is not null;

update public.financial_journal_entries entry
set activity_category_id = activity.id
from public.financial_activity_categories activity
where entry.event_id = 'skm2026'
  and entry.entry_kind = 'expense'
  and entry.activity_category_id is null
  and activity.event_id = entry.event_id
  and activity.code = 'GEN';

-- Convert the expense section of the chart of accounts into actual accounting accounts.
insert into public.financial_accounts (
  event_id, code, name, account_type, statement_group,
  normal_balance, is_payment_source, is_active, sort_order
) values
  ('skm2026', '5010', 'Meals and Refreshments', 'expense', 'Operating expenses', 'debit', false, true, 200),
  ('skm2026', '5020', 'Supplies and Materials', 'expense', 'Operating expenses', 'debit', false, true, 210),
  ('skm2026', '5030', 'Printing and Reproduction', 'expense', 'Operating expenses', 'debit', false, true, 220),
  ('skm2026', '5040', 'Transportation and Fuel', 'expense', 'Operating expenses', 'debit', false, true, 230),
  ('skm2026', '5050', 'Venue and Equipment Rental', 'expense', 'Operating expenses', 'debit', false, true, 240),
  ('skm2026', '5060', 'Permits, Licenses and Regulatory Fees', 'expense', 'Operating expenses', 'debit', false, true, 250),
  ('skm2026', '5070', 'Marketing and Advertising', 'expense', 'Operating expenses', 'debit', false, true, 260),
  ('skm2026', '5080', 'Professional and Talent Fees', 'expense', 'Operating expenses', 'debit', false, true, 270),
  ('skm2026', '5090', 'Personnel Allowances and Wages', 'expense', 'Operating expenses', 'debit', false, true, 280),
  ('skm2026', '5100', 'Timing and Technology Services', 'expense', 'Operating expenses', 'debit', false, true, 290),
  ('skm2026', '5110', 'Safety and Medical Services', 'expense', 'Operating expenses', 'debit', false, true, 300),
  ('skm2026', '5120', 'Race Kits, Medals and Merchandise', 'expense', 'Operating expenses', 'debit', false, true, 310),
  ('skm2026', '5130', 'Communications and Internet', 'expense', 'Operating expenses', 'debit', false, true, 320),
  ('skm2026', '5140', 'Bank and Payment Processing Charges', 'expense', 'Operating expenses', 'debit', false, true, 330),
  ('skm2026', '5150', 'Awards and Prizes', 'expense', 'Operating expenses', 'debit', false, true, 340),
  ('skm2026', '5160', 'Accommodation', 'expense', 'Operating expenses', 'debit', false, true, 350),
  ('skm2026', '5170', 'Documentation and Media', 'expense', 'Operating expenses', 'debit', false, true, 360),
  ('skm2026', '5190', 'Miscellaneous Event Expenses', 'expense', 'Operating expenses', 'debit', false, true, 390)
on conflict (event_id, code) do update set
  name = excluded.name,
  account_type = excluded.account_type,
  statement_group = excluded.statement_group,
  normal_balance = excluded.normal_balance,
  is_payment_source = excluded.is_payment_source,
  is_active = excluded.is_active,
  sort_order = excluded.sort_order;

-- Keep the compatibility label aligned with the actual debit account.
update public.financial_journal_entries entry
set expense_item = expense_account.name
from public.financial_journal_lines line
join public.financial_accounts expense_account
  on expense_account.id = line.account_id and expense_account.account_type = 'expense'
where entry.id = line.entry_id
  and entry.event_id = 'skm2026'
  and entry.entry_kind = 'expense';

drop function if exists public.financial_create_expense(text, date, text, text, numeric, uuid, uuid, text, text);
drop function if exists public.financial_update_expense(uuid, date, text, text, numeric, uuid, uuid, text, text);

create or replace function public.financial_create_expense(
  p_event_id text,
  p_entry_date date,
  p_payee text,
  p_amount numeric,
  p_expense_account_id uuid,
  p_activity_category_id uuid,
  p_payment_account_id uuid,
  p_description text,
  p_payment_method text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  entry_id uuid := gen_random_uuid();
  expense_account_name text;
  activity_name text;
begin
  if auth.uid() is null or coalesce(public.current_admin_role(), '') <> 'owner' then
    raise exception 'Only the owner account can record SKM2026 expenses.';
  end if;
  if p_event_id <> 'skm2026' then raise exception 'This financial workspace is limited to SKM2026.'; end if;
  if p_entry_date is null then raise exception 'Expense date is required.'; end if;
  if length(trim(coalesce(p_payee, ''))) < 2 then raise exception 'Merchant or recipient is required.'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Expense amount must be greater than zero.'; end if;
  if length(trim(coalesce(p_description, ''))) < 3 then raise exception 'A short expense purpose is required.'; end if;

  select name into expense_account_name
  from public.financial_accounts
  where id = p_expense_account_id and event_id = p_event_id and account_type = 'expense' and is_active;
  if expense_account_name is null then raise exception 'Choose a valid expense account.'; end if;

  select name into activity_name
  from public.financial_activity_categories
  where id = p_activity_category_id and event_id = p_event_id and is_active;
  if activity_name is null then raise exception 'Choose a valid activity or cost center.'; end if;

  if not exists (select 1 from public.financial_accounts where id = p_payment_account_id and event_id = p_event_id and is_payment_source and is_active) then
    raise exception 'Choose a valid payment source.';
  end if;

  insert into public.financial_journal_entries (
    id, event_id, entry_date, entry_kind, source_type, source_id,
    counterparty, expense_item, activity_category_id, description, payment_method, created_by, updated_by
  ) values (
    entry_id, p_event_id, p_entry_date, 'expense', 'manual_expense', entry_id::text,
    left(trim(p_payee), 240), expense_account_name, p_activity_category_id,
    left(trim(p_description), 1000), left(trim(coalesce(p_payment_method, '')), 100), actor_email, actor_email
  );

  insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo) values
    (entry_id, 1, p_expense_account_id, round(p_amount, 2), 0, left(activity_name || ': ' || trim(p_description), 500)),
    (entry_id, 2, p_payment_account_id, 0, round(p_amount, 2), 'Payment source');

  insert into public.financial_audit_log (event_id, entry_id, action, actor_id, actor_email, details)
  values (p_event_id, entry_id, 'expense_created', auth.uid(), actor_email, jsonb_build_object(
    'amount', round(p_amount, 2),
    'expense_account', expense_account_name,
    'activity_category', activity_name
  ));

  return jsonb_build_object('id', entry_id, 'status', 'posted');
end;
$fn$;

create or replace function public.financial_update_expense(
  p_entry_id uuid,
  p_entry_date date,
  p_payee text,
  p_amount numeric,
  p_expense_account_id uuid,
  p_activity_category_id uuid,
  p_payment_account_id uuid,
  p_description text,
  p_payment_method text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  target_event text;
  previous jsonb;
  expense_account_name text;
  activity_name text;
begin
  if auth.uid() is null or coalesce(public.current_admin_role(), '') <> 'owner' then
    raise exception 'Only the owner account can update SKM2026 expenses.';
  end if;
  select event_id, to_jsonb(entry) into target_event, previous
  from public.financial_journal_entries entry
  where id = p_entry_id and source_type = 'manual_expense' and entry_kind = 'expense' and status = 'posted';
  if target_event is null then raise exception 'This posted expense entry was not found.'; end if;
  if target_event <> 'skm2026' then raise exception 'This financial workspace is limited to SKM2026.'; end if;
  if p_entry_date is null then raise exception 'Expense date is required.'; end if;
  if length(trim(coalesce(p_payee, ''))) < 2 then raise exception 'Merchant or recipient is required.'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Expense amount must be greater than zero.'; end if;
  if length(trim(coalesce(p_description, ''))) < 3 then raise exception 'A short expense purpose is required.'; end if;

  select name into expense_account_name
  from public.financial_accounts
  where id = p_expense_account_id and event_id = target_event and account_type = 'expense' and is_active;
  if expense_account_name is null then raise exception 'Choose a valid expense account.'; end if;

  select name into activity_name
  from public.financial_activity_categories
  where id = p_activity_category_id and event_id = target_event and is_active;
  if activity_name is null then raise exception 'Choose a valid activity or cost center.'; end if;

  if not exists (select 1 from public.financial_accounts where id = p_payment_account_id and event_id = target_event and is_payment_source and is_active) then
    raise exception 'Choose a valid payment source.';
  end if;

  update public.financial_journal_entries set
    entry_date = p_entry_date,
    counterparty = left(trim(p_payee), 240),
    expense_item = expense_account_name,
    activity_category_id = p_activity_category_id,
    description = left(trim(p_description), 1000),
    payment_method = left(trim(coalesce(p_payment_method, '')), 100),
    updated_at = now(),
    updated_by = actor_email
  where id = p_entry_id;

  delete from public.financial_journal_lines where entry_id = p_entry_id;
  insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo) values
    (p_entry_id, 1, p_expense_account_id, round(p_amount, 2), 0, left(activity_name || ': ' || trim(p_description), 500)),
    (p_entry_id, 2, p_payment_account_id, 0, round(p_amount, 2), 'Payment source');

  insert into public.financial_audit_log (event_id, entry_id, action, actor_id, actor_email, details)
  values (target_event, p_entry_id, 'expense_updated', auth.uid(), actor_email, jsonb_build_object(
    'previous', previous,
    'amount', round(p_amount, 2),
    'expense_account', expense_account_name,
    'activity_category', activity_name
  ));

  return jsonb_build_object('id', p_entry_id, 'status', 'posted');
end;
$fn$;

create or replace function public.financial_list_activity_categories(
  p_event_id text default 'skm2026'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  result jsonb;
begin
  if auth.uid() is null or coalesce(public.current_admin_role(), '') <> 'owner' then
    raise exception 'Only the owner account can access SKM2026 financials.';
  end if;
  if p_event_id <> 'skm2026' then raise exception 'This financial workspace is limited to SKM2026.'; end if;

  select jsonb_build_object(
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'id', category.id,
      'code', category.code,
      'name', category.name
    ) order by category.sort_order, category.name), '[]'::jsonb)
  ) into result
  from public.financial_activity_categories category
  where category.event_id = p_event_id and category.is_active;

  return result;
end;
$fn$;

create or replace function public.financial_expense_statement_details(
  p_event_id text default 'skm2026',
  p_start_date date default null,
  p_end_date date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  result jsonb;
begin
  if auth.uid() is null or coalesce(public.current_admin_role(), '') <> 'owner' then
    raise exception 'Only the owner account can access SKM2026 financials.';
  end if;
  if p_event_id <> 'skm2026' then raise exception 'This financial workspace is limited to SKM2026.'; end if;
  if p_start_date is not null and p_end_date is not null and p_start_date > p_end_date then
    raise exception 'The start date cannot be after the end date.';
  end if;

  with expense_rows as (
    select
      entry.id,
      entry.entry_number,
      entry.entry_date,
      entry.counterparty,
      entry.description,
      entry.payment_method,
      account.id as account_id,
      account.code as account_code,
      account.name as account_name,
      account.sort_order as account_sort_order,
      activity.id as activity_category_id,
      activity.code as activity_category_code,
      activity.name as activity_category_name,
      activity.sort_order as activity_sort_order,
      round(sum(line.debit - line.credit), 2) as amount
    from public.financial_journal_entries entry
    join public.financial_journal_lines line on line.entry_id = entry.id
    join public.financial_accounts account on account.id = line.account_id and account.account_type = 'expense'
    left join public.financial_activity_categories activity on activity.id = entry.activity_category_id
    where entry.event_id = p_event_id
      and entry.entry_kind = 'expense'
      and entry.status = 'posted'
      and (p_start_date is null or entry.entry_date >= p_start_date)
      and (p_end_date is null or entry.entry_date <= p_end_date)
    group by entry.id, account.id, activity.id
  )
  select jsonb_build_object(
    'rows', coalesce(jsonb_agg(to_jsonb(expense_rows) order by activity_sort_order nulls first, account_sort_order, entry_date, entry_number), '[]'::jsonb)
  ) into result
  from expense_rows;

  return result;
end;
$fn$;

create or replace function public.financial_list_entries(
  p_event_id text default 'skm2026',
  p_kind text default null,
  p_status text default null,
  p_search text default null,
  p_start_date date default null,
  p_end_date date default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  result jsonb;
begin
  if auth.uid() is null or coalesce(public.current_admin_role(), '') <> 'owner' then
    raise exception 'Only the owner account can access SKM2026 financials.';
  end if;
  if p_event_id <> 'skm2026' then raise exception 'This financial workspace is limited to SKM2026.'; end if;

  with summarized as materialized (
    select
      entry.id,
      entry.entry_number,
      entry.entry_date,
      entry.entry_kind,
      entry.source_type,
      entry.source_id,
      entry.counterparty,
      entry.expense_item,
      entry.activity_category_id,
      activity.code as activity_category_code,
      activity.name as activity_category_name,
      entry.description,
      entry.payment_method,
      entry.status,
      entry.void_reason,
      entry.voided_at,
      entry.voided_by,
      entry.created_at,
      entry.created_by,
      entry.updated_at,
      entry.updated_by,
      entry.metadata,
      round(coalesce(sum(case
        when entry.entry_kind = 'revenue' and account.account_type = 'revenue' then line.credit - line.debit
        when entry.entry_kind = 'expense' and account.account_type = 'expense' then line.debit - line.credit
        when entry.entry_kind = 'adjustment' then line.debit
        else 0 end), 0), 2) as amount,
      coalesce(
        max(account.name) filter (where account.account_type = entry.entry_kind),
        max(account.name) filter (where entry.entry_kind = 'adjustment' and not account.is_payment_source)
      ) as account_name,
      coalesce(
        max(account.code) filter (where account.account_type = entry.entry_kind),
        max(account.code) filter (where entry.entry_kind = 'adjustment' and not account.is_payment_source)
      ) as account_code,
      max(account.name) filter (where account.is_payment_source) as payment_account_name,
      max(account.code) filter (where account.is_payment_source) as payment_account_code
    from public.financial_journal_entries entry
    left join public.financial_journal_lines line on line.entry_id = entry.id
    left join public.financial_accounts account on account.id = line.account_id
    left join public.financial_activity_categories activity on activity.id = entry.activity_category_id
    where entry.event_id = p_event_id
    group by entry.id, activity.id
  ), filtered as materialized (
    select * from summarized
    where (nullif(trim(coalesce(p_kind, '')), '') is null or entry_kind = p_kind)
      and (nullif(trim(coalesce(p_status, '')), '') is null or status = p_status)
      and (p_start_date is null or entry_date >= p_start_date)
      and (p_end_date is null or entry_date <= p_end_date)
      and (
        nullif(trim(coalesce(p_search, '')), '') is null
        or counterparty ilike '%' || trim(p_search) || '%'
        or expense_item ilike '%' || trim(p_search) || '%'
        or coalesce(activity_category_name, '') ilike '%' || trim(p_search) || '%'
        or description ilike '%' || trim(p_search) || '%'
        or coalesce(metadata ->> 'reference_number', '') ilike '%' || trim(p_search) || '%'
        or coalesce(metadata ->> 'bib_number', '') ilike '%' || trim(p_search) || '%'
      )
  ), paged as (
    select * from filtered
    order by entry_date desc, entry_number desc
    limit least(greatest(coalesce(p_limit, 50), 1), 100)
    offset greatest(coalesce(p_offset, 0), 0)
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'rows', coalesce((select jsonb_agg(to_jsonb(paged) order by entry_date desc, entry_number desc) from paged), '[]'::jsonb)
  ) into result;

  return result;
end;
$fn$;

revoke all on function public.financial_create_expense(text, date, text, numeric, uuid, uuid, uuid, text, text) from public, anon;
revoke all on function public.financial_update_expense(uuid, date, text, numeric, uuid, uuid, uuid, text, text) from public, anon;
revoke all on function public.financial_list_activity_categories(text) from public, anon;
revoke all on function public.financial_expense_statement_details(text, date, date) from public, anon;
revoke all on function public.financial_list_entries(text, text, text, text, date, date, integer, integer) from public, anon;

grant execute on function public.financial_create_expense(text, date, text, numeric, uuid, uuid, uuid, text, text) to authenticated, service_role;
grant execute on function public.financial_update_expense(uuid, date, text, numeric, uuid, uuid, uuid, text, text) to authenticated, service_role;
grant execute on function public.financial_list_activity_categories(text) to authenticated, service_role;
grant execute on function public.financial_expense_statement_details(text, date, date) to authenticated, service_role;
grant execute on function public.financial_list_entries(text, text, text, text, date, date, integer, integer) to authenticated, service_role;

commit;

notify pgrst, 'reload schema';
