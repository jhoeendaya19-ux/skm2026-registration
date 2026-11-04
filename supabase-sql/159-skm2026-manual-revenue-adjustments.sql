begin;

insert into public.financial_accounts (
  event_id, code, name, account_type, statement_group, normal_balance,
  is_payment_source, is_active, sort_order
)
values (
  'skm2026', '4070', 'Manual Revenue Adjustments', 'revenue',
  'Event revenue', 'credit', false, true, 160
)
on conflict (event_id, code) do update
set name = excluded.name,
    account_type = excluded.account_type,
    statement_group = excluded.statement_group,
    normal_balance = excluded.normal_balance,
    is_payment_source = excluded.is_payment_source,
    is_active = true,
    sort_order = excluded.sort_order;

create or replace function public.financial_create_revenue_adjustment(
  p_event_id text,
  p_entry_date date,
  p_direction text,
  p_line_item text,
  p_amount numeric,
  p_justification text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  entry_id uuid := gen_random_uuid();
  cash_account_id uuid;
  revenue_account_id uuid;
  normalized_direction text := lower(trim(coalesce(p_direction, '')));
  normalized_amount numeric(14,2) := round(coalesce(p_amount, 0), 2);
begin
  if auth.uid() is null or coalesce(public.current_admin_role(), '') <> 'owner' then
    raise exception 'Only the owner account can adjust SKM2026 revenue.';
  end if;
  if p_event_id <> 'skm2026' then raise exception 'This financial workspace is limited to SKM2026.'; end if;
  if p_entry_date is null then raise exception 'Adjustment date is required.'; end if;
  if normalized_direction not in ('add', 'deduct') then raise exception 'Choose whether to add or deduct revenue.'; end if;
  if length(trim(coalesce(p_line_item, ''))) < 2 then raise exception 'A revenue line item or provision is required.'; end if;
  if normalized_amount <= 0 then raise exception 'Adjustment amount must be greater than zero.'; end if;
  if length(trim(coalesce(p_justification, ''))) < 5 then raise exception 'A clear justification is required.'; end if;

  select id into cash_account_id
  from public.financial_accounts
  where event_id = p_event_id and code = '1010' and is_payment_source and is_active;

  select id into revenue_account_id
  from public.financial_accounts
  where event_id = p_event_id and code = '4070' and account_type = 'revenue' and is_active;

  if cash_account_id is null or revenue_account_id is null then
    raise exception 'The financial adjustment accounts are not configured.';
  end if;

  insert into public.financial_journal_entries (
    id, event_id, entry_date, entry_kind, source_type, source_id,
    counterparty, expense_item, description, payment_method,
    created_by, updated_by, metadata
  ) values (
    entry_id, p_event_id, p_entry_date, 'revenue', 'manual_revenue_adjustment', entry_id::text,
    left(trim(p_line_item), 240), left(trim(p_line_item), 160), left(trim(p_justification), 1000),
    'registration_and_other_revenue', actor_email, actor_email,
    jsonb_build_object(
      'direction', normalized_direction,
      'line_item', left(trim(p_line_item), 160),
      'justification', left(trim(p_justification), 1000),
      'amount', normalized_amount
    )
  );

  if normalized_direction = 'add' then
    insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo) values
      (entry_id, 1, cash_account_id, normalized_amount, 0, 'Registration and Other Sources of Revenues'),
      (entry_id, 2, revenue_account_id, 0, normalized_amount, left(trim(p_line_item), 500));
  else
    insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo) values
      (entry_id, 1, revenue_account_id, normalized_amount, 0, left(trim(p_line_item), 500)),
      (entry_id, 2, cash_account_id, 0, normalized_amount, 'Registration and Other Sources of Revenues');
  end if;

  insert into public.financial_audit_log (event_id, entry_id, action, actor_id, actor_email, details)
  values (
    p_event_id, entry_id, 'revenue_adjustment_created', auth.uid(), actor_email,
    jsonb_build_object(
      'direction', normalized_direction,
      'line_item', left(trim(p_line_item), 160),
      'amount', normalized_amount,
      'justification', left(trim(p_justification), 1000)
    )
  );

  return jsonb_build_object('id', entry_id, 'status', 'posted');
end;
$fn$;

