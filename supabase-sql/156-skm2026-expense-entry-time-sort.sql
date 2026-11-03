begin;

drop function if exists public.financial_list_entries(text, text, text, text, date, date, integer, integer, text, uuid, text, numeric, numeric);

create function public.financial_list_entries(
  p_event_id text default 'skm2026',
  p_kind text default null,
  p_status text default null,
  p_search text default null,
  p_start_date date default null,
  p_end_date date default null,
  p_limit integer default 50,
  p_offset integer default 0,
  p_expense_account_code text default null,
  p_activity_category_id uuid default null,
  p_payment_account_code text default null,
  p_min_amount numeric default null,
  p_max_amount numeric default null,
  p_sort text default 'expense_date'
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
  if coalesce(p_sort, 'expense_date') not in ('expense_date', 'created_at') then
    raise exception 'Unsupported financial entry sort order.';
  end if;
  if p_start_date is not null and p_end_date is not null and p_start_date > p_end_date then
    raise exception 'The start date cannot be later than the end date.';
  end if;
  if coalesce(p_min_amount, 0) < 0 or coalesce(p_max_amount, 0) < 0 then
    raise exception 'Amount filters cannot be negative.';
  end if;
  if p_min_amount is not null and p_max_amount is not null and p_min_amount > p_max_amount then
    raise exception 'The minimum amount cannot be greater than the maximum amount.';
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
    select *
    from summarized
    where (nullif(trim(coalesce(p_kind, '')), '') is null or entry_kind = p_kind)
      and (nullif(trim(coalesce(p_status, '')), '') is null or status = p_status)
      and (p_start_date is null or entry_date >= p_start_date)
      and (p_end_date is null or entry_date <= p_end_date)
      and (nullif(trim(coalesce(p_expense_account_code, '')), '') is null or account_code = trim(p_expense_account_code))
      and (p_activity_category_id is null or activity_category_id = p_activity_category_id)
      and (nullif(trim(coalesce(p_payment_account_code, '')), '') is null or payment_account_code = trim(p_payment_account_code))
      and (p_min_amount is null or amount >= p_min_amount)
      and (p_max_amount is null or amount <= p_max_amount)
      and (
        nullif(trim(coalesce(p_search, '')), '') is null
        or counterparty ilike '%' || trim(p_search) || '%'
        or expense_item ilike '%' || trim(p_search) || '%'
        or coalesce(activity_category_name, '') ilike '%' || trim(p_search) || '%'
        or coalesce(account_name, '') ilike '%' || trim(p_search) || '%'
        or coalesce(account_code, '') ilike '%' || trim(p_search) || '%'
        or coalesce(payment_account_name, '') ilike '%' || trim(p_search) || '%'
        or coalesce(payment_method, '') ilike '%' || trim(p_search) || '%'
        or description ilike '%' || trim(p_search) || '%'
        or coalesce(metadata ->> 'reference_number', '') ilike '%' || trim(p_search) || '%'
        or coalesce(metadata ->> 'bib_number', '') ilike '%' || trim(p_search) || '%'
      )
  ), paged as (
    select *
    from filtered
    order by
      case when coalesce(p_sort, 'expense_date') = 'created_at' then created_at end desc,
      case when coalesce(p_sort, 'expense_date') = 'expense_date' then entry_date end desc,
      entry_number desc
    limit least(greatest(coalesce(p_limit, 50), 1), 100)
    offset greatest(coalesce(p_offset, 0), 0)
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'total_amount', (select round(coalesce(sum(amount), 0), 2) from filtered),
    'rows', coalesce((select jsonb_agg(to_jsonb(paged) order by
      case when coalesce(p_sort, 'expense_date') = 'created_at' then created_at end desc,
      case when coalesce(p_sort, 'expense_date') = 'expense_date' then entry_date end desc,
      entry_number desc
    ) from paged), '[]'::jsonb)
  ) into result;

  return result;
end;
$fn$;

revoke all on function public.financial_list_entries(text, text, text, text, date, date, integer, integer, text, uuid, text, numeric, numeric, text) from public, anon;
grant execute on function public.financial_list_entries(text, text, text, text, date, date, integer, integer, text, uuid, text, numeric, numeric, text) to authenticated, service_role;

commit;

notify pgrst, 'reload schema';
