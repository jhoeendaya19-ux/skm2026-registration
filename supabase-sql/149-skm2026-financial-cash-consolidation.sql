-- FEATURE 149
-- Consolidate all SKM2026 collected funds into Cash on Hand.

begin;

update public.financial_journal_lines line
set account_id = cash_account.id
from public.financial_accounts source_account
cross join public.financial_accounts cash_account
where line.account_id = source_account.id
  and source_account.event_id = 'skm2026'
  and source_account.code in ('1020', '1030', '1090')
  and cash_account.event_id = 'skm2026'
  and cash_account.code = '1010';

update public.financial_accounts
set is_active = false,
    is_payment_source = false
where event_id = 'skm2026'
  and code in ('1020', '1030', '1090');

create or replace function public.financial_payment_account_code(p_method text)
returns text
language sql
immutable
set search_path = public
as $fn$
  select '1010'::text;
$fn$;

revoke all on function public.financial_payment_account_code(text) from public, anon, authenticated;
grant execute on function public.financial_payment_account_code(text) to service_role;

commit;

notify pgrst, 'reload schema';
