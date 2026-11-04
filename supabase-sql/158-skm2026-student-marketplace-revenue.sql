begin;

insert into public.financial_accounts (
  event_id, code, name, account_type, statement_group, normal_balance,
  is_payment_source, is_active, sort_order
)
values
  ('skm2026', '4030', 'Student Registration Revenue', 'revenue', 'Event revenue', 'credit', false, true, 120),
  ('skm2026', '4040', 'Student Registration Add-on Revenue', 'revenue', 'Event revenue', 'credit', false, true, 130),
  ('skm2026', '4050', 'Marketplace Merchandise Revenue', 'revenue', 'Event revenue', 'credit', false, true, 140),
  ('skm2026', '4060', 'Marketplace Shipping Revenue', 'revenue', 'Event revenue', 'credit', false, true, 150)
on conflict (event_id, code) do update
set name = excluded.name,
    account_type = excluded.account_type,
    statement_group = excluded.statement_group,
    normal_balance = excluded.normal_balance,
    is_payment_source = excluded.is_payment_source,
    is_active = true,
    sort_order = excluded.sort_order;

-- Seed active student registration collections as separate base-fee and add-on entries.
insert into public.financial_journal_entries (
  event_id, entry_date, entry_kind, source_type, source_id, counterparty,
  description, payment_method, created_by, updated_by, metadata
)
select
  'skm2026',
  (coalesce(student.payment_verified_at, student.created_at) at time zone 'Asia/Manila')::date,
  'revenue',
  'student_registration',
  student.id::text,
  trim(concat_ws(', ', nullif(student.last_name, ''), nullif(student.first_name, ''))),
  'Student registration ' || student.reference_number,
  coalesce(nullif(student.payment_method, ''), 'cash'),
  'system:financial-import',
  'system:financial-import',
  jsonb_build_object(
    'managed_revenue_source', true,
    'student_registration_id', student.id,
    'reference_number', student.reference_number,
    'bib_number', student.bib_number,
    'race_category', student.distance,
    'amount', least(coalesce(student.amount_paid, 0), coalesce(student.registration_fee, 0)),
    'amount_paid', coalesce(student.amount_paid, 0),
    'registration_fee', coalesce(student.registration_fee, 0),
    'payment_reference', student.payment_reference,
    'payment_verified_at', student.payment_verified_at,
    'created_at', student.created_at
  )
from public.student_registrations student
where student.status = 'active'
  and least(coalesce(student.amount_paid, 0), coalesce(student.registration_fee, 0)) > 0
on conflict (event_id, source_type, source_id) where source_id is not null do nothing;

insert into public.financial_journal_entries (
  event_id, entry_date, entry_kind, source_type, source_id, counterparty,
  description, payment_method, created_by, updated_by, metadata
)
select
  'skm2026',
  (coalesce(student.payment_verified_at, student.created_at) at time zone 'Asia/Manila')::date,
  'revenue',
  'student_registration_addon',
  student.id::text,
  trim(concat_ws(', ', nullif(student.last_name, ''), nullif(student.first_name, ''))),
  'Student registration add-ons ' || student.reference_number,
  coalesce(nullif(student.payment_method, ''), 'cash'),
  'system:financial-import',
  'system:financial-import',
  jsonb_build_object(
    'managed_revenue_source', true,
    'student_registration_id', student.id,
    'reference_number', student.reference_number,
    'bib_number', student.bib_number,
    'race_category', student.distance,
    'amount', greatest(coalesce(student.amount_paid, 0) - coalesce(student.registration_fee, 0), 0),
    'amount_paid', coalesce(student.amount_paid, 0),
    'registration_fee', coalesce(student.registration_fee, 0),
    'payment_reference', student.payment_reference,
    'payment_verified_at', student.payment_verified_at,
    'created_at', student.created_at
  )
from public.student_registrations student
where student.status = 'active'
  and greatest(coalesce(student.amount_paid, 0) - coalesce(student.registration_fee, 0), 0) > 0
on conflict (event_id, source_type, source_id) where source_id is not null do nothing;

