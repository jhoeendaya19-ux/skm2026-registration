-- FEATURE 148
-- Owner-only SKM2026 event ledger and income statement workspace.

begin;

create table if not exists public.financial_accounts (
  id uuid primary key default gen_random_uuid(),
  event_id text not null references public.events(id) on delete cascade,
  code text not null,
  name text not null,
  account_type text not null check (account_type in ('asset', 'liability', 'revenue', 'expense', 'equity')),
  statement_group text not null,
  normal_balance text not null check (normal_balance in ('debit', 'credit')),
  is_payment_source boolean not null default false,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (event_id, code)
);

create table if not exists public.financial_journal_entries (
  id uuid primary key default gen_random_uuid(),
  entry_number bigint generated always as identity,
  event_id text not null references public.events(id) on delete cascade,
  entry_date date not null,
  entry_kind text not null check (entry_kind in ('revenue', 'expense', 'adjustment')),
  source_type text not null,
  source_id text,
  counterparty text,
  description text not null,
  payment_method text,
  status text not null default 'posted' check (status in ('posted', 'voided')),
  void_reason text,
  voided_at timestamptz,
  voided_by text,
  created_at timestamptz not null default now(),
  created_by text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  metadata jsonb not null default '{}'::jsonb
);

create unique index if not exists financial_journal_source_unique_idx
  on public.financial_journal_entries(event_id, source_type, source_id)
  where source_id is not null;

create index if not exists financial_journal_event_date_idx
  on public.financial_journal_entries(event_id, entry_date desc, entry_number desc);

create index if not exists financial_journal_event_kind_status_idx
  on public.financial_journal_entries(event_id, entry_kind, status);

create table if not exists public.financial_journal_lines (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.financial_journal_entries(id) on delete cascade,
  line_number smallint not null,
  account_id uuid not null references public.financial_accounts(id),
  debit numeric(14,2) not null default 0 check (debit >= 0),
  credit numeric(14,2) not null default 0 check (credit >= 0),
  memo text,
  created_at timestamptz not null default now(),
  check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0)),
  unique (entry_id, line_number)
);

create index if not exists financial_journal_lines_account_idx
  on public.financial_journal_lines(account_id, entry_id);

