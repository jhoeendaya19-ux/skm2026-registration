-- FEATURE 160
-- Owner-only read model for the line items behind manual revenue adjustments.

begin;

create or replace function public.financial_revenue_adjustment_statement_details(
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
  if p_event_id <> 'skm2026' then
    raise exception 'This financial workspace is limited to SKM2026.';
  end if;
  if p_start_date is not null and p_end_date is not null and p_start_date > p_end_date then
    raise exception 'The start date cannot be after the end date.';
  end if;

  with adjustment_rows as (
    select
      entry.id,
      entry.entry_number,
      entry.entry_date,
      coalesce(nullif(entry.metadata ->> 'direction', ''), case when sum(line.credit - line.debit) < 0 then 'deduct' else 'add' end) as direction,
      coalesce(nullif(entry.metadata ->> 'line_item', ''), nullif(entry.expense_item, ''), nullif(entry.counterparty, ''), 'Revenue adjustment') as line_item,
      coalesce(nullif(entry.metadata ->> 'justification', ''), nullif(entry.description, ''), '') as justification,
      round(sum(line.credit - line.debit), 2) as amount
    from public.financial_journal_entries entry
    join public.financial_journal_lines line on line.entry_id = entry.id
    join public.financial_accounts account on account.id = line.account_id and account.account_type = 'revenue'
    where entry.event_id = p_event_id
      and entry.entry_kind = 'revenue'
      and entry.source_type = 'manual_revenue_adjustment'
      and entry.status = 'posted'
      and (p_start_date is null or entry.entry_date >= p_start_date)
      and (p_end_date is null or entry.entry_date <= p_end_date)
    group by entry.id
  )
  select jsonb_build_object(
    'rows', coalesce(jsonb_agg(to_jsonb(adjustment_rows) order by entry_date desc, entry_number desc), '[]'::jsonb)
  ) into result
  from adjustment_rows;

  return result;
end;
$fn$;

revoke all on function public.financial_revenue_adjustment_statement_details(text, date, date) from public, anon;
grant execute on function public.financial_revenue_adjustment_statement_details(text, date, date) to authenticated, service_role;

commit;

notify pgrst, 'reload schema';