-- Marketplace revenue is recognized only after payment verification.
insert into public.financial_journal_entries (
  event_id, entry_date, entry_kind, source_type, source_id, counterparty,
  description, payment_method, created_by, updated_by, metadata
)
select
  'skm2026',
  (coalesce(market.payment_verified_at, market.reviewed_at, market.created_at) at time zone 'Asia/Manila')::date,
  'revenue',
  'marketplace_merchandise',
  market.id::text,
  market.full_name,
  'Marketplace merchandise ' || market.order_number,
  coalesce(nullif(market.payment_method, ''), 'other'),
  'system:financial-import',
  'system:financial-import',
  jsonb_build_object(
    'managed_revenue_source', true,
    'marketplace_order_id', market.id,
    'order_number', market.order_number,
    'runner_reference', market.runner_reference,
    'reference_number', market.order_number,
    'amount', greatest(coalesce(market.subtotal, 0) - coalesce(market.discount_total, 0), 0),
    'subtotal', coalesce(market.subtotal, 0),
    'discount_total', coalesce(market.discount_total, 0),
    'shipping_fee', coalesce(market.shipping_fee, 0),
    'total_amount', coalesce(market.total_amount, 0),
    'payment_reference', market.payment_reference,
    'marketplace_status', market.status,
    'payment_verified_at', market.payment_verified_at,
    'created_at', market.created_at
  )
from public.marketplace_orders market
where market.event_id = 'skm2026'
  and market.status not in ('pending_payment_verification', 'cancelled', 'declined')
  and greatest(coalesce(market.subtotal, 0) - coalesce(market.discount_total, 0), 0) > 0
on conflict (event_id, source_type, source_id) where source_id is not null do nothing;

insert into public.financial_journal_entries (
  event_id, entry_date, entry_kind, source_type, source_id, counterparty,
  description, payment_method, created_by, updated_by, metadata
)
select
  'skm2026',
  (coalesce(market.payment_verified_at, market.reviewed_at, market.created_at) at time zone 'Asia/Manila')::date,
  'revenue',
  'marketplace_shipping',
  market.id::text,
  market.full_name,
  'Marketplace shipping ' || market.order_number,
  coalesce(nullif(market.payment_method, ''), 'other'),
  'system:financial-import',
  'system:financial-import',
  jsonb_build_object(
    'managed_revenue_source', true,
    'marketplace_order_id', market.id,
    'order_number', market.order_number,
    'runner_reference', market.runner_reference,
    'reference_number', market.order_number,
    'amount', coalesce(market.shipping_fee, 0),
    'subtotal', coalesce(market.subtotal, 0),
    'discount_total', coalesce(market.discount_total, 0),
    'shipping_fee', coalesce(market.shipping_fee, 0),
    'total_amount', coalesce(market.total_amount, 0),
    'payment_reference', market.payment_reference,
    'marketplace_status', market.status,
    'payment_verified_at', market.payment_verified_at,
    'created_at', market.created_at
  )
from public.marketplace_orders market
where market.event_id = 'skm2026'
  and market.status not in ('pending_payment_verification', 'cancelled', 'declined')
  and coalesce(market.shipping_fee, 0) > 0
on conflict (event_id, source_type, source_id) where source_id is not null do nothing;

insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo)
select entry.id, 1, account.id, coalesce((entry.metadata ->> 'amount')::numeric, 0), 0, 'Revenue payment source'
from public.financial_journal_entries entry
join public.financial_accounts account
  on account.event_id = entry.event_id
 and account.code = public.financial_payment_account_code(entry.payment_method)
where entry.event_id = 'skm2026'
  and entry.source_type in ('student_registration', 'student_registration_addon', 'marketplace_merchandise', 'marketplace_shipping')
  and coalesce((entry.metadata ->> 'amount')::numeric, 0) > 0
  and not exists (
    select 1 from public.financial_journal_lines line
    where line.entry_id = entry.id and line.line_number = 1
  );

insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo)
select
  entry.id,
  2,
  account.id,
  0,
  coalesce((entry.metadata ->> 'amount')::numeric, 0),
  case entry.source_type
    when 'student_registration' then 'Student registration revenue'
    when 'student_registration_addon' then 'Student registration add-on revenue'
    when 'marketplace_merchandise' then 'Marketplace merchandise revenue after discounts'
    when 'marketplace_shipping' then 'Marketplace shipping revenue'
  end