create or replace function public.financial_update_revenue_adjustment(
  p_entry_id uuid,
  p_entry_date date,
  p_direction text,
  p_line_item text,
  p_amount numeric,
  p_justification text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  target public.financial_journal_entries%rowtype;
  previous jsonb;
  cash_account_id uuid;
  revenue_account_id uuid;
  normalized_direction text := lower(trim(coalesce(p_direction, '')));
  normalized_amount numeric(14,2) := round(coalesce(p_amount, 0), 2);
begin
  if auth.uid() is null or coalesce(public.current_admin_role(), '') <> 'owner' then
    raise exception 'Only the owner account can update SKM2026 revenue adjustments.';
  end if;

  select * into target
  from public.financial_journal_entries
  where id = p_entry_id and event_id = 'skm2026'
    and source_type = 'manual_revenue_adjustment'
    and entry_kind = 'revenue' and status = 'posted'
  for update;

  if target.id is null then raise exception 'This posted revenue adjustment was not found.'; end if;
  if p_entry_date is null then raise exception 'Adjustment date is required.'; end if;
  if normalized_direction not in ('add', 'deduct') then raise exception 'Choose whether to add or deduct revenue.'; end if;
  if length(trim(coalesce(p_line_item, ''))) < 2 then raise exception 'A revenue line item or provision is required.'; end if;
  if normalized_amount <= 0 then raise exception 'Adjustment amount must be greater than zero.'; end if;
  if length(trim(coalesce(p_justification, ''))) < 5 then raise exception 'A clear justification is required.'; end if;

  previous := to_jsonb(target);

  select id into cash_account_id
  from public.financial_accounts
  where event_id = target.event_id and code = '1010' and is_payment_source and is_active;

  select id into revenue_account_id
  from public.financial_accounts
  where event_id = target.event_id and code = '4070' and account_type = 'revenue' and is_active;

  if cash_account_id is null or revenue_account_id is null then
    raise exception 'The financial adjustment accounts are not configured.';
  end if;

  update public.financial_journal_entries
  set entry_date = p_entry_date,
      counterparty = left(trim(p_line_item), 240),
      expense_item = left(trim(p_line_item), 160),
      description = left(trim(p_justification), 1000),
      payment_method = 'registration_and_other_revenue',
      metadata = jsonb_build_object(
        'direction', normalized_direction,
        'line_item', left(trim(p_line_item), 160),
        'justification', left(trim(p_justification), 1000),
        'amount', normalized_amount
      ),
      updated_at = now(),
      updated_by = actor_email
  where id = p_entry_id;

  delete from public.financial_journal_lines where entry_id = p_entry_id;

  if normalized_direction = 'add' then
    insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo) values
      (p_entry_id, 1, cash_account_id, normalized_amount, 0, 'Registration and Other Sources of Revenues'),
      (p_entry_id, 2, revenue_account_id, 0, normalized_amount, left(trim(p_line_item), 500));
  else
    insert into public.financial_journal_lines (entry_id, line_number, account_id, debit, credit, memo) values
      (p_entry_id, 1, revenue_account_id, normalized_amount, 0, left(trim(p_line_item), 500)),
      (p_entry_id, 2, cash_account_id, 0, normalized_amount, 'Registration and Other Sources of Revenues');
  end if;

  insert into public.financial_audit_log (event_id, entry_id, action, actor_id, actor_email, details)
  values (
    target.event_id, p_entry_id, 'revenue_adjustment_updated', auth.uid(), actor_email,
    jsonb_build_object(
      'previous', previous,
      'direction', normalized_direction,
      'line_item', left(trim(p_line_item), 160),
      'amount', normalized_amount,
      'justification', left(trim(p_justification), 1000)
    )
  );

  return jsonb_build_object('id', p_entry_id, 'status', 'posted');
end;
$fn$;

revoke all on function public.financial_create_revenue_adjustment(text, date, text, text, numeric, text) from public, anon;
revoke all on function public.financial_update_revenue_adjustment(uuid, date, text, text, numeric, text) from public, anon;
grant execute on function public.financial_create_revenue_adjustment(text, date, text, text, numeric, text) to authenticated, service_role;
grant execute on function public.financial_update_revenue_adjustment(uuid, date, text, text, numeric, text) to authenticated, service_role;

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
  manual_adjustments numeric(14,2) := 0;
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
    round(coalesce(sum(line.credit - line.debit) filter (
      where entry.source_type = 'manual_revenue_adjustment'
    ), 0), 2),
    round(coalesce(sum(line.credit - line.debit), 0), 2)
  into registration_revenue, student_revenue, marketplace_revenue, manual_adjustments, supportable_revenue
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
    'manual_revenue_adjustments', manual_adjustments,
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
