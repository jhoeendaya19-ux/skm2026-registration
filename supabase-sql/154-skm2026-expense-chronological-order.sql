-- FEATURE 154
-- Return expense statement transactions latest to earliest within each activity.

begin;

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
    'rows', coalesce(jsonb_agg(to_jsonb(expense_rows)
      order by activity_sort_order nulls first, entry_date desc, entry_number desc), '[]'::jsonb)
  ) into result
  from expense_rows;

  return result;
end;
$fn$;

revoke all on function public.financial_expense_statement_details(text, date, date) from public, anon;
grant execute on function public.financial_expense_statement_details(text, date, date) to authenticated, service_role;

commit;

notify pgrst, 'reload schema';