from public.financial_journal_entries entry
join public.financial_accounts account
  on account.event_id = entry.event_id
 and account.code = case entry.source_type
   when 'student_registration' then '4030'
   when 'student_registration_addon' then '4040'
   when 'marketplace_merchandise' then '4050'
   when 'marketplace_shipping' then '4060'
 end
where entry.event_id = 'skm2026'
  and entry.source_type in ('student_registration', 'student_registration_addon', 'marketplace_merchandise', 'marketplace_shipping')
  and coalesce((entry.metadata ->> 'amount')::numeric, 0) > 0
  and not exists (
    select 1 from public.financial_journal_lines line
    where line.entry_id = entry.id and line.line_number = 2
  );

create or replace function public.financial_sync_skm2026_all_revenue()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  base_result jsonb;
  before_count integer;
  after_count integer;
  line_count integer;
begin
  if auth.uid() is null or coalesce(public.current_admin_role(), '') <> 'owner' then
    raise exception 'Only the owner account can synchronize SKM2026 revenue.';
  end if;

  select count(*) into before_count
  from public.financial_journal_entries
  where event_id = 'skm2026' and entry_kind = 'revenue';

  base_result := public.financial_sync_skm2026_revenue();

  insert into public.financial_journal_entries (
    event_id, entry_date, entry_kind, source_type, source_id, counterparty,
    description, payment_method, created_by, updated_by, metadata
  )
  select 'skm2026', (coalesce(payment_verified_at, created_at) at time zone 'Asia/Manila')::date,
    'revenue', 'student_registration', id::text,
    trim(concat_ws(', ', nullif(last_name, ''), nullif(first_name, ''))),
    'Student registration ' || reference_number, coalesce(nullif(payment_method, ''), 'cash'),
    actor_email, actor_email,
    jsonb_build_object(
      'managed_revenue_source', true, 'student_registration_id', id,
      'reference_number', reference_number, 'bib_number', bib_number, 'race_category', distance,
      'amount', least(coalesce(amount_paid, 0), coalesce(registration_fee, 0)),
      'amount_paid', coalesce(amount_paid, 0), 'registration_fee', coalesce(registration_fee, 0),
      'payment_reference', payment_reference, 'payment_verified_at', payment_verified_at, 'created_at', created_at
    )
  from public.student_registrations
  where status = 'active'
    and least(coalesce(amount_paid, 0), coalesce(registration_fee, 0)) > 0
  on conflict (event_id, source_type, source_id) where source_id is not null do nothing;

  insert into public.financial_journal_entries (
    event_id, entry_date, entry_kind, source_type, source_id, counterparty,
    description, payment_method, created_by, updated_by, metadata
  )
  select 'skm2026', (coalesce(payment_verified_at, created_at) at time zone 'Asia/Manila')::date,
    'revenue', 'student_registration_addon', id::text,
    trim(concat_ws(', ', nullif(last_name, ''), nullif(first_name, ''))),
    'Student registration add-ons ' || reference_number, coalesce(nullif(payment_method, ''), 'cash'),
    actor_email, actor_email,
    jsonb_build_object(
      'managed_revenue_source', true, 'student_registration_id', id,
      'reference_number', reference_number, 'bib_number', bib_number, 'race_category', distance,
      'amount', greatest(coalesce(amount_paid, 0) - coalesce(registration_fee, 0), 0),
      'amount_paid', coalesce(amount_paid, 0), 'registration_fee', coalesce(registration_fee, 0),
      'payment_reference', payment_reference, 'payment_verified_at', payment_verified_at, 'created_at', created_at
    )
  from public.student_registrations
  where status = 'active'
    and greatest(coalesce(amount_paid, 0) - coalesce(registration_fee, 0), 0) > 0
  on conflict (event_id, source_type, source_id) where source_id is not null do nothing;

  insert into public.financial_journal_entries (
    event_id, entry_date, entry_kind, source_type, source_id, counterparty,
    description, payment_method, created_by, updated_by, metadata
  )
  select 'skm2026', (coalesce(payment_verified_at, reviewed_at, created_at) at time zone 'Asia/Manila')::date,
    'revenue', 'marketplace_merchandise', id::text, full_name,
    'Marketplace merchandise ' || order_number, coalesce(nullif(payment_method, ''), 'other'),
    actor_email, actor_email,
    jsonb_build_object(
      'managed_revenue_source', true, 'marketplace_order_id', id, 'order_number', order_number,
      'runner_reference', runner_reference, 'reference_number', order_number,
      'amount', greatest(coalesce(subtotal, 0) - coalesce(discount_total, 0), 0),
      'subtotal', coalesce(subtotal, 0), 'discount_total', coalesce(discount_total, 0),
      'shipping_fee', coalesce(shipping_fee, 0), 'total_amount', coalesce(total_amount, 0),
      'payment_reference', payment_reference, 'marketplace_status', status,
      'payment_verified_at', payment_verified_at, 'created_at', created_at
    )
  from public.marketplace_orders
  where event_id = 'skm2026'
    and status not in ('pending_payment_verification', 'cancelled', 'declined')
    and greatest(coalesce(subtotal, 0) - coalesce(discount_total, 0), 0) > 0
  on conflict (event_id, source_type, source_id) where source_id is not null do nothing;

  insert into public.financial_journal_entries (
    event_id, entry_date, entry_kind, source_type, source_id, counterparty,
    description, payment_method, created_by, updated_by, metadata
  )
  select 'skm2026', (coalesce(payment_verified_at, reviewed_at, created_at) at time zone 'Asia/Manila')::date,
    'revenue', 'marketplace_shipping', id::text, full_name,
    'Marketplace shipping ' || order_number, coalesce(nullif(payment_method, ''), 'other'),
    actor_email, actor_email,
    jsonb_build_object(
      'managed_revenue_source', true, 'marketplace_order_id', id, 'order_number', order_number,
      'runner_reference', runner_reference, 'reference_number', order_number,
      'amount', coalesce(shipping_fee, 0), 'subtotal', coalesce(subtotal, 0),
      'discount_total', coalesce(discount_total, 0), 'shipping_fee', coalesce(shipping_fee, 0),
      'total_amount', coalesce(total_amount, 0), 'payment_reference', payment_reference,
      'marketplace_status', status, 'payment_verified_at', payment_verified_at, 'created_at', created_at
    )
  from public.marketplace_orders
  where event_id = 'skm2026'
    and status not in ('pending_payment_verification', 'cancelled', 'declined')
    and coalesce(shipping_fee, 0) > 0
  on conflict (event_id, source_type, source_id) where source_id is not null do nothing;

  insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo)
  select entry.id, 1, account.id, coalesce((entry.metadata ->> 'amount')::numeric, 0), 0, 'Revenue payment source'
  from public.financial_journal_entries entry
  join public.financial_accounts account
    on account.event_id = entry.event_id
   and account.code = public.financial_payment_account_code(entry.payment_method)
  where entry.event_id = 'skm2026'
    and entry.source_type in ('student_registration', 'student_registration_addon', 'marketplace_merchandise', 'marketplace_shipping')
    and coalesce((entry.metadata ->> 'amount')::numeric, 0) > 0
    and not exists (select 1 from public.financial_journal_lines line where line.entry_id = entry.id and line.line_number = 1);

  insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo)
  select entry.id, 2, account.id, 0, coalesce((entry.metadata ->> 'amount')::numeric, 0),
    case entry.source_type
      when 'student_registration' then 'Student registration revenue'
      when 'student_registration_addon' then 'Student registration add-on revenue'
      when 'marketplace_merchandise' then 'Marketplace merchandise revenue after discounts'
      when 'marketplace_shipping' then 'Marketplace shipping revenue'
    end
  from public.financial_journal_entries entry
  join public.financial_accounts account
    on account.event_id = entry.event_id
   and account.code = case entry.source_type
     when 'student_registration' then '4030'
     when 'student_registration_addon' then '4040'
     when 'marketplace_merchandise' then '4050'
     when 'marketplace_shipping' then '4060'
   end
  where entry.event_id = 'skm2026'
    and entry.source_type in ('student_registration', 'student_registration_addon', 'marketplace_merchandise', 'marketplace_shipping')
    and coalesce((entry.metadata ->> 'amount')::numeric, 0) > 0
    and not exists (select 1 from public.financial_journal_lines line where line.entry_id = entry.id and line.line_number = 2);

  select count(*) into after_count
  from public.financial_journal_entries
  where event_id = 'skm2026' and entry_kind = 'revenue';

  select count(*) into line_count
  from public.financial_journal_lines line
  join public.financial_journal_entries entry on entry.id = line.entry_id
  where entry.event_id = 'skm2026' and entry.entry_kind = 'revenue';

  insert into public.financial_audit_log (event_id, action, actor_id, actor_email, details)
  values (
    'skm2026', 'all_revenue_synchronized', auth.uid(), actor_email,
    jsonb_build_object('before', before_count, 'after', after_count, 'added', after_count - before_count, 'base_sync', base_result)
  );

  return jsonb_build_object(
    'before', before_count,
    'after', after_count,
    'added', after_count - before_count,
    'lines', line_count
  );