create table if not exists public.financial_audit_log (
  id bigint generated always as identity primary key,
  event_id text not null references public.events(id) on delete cascade,
  entry_id uuid references public.financial_journal_entries(id) on delete set null,
  action text not null,
  actor_id uuid,
  actor_email text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists financial_audit_event_idx
  on public.financial_audit_log(event_id, created_at desc);

create index if not exists financial_audit_entry_idx
  on public.financial_audit_log(entry_id)
  where entry_id is not null;

alter table public.financial_accounts enable row level security;
alter table public.financial_journal_entries enable row level security;
alter table public.financial_journal_lines enable row level security;
alter table public.financial_audit_log enable row level security;

revoke all on table public.financial_accounts from public, anon, authenticated;
revoke all on table public.financial_journal_entries from public, anon, authenticated;
revoke all on table public.financial_journal_lines from public, anon, authenticated;
revoke all on table public.financial_audit_log from public, anon, authenticated;

grant all on table public.financial_accounts to service_role;
grant all on table public.financial_journal_entries to service_role;
grant all on table public.financial_journal_lines to service_role;
grant all on table public.financial_audit_log to service_role;

drop policy if exists "No direct financial account access" on public.financial_accounts;
create policy "No direct financial account access"
  on public.financial_accounts for all to anon, authenticated
  using (false) with check (false);

drop policy if exists "No direct financial journal access" on public.financial_journal_entries;
create policy "No direct financial journal access"
  on public.financial_journal_entries for all to anon, authenticated
  using (false) with check (false);

drop policy if exists "No direct financial line access" on public.financial_journal_lines;
create policy "No direct financial line access"
  on public.financial_journal_lines for all to anon, authenticated
  using (false) with check (false);

drop policy if exists "No direct financial audit access" on public.financial_audit_log;
create policy "No direct financial audit access"
  on public.financial_audit_log for all to anon, authenticated
  using (false) with check (false);

insert into public.financial_accounts (
  event_id, code, name, account_type, statement_group,
  normal_balance, is_payment_source, sort_order
) values
  ('skm2026', '1010', 'Cash on Hand', 'asset', 'Cash and cash equivalents', 'debit', true, 10),
  ('skm2026', '1020', 'GCash and E-wallets', 'asset', 'Cash and cash equivalents', 'debit', true, 20),
  ('skm2026', '1030', 'Bank Transfers', 'asset', 'Cash and cash equivalents', 'debit', true, 30),
  ('skm2026', '1090', 'Other Funds and Receivables', 'asset', 'Other current assets', 'debit', true, 40),
  ('skm2026', '2010', 'Accounts Payable', 'liability', 'Current liabilities', 'credit', true, 50),
  ('skm2026', '2020', 'Due to Event Owner or Staff', 'liability', 'Current liabilities', 'credit', true, 60),
  ('skm2026', '4010', 'Registration Revenue', 'revenue', 'Event revenue', 'credit', false, 100),
  ('skm2026', '4020', 'Registration Add-on Revenue', 'revenue', 'Event revenue', 'credit', false, 110),
  ('skm2026', '4090', 'Other Event Revenue', 'revenue', 'Event revenue', 'credit', false, 120),
  ('skm2026', '5010', 'Onsite Registration and Race Kit Claiming', 'expense', 'Operating expenses', 'debit', false, 200),
  ('skm2026', '5020', 'Race Kit and Merchandise', 'expense', 'Operating expenses', 'debit', false, 210),
  ('skm2026', '5030', 'Marketing and Communications', 'expense', 'Operating expenses', 'debit', false, 220),
  ('skm2026', '5040', 'Logistics and Transportation', 'expense', 'Operating expenses', 'debit', false, 230),
  ('skm2026', '5050', 'Venue, Permits and Compliance', 'expense', 'Operating expenses', 'debit', false, 240),
  ('skm2026', '5060', 'Race Day Operations', 'expense', 'Operating expenses', 'debit', false, 250),
  ('skm2026', '5070', 'Timing and Technology', 'expense', 'Operating expenses', 'debit', false, 260),
  ('skm2026', '5080', 'Safety and Medical', 'expense', 'Operating expenses', 'debit', false, 270),
  ('skm2026', '5090', 'Personnel and Professional Fees', 'expense', 'Operating expenses', 'debit', false, 280),
  ('skm2026', '5100', 'Post-Race Operations', 'expense', 'Operating expenses', 'debit', false, 290),
  ('skm2026', '5110', 'Administrative and Bank Charges', 'expense', 'Operating expenses', 'debit', false, 300),
  ('skm2026', '5190', 'Other Event Expenses', 'expense', 'Operating expenses', 'debit', false, 310)
on conflict (event_id, code) do update set
  name = excluded.name,
  account_type = excluded.account_type,
  statement_group = excluded.statement_group,
  normal_balance = excluded.normal_balance,
  is_payment_source = excluded.is_payment_source,
  is_active = true,
  sort_order = excluded.sort_order;

create or replace function public.financial_payment_account_code(p_method text)
returns text
language sql
immutable
set search_path = public
as $fn$
  select case
    when lower(coalesce(p_method, '')) in ('cash', 'onsite cash') then '1010'
    when lower(coalesce(p_method, '')) similar to '%(gcash|maya|e-wallet|ewallet)%' then '1020'
    when lower(coalesce(p_method, '')) similar to '%(bank|transfer|deposit)%' then '1030'
    else '1090'
  end;
$fn$;

revoke all on function public.financial_payment_account_code(text) from public, anon, authenticated;
grant execute on function public.financial_payment_account_code(text) to service_role;

-- Import one net checkout entry for every active SKM2026 non-student fulfillment record.
with active_registrations as (
  select distinct on (package.registration_id)
    registration.*
  from public.fulfillment_packages package
  join public.registrations registration on registration.id = package.registration_id
  where package.event_id = 'skm2026'
    and package.is_active = true
    and registration.event_id = 'skm2026'
    and registration.voided_at is null
    and coalesce(registration.is_test_registration, false) = false
  order by package.registration_id, package.updated_at desc nulls last, package.created_at desc
)
insert into public.financial_journal_entries (
  event_id, entry_date, entry_kind, source_type, source_id,
  counterparty, description, payment_method, created_by, updated_by, metadata
)
select
  'skm2026',
  (coalesce(registration.approved_at, registration.created_at) at time zone 'Asia/Manila')::date,
  'revenue',
  'registration_checkout',
  registration.id::text,
  registration.full_name,
  'SKM2026 registration ' || registration.reference_number,
  coalesce(nullif(registration.payment_method, ''), 'other'),
  'system:financial-import',
  'system:financial-import',
  jsonb_build_object(
    'registration_id', registration.id,
    'reference_number', registration.reference_number,
    'bib_number', registration.bib_number,
    'race_category', registration.race_category,
    'registration_channel', registration.registration_channel,
    'checkout_total', coalesce(registration.total_amount, 0),
    'race_fee', coalesce(registration.race_fee, 0),
    'regular_race_fee', coalesce(registration.regular_race_fee, registration.race_fee, 0),
    'product_total', coalesce(registration.product_total, 0),
    'voucher_code', registration.voucher_code,
    'voucher_discount', coalesce(registration.discount_amount, 0),
    'sale_discount', coalesce(registration.category_sale_discount_amount, 0),
    'statutory_discount', coalesce(registration.statutory_discount_amount, 0),
    'onsite_cash_amount', registration.onsite_cash_amount,
    'approved_at', registration.approved_at,
    'created_at', registration.created_at
  )
from active_registrations registration
on conflict (event_id, source_type, source_id) where source_id is not null do nothing;

insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo)
select
  entry.id,
  1,
  payment_account.id,
  round(coalesce(registration.total_amount, 0), 2),
  0,
  'Registration payment source'
