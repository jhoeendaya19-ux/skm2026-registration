-- FEATURE 150
-- Apply the documented SKM2026 revenue audit conclusion without altering registrations.

begin;

insert into public.financial_accounts (
  event_id, code, name, account_type, statement_group,
  normal_balance, is_payment_source, is_active, sort_order
) values
  ('skm2026', '4080', 'Revenue Reconciliation Adjustments', 'revenue', 'Event revenue', 'credit', false, true, 115),
  ('skm2026', '2090', 'Unidentified Cash Overage', 'liability', 'Current liabilities', 'credit', false, true, 70)
on conflict (event_id, code) do update set
  name = excluded.name,
  account_type = excluded.account_type,
  statement_group = excluded.statement_group,
  normal_balance = excluded.normal_balance,
  is_payment_source = excluded.is_payment_source,
  is_active = excluded.is_active,
  sort_order = excluded.sort_order;

insert into public.financial_journal_entries (
  event_id, entry_date, entry_kind, source_type, source_id,
  counterparty, description, payment_method, created_by, updated_by, metadata
) values
  (
    'skm2026', date '2026-10-18', 'adjustment', 'audit_reconciliation',
    'skm2026:unsupported-recorded-revenue', 'SKM2026 Revenue Audit',
    'Audit adjustment: recorded revenue not supported by verified collections',
    'Audit reconciliation', 'system:audit-reconciliation', 'system:audit-reconciliation',
    jsonb_build_object(
      'amount', 3372.00,
      'audit_label', 'Recorded revenue not supported by verified collections',
      'system_recorded_revenue', 2538363.73,
      'dashboard_verified_revenue', 2534991.73,
      'unpaid_category_change_balances', 4080.92,
      'supportable_net_revenue', 2530910.81,
      'unidentified_cash_overage', 187.20,
      'supportable_revenue_plus_overage', 2531098.01
    )
  ),
  (
    'skm2026', date '2026-10-18', 'adjustment', 'audit_reconciliation',
    'skm2026:unpaid-category-change-balances', 'SKM2026 Revenue Audit',
    'Audit adjustment: category-change balances not recorded as paid',
    'Audit reconciliation', 'system:audit-reconciliation', 'system:audit-reconciliation',
    jsonb_build_object(
      'amount', 4080.92,
      'audit_label', 'Category-change balances not recorded as paid',
      'system_recorded_revenue', 2538363.73,
      'dashboard_verified_revenue', 2534991.73,
      'unpaid_category_change_balances', 4080.92,
      'supportable_net_revenue', 2530910.81,
      'unidentified_cash_overage', 187.20,
      'supportable_revenue_plus_overage', 2531098.01
    )
  ),
  (
    'skm2026', date '2026-10-18', 'adjustment', 'audit_reconciliation',
    'skm2026:unidentified-cash-overage', 'SKM2026 Revenue Audit',
    'Audit reconciliation: unidentified cash overage',
    'Cash count', 'system:audit-reconciliation', 'system:audit-reconciliation',
    jsonb_build_object(
      'amount', 187.20,
      'audit_label', 'Unidentified cash overage',
      'system_recorded_revenue', 2538363.73,
      'dashboard_verified_revenue', 2534991.73,
      'unpaid_category_change_balances', 4080.92,
      'supportable_net_revenue', 2530910.81,
      'unidentified_cash_overage', 187.20,
      'supportable_revenue_plus_overage', 2531098.01
    )
  )
on conflict (event_id, source_type, source_id) where source_id is not null do nothing;

insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo)
select entry.id, 1, account.id, (entry.metadata ->> 'amount')::numeric, 0, entry.description
from public.financial_journal_entries entry
join public.financial_accounts account
  on account.event_id = entry.event_id and account.code = '4080'
where entry.event_id = 'skm2026'
  and entry.source_type = 'audit_reconciliation'
  and entry.source_id in ('skm2026:unsupported-recorded-revenue', 'skm2026:unpaid-category-change-balances')
  and not exists (
    select 1 from public.financial_journal_lines line
    where line.entry_id = entry.id and line.line_number = 1
  );

insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo)
select entry.id, 2, account.id, 0, (entry.metadata ->> 'amount')::numeric, 'Reduce unsupported Cash on Hand'
from public.financial_journal_entries entry
join public.financial_accounts account
  on account.event_id = entry.event_id and account.code = '1010'
where entry.event_id = 'skm2026'
  and entry.source_type = 'audit_reconciliation'
  and entry.source_id in ('skm2026:unsupported-recorded-revenue', 'skm2026:unpaid-category-change-balances')
  and not exists (
    select 1 from public.financial_journal_lines line
    where line.entry_id = entry.id and line.line_number = 2
  );

insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo)
select entry.id, 1, account.id, (entry.metadata ->> 'amount')::numeric, 0, 'Unidentified cash counted'
from public.financial_journal_entries entry
join public.financial_accounts account
  on account.event_id = entry.event_id and account.code = '1010'
where entry.event_id = 'skm2026'
  and entry.source_type = 'audit_reconciliation'
  and entry.source_id = 'skm2026:unidentified-cash-overage'
  and not exists (
    select 1 from public.financial_journal_lines line
    where line.entry_id = entry.id and line.line_number = 1
  );

insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo)
select entry.id, 2, account.id, 0, (entry.metadata ->> 'amount')::numeric, 'Pending identification or disposition'
from public.financial_journal_entries entry
join public.financial_accounts account
  on account.event_id = entry.event_id and account.code = '2090'
where entry.event_id = 'skm2026'
  and entry.source_type = 'audit_reconciliation'
  and entry.source_id = 'skm2026:unidentified-cash-overage'
  and not exists (
    select 1 from public.financial_journal_lines line
    where line.entry_id = entry.id and line.line_number = 2
  );

create or replace function public.financial_get_audit_reconciliation(
  p_event_id text default 'skm2026'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  supportable_revenue numeric(14,2) := 0;
  cash_after_overage numeric(14,2) := 0;
begin
  if auth.uid() is null or coalesce(public.current_admin_role(), '') <> 'owner' then
    raise exception 'Only the owner account can access SKM2026 financials.';
  end if;
  if p_event_id <> 'skm2026' then
    raise exception 'This financial workspace is limited to SKM2026.';
  end if;

  select round(coalesce(sum(line.credit - line.debit), 0), 2)
  into supportable_revenue
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
    'supportable_net_revenue', supportable_revenue,
    'unidentified_cash_overage', 187.20,
    'supportable_revenue_plus_overage', cash_after_overage
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

revoke all on function public.financial_get_audit_reconciliation(text) from public, anon;
grant execute on function public.financial_get_audit_reconciliation(text) to authenticated, service_role;

revoke all on function public.financial_list_entries(text, text, text, text, date, date, integer, integer) from public, anon;
grant execute on function public.financial_list_entries(text, text, text, text, date, date, integer, integer) to authenticated, service_role;

commit;

notify pgrst, 'reload schema';