end;
$fn$;

revoke all on function public.financial_sync_skm2026_all_revenue() from public, anon;
grant execute on function public.financial_sync_skm2026_all_revenue() to authenticated, service_role;

create or replace function public.financial_get_audit_reconciliation(
  p_event_id text default 'skm2026'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  registration_revenue numeric(14,2) := 0;
  student_revenue numeric(14,2) := 0;
  marketplace_revenue numeric(14,2) := 0;
  supportable_revenue numeric(14,2) := 0;
  cash_after_overage numeric(14,2) := 0;
begin
  if auth.uid() is null or coalesce(public.current_admin_role(), '') <> 'owner' then
    raise exception 'Only the owner account can access SKM2026 financials.';
  end if;
  if p_event_id <> 'skm2026' then
    raise exception 'This financial workspace is limited to SKM2026.';
  end if;

  select
    round(coalesce(sum(line.credit - line.debit) filter (
      where entry.source_type in ('registration_checkout', 'registration_addon', 'audit_reconciliation')
    ), 0), 2),
    round(coalesce(sum(line.credit - line.debit) filter (
      where entry.source_type in ('student_registration', 'student_registration_addon')
    ), 0), 2),
    round(coalesce(sum(line.credit - line.debit) filter (
      where entry.source_type in ('marketplace_merchandise', 'marketplace_shipping')
    ), 0), 2),
    round(coalesce(sum(line.credit - line.debit), 0), 2)
  into registration_revenue, student_revenue, marketplace_revenue, supportable_revenue
  from public.financial_journal_entries entry
  join public.financial_journal_lines line on line.entry_id = entry.id
  join public.financial_accounts account on account.id = line.account_id
  where entry.event_id = p_event_id
    and entry.status = 'posted'
    and account.account_type = 'revenue';

  select round(coalesce(sum(line.debit - line.credit), 0), 2)
  into cash_after_overage
  from public.financial_journal_entries entry
  join public.financial_journal_lines line on line.entry_id = entry.id
  join public.financial_accounts account on account.id = line.account_id
  where entry.event_id = p_event_id
    and entry.status = 'posted'
    and account.code = '1010'
    and (entry.entry_kind = 'revenue' or entry.source_type = 'audit_reconciliation');

  return jsonb_build_object(
    'system_recorded_revenue', 2538363.73,
    'unsupported_recorded_revenue', 3372.00,
    'dashboard_verified_revenue', 2534991.73,
    'unpaid_category_change_balances', 4080.92,
    'supportable_registration_revenue', registration_revenue,
    'student_registration_revenue', student_revenue,
    'marketplace_revenue', marketplace_revenue,
    'supportable_net_revenue', supportable_revenue,
    'total_supportable_revenue', supportable_revenue,
    'unidentified_cash_overage', 187.20,
    'supportable_revenue_plus_overage', cash_after_overage
  );
end;
$fn$;

revoke all on function public.financial_get_audit_reconciliation(text) from public, anon;
grant execute on function public.financial_get_audit_reconciliation(text) to authenticated, service_role;

commit;

notify pgrst, 'reload schema';