from public.financial_journal_entries entry
join public.registrations registration on registration.id::text = entry.source_id
join public.financial_accounts payment_account
  on payment_account.event_id = entry.event_id
 and payment_account.code = public.financial_payment_account_code(registration.payment_method)
where entry.event_id = 'skm2026'
  and entry.source_type = 'registration_checkout'
  and coalesce(registration.total_amount, 0) > 0
  and not exists (
    select 1 from public.financial_journal_lines line
    where line.entry_id = entry.id and line.line_number = 1
  );

insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo)
select
  entry.id,
  2,
  revenue_account.id,
  0,
  round(coalesce(registration.total_amount, 0), 2),
  'Net registration revenue after recorded discounts'
from public.financial_journal_entries entry
join public.registrations registration on registration.id::text = entry.source_id
join public.financial_accounts revenue_account
  on revenue_account.event_id = entry.event_id and revenue_account.code = '4010'
where entry.event_id = 'skm2026'
  and entry.source_type = 'registration_checkout'
  and coalesce(registration.total_amount, 0) > 0
  and not exists (
    select 1 from public.financial_journal_lines line
    where line.entry_id = entry.id and line.line_number = 2
  );

-- Later verified add-on payments remain separate from the original checkout total.
with active_registrations as (
  select distinct on (package.registration_id)
    registration.*
  from public.fulfillment_packages package
  join public.registrations registration on registration.id = package.registration_id
  where package.event_id = 'skm2026'
    and package.is_active = true
    and registration.event_id = 'skm2026'
    and registration.voided_at is null
    and coalesce(registration.is_test_registration, false) = false
  order by package.registration_id, package.updated_at desc nulls last, package.created_at desc
), payments as (
  select
    registration.id as registration_id,
    registration.full_name,
    registration.reference_number,
    registration.bib_number,
    registration.race_category,
    payment.value as payment,
    payment.ordinality as payment_number
  from active_registrations registration
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(registration.post_registration_payments) = 'array'
      then registration.post_registration_payments else '[]'::jsonb end
  ) with ordinality as payment(value, ordinality)
  where coalesce((payment.value ->> 'amount')::numeric, 0) > 0
)
insert into public.financial_journal_entries (
  event_id, entry_date, entry_kind, source_type, source_id,
  counterparty, description, payment_method, created_by, updated_by, metadata
)
select
  'skm2026',
  coalesce(
    nullif(payment ->> 'recorded_at', '')::timestamptz at time zone 'Asia/Manila',
    now() at time zone 'Asia/Manila'
  )::date,
  'revenue',
  'registration_addon',
  registration_id::text || ':' || payment_number::text,
  full_name,
  'Post-registration payment for ' || reference_number,
  coalesce(nullif(payment ->> 'method', ''), 'other'),
  'system:financial-import',
  'system:financial-import',
  jsonb_build_object(
    'registration_id', registration_id,
    'reference_number', reference_number,
    'bib_number', bib_number,
    'race_category', race_category,
    'payment_number', payment_number,
    'amount', coalesce((payment ->> 'amount')::numeric, 0),
    'transaction_reference', payment ->> 'transaction_reference',
    'recorded_at', payment ->> 'recorded_at',
    'additional_products', coalesce(payment -> 'additional_products', payment -> 'products_after_update', '[]'::jsonb)
  )
from payments
on conflict (event_id, source_type, source_id) where source_id is not null do nothing;

insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo)
select
  entry.id,
  1,
  payment_account.id,
  round(coalesce((entry.metadata ->> 'amount')::numeric, 0), 2),
  0,
  'Additional payment source'
from public.financial_journal_entries entry
join public.financial_accounts payment_account
  on payment_account.event_id = entry.event_id
 and payment_account.code = public.financial_payment_account_code(entry.payment_method)
where entry.event_id = 'skm2026'
  and entry.source_type = 'registration_addon'
  and coalesce((entry.metadata ->> 'amount')::numeric, 0) > 0
  and not exists (
    select 1 from public.financial_journal_lines line
    where line.entry_id = entry.id and line.line_number = 1
  );

insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo)
select
  entry.id,
  2,
  revenue_account.id,
  0,
  round(coalesce((entry.metadata ->> 'amount')::numeric, 0), 2),
  'Post-registration add-on revenue'
from public.financial_journal_entries entry
join public.financial_accounts revenue_account
  on revenue_account.event_id = entry.event_id and revenue_account.code = '4020'
where entry.event_id = 'skm2026'
  and entry.source_type = 'registration_addon'
  and coalesce((entry.metadata ->> 'amount')::numeric, 0) > 0
  and not exists (
    select 1 from public.financial_journal_lines line
    where line.entry_id = entry.id and line.line_number = 2
  );

create or replace function public.financial_get_workspace(
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
  actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  revenue_total numeric(14,2) := 0;
  expense_total numeric(14,2) := 0;
  registration_count integer := 0;
  posted_revenue_count integer := 0;
  voided_revenue_count integer := 0;
  posted_expense_count integer := 0;
  voided_expense_count integer := 0;
  accounts_json jsonb := '[]'::jsonb;
  revenue_json jsonb := '[]'::jsonb;
  expense_json jsonb := '[]'::jsonb;
  payment_json jsonb := '[]'::jsonb;
  discounts_json jsonb := '{}'::jsonb;
begin
  if auth.uid() is null or coalesce(public.current_admin_role(), '') <> 'owner' then
    raise exception 'Only the owner account can access SKM2026 financials.';
  end if;
  if p_event_id <> 'skm2026' then
    raise exception 'This financial workspace is limited to SKM2026.';
  end if;
  if p_start_date is not null and p_end_date is not null and p_start_date > p_end_date then
    raise exception 'The start date cannot be after the end date.';
  end if;

  select
    coalesce(sum(case when account.account_type = 'revenue' then line.credit - line.debit else 0 end), 0),
    coalesce(sum(case when account.account_type = 'expense' then line.debit - line.credit else 0 end), 0)
  into revenue_total, expense_total
  from public.financial_journal_entries entry
  join public.financial_journal_lines line on line.entry_id = entry.id
  join public.financial_accounts account on account.id = line.account_id
  where entry.event_id = p_event_id
    and entry.status = 'posted'
    and (p_start_date is null or entry.entry_date >= p_start_date)
    and (p_end_date is null or entry.entry_date <= p_end_date);

  select
    count(*) filter (where source_type = 'registration_checkout'),
    count(*) filter (where entry_kind = 'revenue' and status = 'posted'),
    count(*) filter (where entry_kind = 'revenue' and status = 'voided'),
    count(*) filter (where entry_kind = 'expense' and status = 'posted'),
    count(*) filter (where entry_kind = 'expense' and status = 'voided')
  into registration_count, posted_revenue_count, voided_revenue_count, posted_expense_count, voided_expense_count
  from public.financial_journal_entries
  where event_id = p_event_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', account.id,
    'code', account.code,
    'name', account.name,
    'account_type', account.account_type,
    'statement_group', account.statement_group,
    'is_payment_source', account.is_payment_source
  ) order by account.sort_order, account.code), '[]'::jsonb)
  into accounts_json
  from public.financial_accounts account
  where account.event_id = p_event_id and account.is_active;

  select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.sort_order), '[]'::jsonb)
  into revenue_json
  from (
    select account.code, account.name, account.sort_order,
      round(sum(line.credit - line.debit), 2) as amount
    from public.financial_journal_entries entry
    join public.financial_journal_lines line on line.entry_id = entry.id
    join public.financial_accounts account on account.id = line.account_id
    where entry.event_id = p_event_id
      and entry.status = 'posted'
      and account.account_type = 'revenue'
      and (p_start_date is null or entry.entry_date >= p_start_date)
      and (p_end_date is null or entry.entry_date <= p_end_date)
    group by account.code, account.name, account.sort_order
    having sum(line.credit - line.debit) <> 0
  ) row_data;

  select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.sort_order), '[]'::jsonb)
  into expense_json
  from (
    select account.code, account.name, account.sort_order,
      round(sum(line.debit - line.credit), 2) as amount
    from public.financial_journal_entries entry
    join public.financial_journal_lines line on line.entry_id = entry.id
    join public.financial_accounts account on account.id = line.account_id
    where entry.event_id = p_event_id
      and entry.status = 'posted'
      and account.account_type = 'expense'
      and (p_start_date is null or entry.entry_date >= p_start_date)
      and (p_end_date is null or entry.entry_date <= p_end_date)
    group by account.code, account.name, account.sort_order
    having sum(line.debit - line.credit) <> 0
  ) row_data;

  select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.sort_order), '[]'::jsonb)
  into payment_json
  from (
    select account.code, account.name, account.sort_order,
      round(sum(line.debit - line.credit), 2) as amount
    from public.financial_journal_entries entry
    join public.financial_journal_lines line on line.entry_id = entry.id
    join public.financial_accounts account on account.id = line.account_id
    where entry.event_id = p_event_id
      and entry.status = 'posted'
      and entry.entry_kind = 'revenue'
      and account.is_payment_source
      and (p_start_date is null or entry.entry_date >= p_start_date)
      and (p_end_date is null or entry.entry_date <= p_end_date)
    group by account.code, account.name, account.sort_order
    having sum(line.debit - line.credit) <> 0
  ) row_data;

  select jsonb_build_object(
    'voucher', round(coalesce(sum((metadata ->> 'voucher_discount')::numeric), 0), 2),
    'sale', round(coalesce(sum((metadata ->> 'sale_discount')::numeric), 0), 2),
    'statutory', round(coalesce(sum((metadata ->> 'statutory_discount')::numeric), 0), 2),
    'total', round(coalesce(sum(
      (metadata ->> 'voucher_discount')::numeric
      + (metadata ->> 'sale_discount')::numeric
      + (metadata ->> 'statutory_discount')::numeric
    ), 0), 2)
  )
  into discounts_json
  from public.financial_journal_entries
  where event_id = p_event_id
    and source_type = 'registration_checkout'
    and status = 'posted'
    and (p_start_date is null or entry_date >= p_start_date)
    and (p_end_date is null or entry_date <= p_end_date);

  return jsonb_build_object(
    'actor', jsonb_build_object('email', actor_email, 'role', 'owner'),
    'event', (select jsonb_build_object('id', event.id, 'name', event.name, 'event_date', event.event_date) from public.events event where event.id = p_event_id),
    'period', jsonb_build_object('start_date', p_start_date, 'end_date', p_end_date),
    'summary', jsonb_build_object(
      'revenue', round(revenue_total, 2),
      'expenses', round(expense_total, 2),
      'net_income', round(revenue_total - expense_total, 2),
      'registration_count', registration_count,
      'posted_revenue_count', posted_revenue_count,
      'voided_revenue_count', voided_revenue_count,
      'posted_expense_count', posted_expense_count,
      'voided_expense_count', voided_expense_count
    ),
    'accounts', accounts_json,
    'revenue_accounts', revenue_json,
    'expense_accounts', expense_json,
    'payment_sources', payment_json,
    'discounts', discounts_json
  );
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
  if p_event_id <> 'skm2026' then
    raise exception 'This financial workspace is limited to SKM2026.';
  end if;

  with summarized as materialized (
    select
      entry.id,
      entry.entry_number,
      entry.entry_date,
      entry.entry_kind,
      entry.source_type,
      entry.source_id,
      entry.counterparty,
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
        else 0 end), 0), 2) as amount,
      max(account.name) filter (where account.account_type = entry.entry_kind) as account_name,
      max(account.code) filter (where account.account_type = entry.entry_kind) as account_code,
      max(account.name) filter (where account.is_payment_source) as payment_account_name,
      max(account.code) filter (where account.is_payment_source) as payment_account_code
    from public.financial_journal_entries entry
    left join public.financial_journal_lines line on line.entry_id = entry.id
    left join public.financial_accounts account on account.id = line.account_id
    where entry.event_id = p_event_id
    group by entry.id
  ), filtered as materialized (
    select * from summarized
    where (nullif(trim(coalesce(p_kind, '')), '') is null or entry_kind = p_kind)
      and (nullif(trim(coalesce(p_status, '')), '') is null or status = p_status)
      and (p_start_date is null or entry_date >= p_start_date)
      and (p_end_date is null or entry_date <= p_end_date)
      and (
        nullif(trim(coalesce(p_search, '')), '') is null
        or counterparty ilike '%' || trim(p_search) || '%'
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

create or replace function public.financial_create_expense(
  p_event_id text,
  p_entry_date date,
  p_payee text,
  p_amount numeric,
  p_expense_account_id uuid,
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
begin
  if auth.uid() is null or coalesce(public.current_admin_role(), '') <> 'owner' then
    raise exception 'Only the owner account can record SKM2026 expenses.';
  end if;
  if p_event_id <> 'skm2026' then raise exception 'This financial workspace is limited to SKM2026.'; end if;
  if p_entry_date is null then raise exception 'Expense date is required.'; end if;
  if length(trim(coalesce(p_payee, ''))) < 2 then raise exception 'Merchant or recipient is required.'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Expense amount must be greater than zero.'; end if;
  if length(trim(coalesce(p_description, ''))) < 3 then raise exception 'A short expense description is required.'; end if;
  if not exists (select 1 from public.financial_accounts where id = p_expense_account_id and event_id = p_event_id and account_type = 'expense' and is_active) then
    raise exception 'Choose a valid expense category.';
  end if;
  if not exists (select 1 from public.financial_accounts where id = p_payment_account_id and event_id = p_event_id and is_payment_source and is_active) then
    raise exception 'Choose a valid payment source.';
  end if;

  insert into public.financial_journal_entries (
    id, event_id, entry_date, entry_kind, source_type, source_id,
    counterparty, description, payment_method, created_by, updated_by
  ) values (
    entry_id, p_event_id, p_entry_date, 'expense', 'manual_expense', entry_id::text,
    left(trim(p_payee), 240), left(trim(p_description), 1000), left(trim(coalesce(p_payment_method, '')), 100),
    actor_email, actor_email
  );

  insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo) values
    (entry_id, 1, p_expense_account_id, round(p_amount, 2), 0, left(trim(p_description), 500)),
    (entry_id, 2, p_payment_account_id, 0, round(p_amount, 2), 'Payment source');

  insert into public.financial_audit_log (event_id, entry_id, action, actor_id, actor_email, details)
  values (p_event_id, entry_id, 'expense_created', auth.uid(), actor_email, jsonb_build_object('amount', round(p_amount, 2)));

  return jsonb_build_object('id', entry_id, 'status', 'posted');
end;
$fn$;

create or replace function public.financial_update_expense(
  p_entry_id uuid,
  p_entry_date date,
  p_payee text,
  p_amount numeric,
  p_expense_account_id uuid,
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
  if length(trim(coalesce(p_description, ''))) < 3 then raise exception 'A short expense description is required.'; end if;
  if not exists (select 1 from public.financial_accounts where id = p_expense_account_id and event_id = target_event and account_type = 'expense' and is_active) then raise exception 'Choose a valid expense category.'; end if;
  if not exists (select 1 from public.financial_accounts where id = p_payment_account_id and event_id = target_event and is_payment_source and is_active) then raise exception 'Choose a valid payment source.'; end if;

  update public.financial_journal_entries set
    entry_date = p_entry_date,
    counterparty = left(trim(p_payee), 240),
    description = left(trim(p_description), 1000),
    payment_method = left(trim(coalesce(p_payment_method, '')), 100),
    updated_at = now(),
    updated_by = actor_email
  where id = p_entry_id;

  delete from public.financial_journal_lines where entry_id = p_entry_id;
  insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo) values
    (p_entry_id, 1, p_expense_account_id, round(p_amount, 2), 0, left(trim(p_description), 500)),
    (p_entry_id, 2, p_payment_account_id, 0, round(p_amount, 2), 'Payment source');

  insert into public.financial_audit_log (event_id, entry_id, action, actor_id, actor_email, details)
  values (target_event, p_entry_id, 'expense_updated', auth.uid(), actor_email, jsonb_build_object('previous', previous, 'amount', round(p_amount, 2)));

  return jsonb_build_object('id', p_entry_id, 'status', 'posted');
end;
$fn$;

create or replace function public.financial_void_entry(p_entry_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  target public.financial_journal_entries%rowtype;
begin
  if auth.uid() is null or coalesce(public.current_admin_role(), '') <> 'owner' then
    raise exception 'Only the owner account can void SKM2026 journal entries.';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Enter a short reason for voiding this entry.'; end if;
  select * into target from public.financial_journal_entries where id = p_entry_id for update;
  if target.id is null or target.event_id <> 'skm2026' then raise exception 'Journal entry not found.'; end if;
  if target.status = 'voided' then raise exception 'This journal entry is already voided.'; end if;

  update public.financial_journal_entries set
    status = 'voided',
    void_reason = left(trim(p_reason), 500),
    voided_at = now(),
    voided_by = actor_email,
    updated_at = now(),
    updated_by = actor_email
  where id = p_entry_id;

  insert into public.financial_audit_log (event_id, entry_id, action, actor_id, actor_email, details)
  values (target.event_id, p_entry_id, 'entry_voided', auth.uid(), actor_email, jsonb_build_object('reason', left(trim(p_reason), 500), 'entry_kind', target.entry_kind, 'source_type', target.source_type));

  return jsonb_build_object('id', p_entry_id, 'status', 'voided');
end;
$fn$;

create or replace function public.financial_restore_entry(p_entry_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  target public.financial_journal_entries%rowtype;
begin
  if auth.uid() is null or coalesce(public.current_admin_role(), '') <> 'owner' then
    raise exception 'Only the owner account can restore SKM2026 journal entries.';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Enter a short reason for restoring this entry.'; end if;
  select * into target from public.financial_journal_entries where id = p_entry_id for update;
  if target.id is null or target.event_id <> 'skm2026' then raise exception 'Journal entry not found.'; end if;
  if target.status <> 'voided' then raise exception 'This journal entry is already posted.'; end if;

  update public.financial_journal_entries set
    status = 'posted',
    void_reason = null,
    voided_at = null,
    voided_by = null,
    updated_at = now(),
    updated_by = actor_email
  where id = p_entry_id;

  insert into public.financial_audit_log (event_id, entry_id, action, actor_id, actor_email, details)
  values (target.event_id, p_entry_id, 'entry_restored', auth.uid(), actor_email, jsonb_build_object('reason', left(trim(p_reason), 500), 'previous_void_reason', target.void_reason));

  return jsonb_build_object('id', p_entry_id, 'status', 'posted');
end;
$fn$;

create or replace function public.financial_sync_skm2026_revenue()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  before_count integer;
  after_count integer;
  line_count integer;
begin
  if auth.uid() is null or coalesce(public.current_admin_role(), '') <> 'owner' then
    raise exception 'Only the owner account can synchronize SKM2026 revenue.';
  end if;
  select count(*) into before_count from public.financial_journal_entries where event_id = 'skm2026' and entry_kind = 'revenue';

  with active_registrations as (
    select distinct on (package.registration_id) registration.*
    from public.fulfillment_packages package
    join public.registrations registration on registration.id = package.registration_id
    where package.event_id = 'skm2026' and package.is_active = true
      and registration.event_id = 'skm2026' and registration.voided_at is null
      and coalesce(registration.is_test_registration, false) = false
    order by package.registration_id, package.updated_at desc nulls last, package.created_at desc
  )
  insert into public.financial_journal_entries (
    event_id, entry_date, entry_kind, source_type, source_id, counterparty,
    description, payment_method, created_by, updated_by, metadata
  )
  select 'skm2026', (coalesce(approved_at, created_at) at time zone 'Asia/Manila')::date,
    'revenue', 'registration_checkout', id::text, full_name,
    'SKM2026 registration ' || reference_number, coalesce(nullif(payment_method, ''), 'other'),
    actor_email, actor_email,
    jsonb_build_object(
      'registration_id', id, 'reference_number', reference_number, 'bib_number', bib_number,
      'race_category', race_category, 'registration_channel', registration_channel,
      'checkout_total', coalesce(total_amount, 0), 'race_fee', coalesce(race_fee, 0),
      'regular_race_fee', coalesce(regular_race_fee, race_fee, 0), 'product_total', coalesce(product_total, 0),
      'voucher_code', voucher_code, 'voucher_discount', coalesce(discount_amount, 0),
      'sale_discount', coalesce(category_sale_discount_amount, 0),
      'statutory_discount', coalesce(statutory_discount_amount, 0),
      'onsite_cash_amount', onsite_cash_amount, 'approved_at', approved_at, 'created_at', created_at
    )
  from active_registrations
  on conflict (event_id, source_type, source_id) where source_id is not null do nothing;

  with active_registrations as (
    select distinct on (package.registration_id) registration.*
    from public.fulfillment_packages package
    join public.registrations registration on registration.id = package.registration_id
    where package.event_id = 'skm2026' and package.is_active = true
      and registration.event_id = 'skm2026' and registration.voided_at is null
      and coalesce(registration.is_test_registration, false) = false
    order by package.registration_id, package.updated_at desc nulls last, package.created_at desc
  ), payments as (
    select registration.id as registration_id, registration.full_name, registration.reference_number,
      registration.bib_number, registration.race_category, payment.value as payment,
      payment.ordinality as payment_number
    from active_registrations registration
    cross join lateral jsonb_array_elements(case when jsonb_typeof(registration.post_registration_payments) = 'array' then registration.post_registration_payments else '[]'::jsonb end)
      with ordinality as payment(value, ordinality)
    where coalesce((payment.value ->> 'amount')::numeric, 0) > 0
  )
  insert into public.financial_journal_entries (
    event_id, entry_date, entry_kind, source_type, source_id, counterparty,
    description, payment_method, created_by, updated_by, metadata
  )
  select 'skm2026', coalesce(nullif(payment ->> 'recorded_at', '')::timestamptz at time zone 'Asia/Manila', now() at time zone 'Asia/Manila')::date,
    'revenue', 'registration_addon', registration_id::text || ':' || payment_number::text, full_name,
    'Post-registration payment for ' || reference_number, coalesce(nullif(payment ->> 'method', ''), 'other'),
    actor_email, actor_email,
    jsonb_build_object(
      'registration_id', registration_id, 'reference_number', reference_number, 'bib_number', bib_number,
      'race_category', race_category, 'payment_number', payment_number,
      'amount', coalesce((payment ->> 'amount')::numeric, 0),
      'transaction_reference', payment ->> 'transaction_reference', 'recorded_at', payment ->> 'recorded_at',
      'additional_products', coalesce(payment -> 'additional_products', payment -> 'products_after_update', '[]'::jsonb)
    )
  from payments
  on conflict (event_id, source_type, source_id) where source_id is not null do nothing;

  insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo)
  select entry.id, 1, account.id,
    case when entry.source_type = 'registration_checkout' then coalesce((entry.metadata ->> 'checkout_total')::numeric, 0) else coalesce((entry.metadata ->> 'amount')::numeric, 0) end,
    0, 'Revenue payment source'
  from public.financial_journal_entries entry
  join public.financial_accounts account on account.event_id = entry.event_id and account.code = public.financial_payment_account_code(entry.payment_method)
  where entry.event_id = 'skm2026' and entry.entry_kind = 'revenue'
    and (case when entry.source_type = 'registration_checkout' then coalesce((entry.metadata ->> 'checkout_total')::numeric, 0) else coalesce((entry.metadata ->> 'amount')::numeric, 0) end) > 0
    and not exists (select 1 from public.financial_journal_lines line where line.entry_id = entry.id and line.line_number = 1);

  insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo)
  select entry.id, 2, account.id, 0,
    case when entry.source_type = 'registration_checkout' then coalesce((entry.metadata ->> 'checkout_total')::numeric, 0) else coalesce((entry.metadata ->> 'amount')::numeric, 0) end,
    case when entry.source_type = 'registration_checkout' then 'Net registration revenue' else 'Post-registration add-on revenue' end
  from public.financial_journal_entries entry
  join public.financial_accounts account on account.event_id = entry.event_id
    and account.code = case when entry.source_type = 'registration_checkout' then '4010' else '4020' end
  where entry.event_id = 'skm2026' and entry.entry_kind = 'revenue'
    and (case when entry.source_type = 'registration_checkout' then coalesce((entry.metadata ->> 'checkout_total')::numeric, 0) else coalesce((entry.metadata ->> 'amount')::numeric, 0) end) > 0
    and not exists (select 1 from public.financial_journal_lines line where line.entry_id = entry.id and line.line_number = 2);

  select count(*) into after_count from public.financial_journal_entries where event_id = 'skm2026' and entry_kind = 'revenue';
  select count(*) into line_count from public.financial_journal_lines line join public.financial_journal_entries entry on entry.id = line.entry_id where entry.event_id = 'skm2026' and entry.entry_kind = 'revenue';

  insert into public.financial_audit_log (event_id, action, actor_id, actor_email, details)
  values ('skm2026', 'revenue_synchronized', auth.uid(), actor_email, jsonb_build_object('before', before_count, 'after', after_count, 'added', after_count - before_count));

  return jsonb_build_object('before', before_count, 'after', after_count, 'added', after_count - before_count, 'lines', line_count);
end;
$fn$;

revoke all on function public.financial_get_workspace(text, date, date) from public, anon;
revoke all on function public.financial_list_entries(text, text, text, text, date, date, integer, integer) from public, anon;
revoke all on function public.financial_create_expense(text, date, text, numeric, uuid, uuid, text, text) from public, anon;
revoke all on function public.financial_update_expense(uuid, date, text, numeric, uuid, uuid, text, text) from public, anon;
revoke all on function public.financial_void_entry(uuid, text) from public, anon;
revoke all on function public.financial_restore_entry(uuid, text) from public, anon;
revoke all on function public.financial_sync_skm2026_revenue() from public, anon;

grant execute on function public.financial_get_workspace(text, date, date) to authenticated, service_role;
grant execute on function public.financial_list_entries(text, text, text, text, date, date, integer, integer) to authenticated, service_role;
grant execute on function public.financial_create_expense(text, date, text, numeric, uuid, uuid, text, text) to authenticated, service_role;
grant execute on function public.financial_update_expense(uuid, date, text, numeric, uuid, uuid, text, text) to authenticated, service_role;
grant execute on function public.financial_void_entry(uuid, text) to authenticated, service_role;
grant execute on function public.financial_restore_entry(uuid, text) to authenticated, service_role;
grant execute on function public.financial_sync_skm2026_revenue() to authenticated, service_role;

commit;

notify pgrst, 'reload schema';
