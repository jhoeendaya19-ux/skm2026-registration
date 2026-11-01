-- FEATURE 153
-- Let the owner extend the SKM2026 chart of expense accounts safely.

begin;

create or replace function public.financial_create_expense_account(
  p_event_id text,
  p_code text,
  p_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  clean_code text := trim(coalesce(p_code, ''));
  clean_name text := trim(coalesce(p_name, ''));
  account_id uuid;
begin
  if auth.uid() is null or coalesce(public.current_admin_role(), '') <> 'owner' then
    raise exception 'Only the owner account can create expense accounts.';
  end if;
  if p_event_id <> 'skm2026' then
    raise exception 'This financial workspace is limited to SKM2026.';
  end if;
  if clean_code !~ '^5[0-9]{3}$' then
    raise exception 'Expense account code must contain four digits and begin with 5.';
  end if;
  if length(clean_name) < 3 or length(clean_name) > 160 then
    raise exception 'Expense account name must contain 3 to 160 characters.';
  end if;
  if exists (
    select 1 from public.financial_accounts
    where event_id = p_event_id and code = clean_code
  ) then
    raise exception 'Expense account code % already exists.', clean_code;
  end if;
  if exists (
    select 1 from public.financial_accounts
    where event_id = p_event_id and account_type = 'expense' and lower(name) = lower(clean_name)
  ) then
    raise exception 'An expense account named % already exists.', clean_name;
  end if;

  insert into public.financial_accounts (
    event_id, code, name, account_type, statement_group,
    normal_balance, is_payment_source, is_active, sort_order
  ) values (
    p_event_id, clean_code, clean_name, 'expense', 'Operating expenses',
    'debit', false, true, clean_code::integer
  )
  returning id into account_id;

  insert into public.financial_audit_log (event_id, action, actor_id, actor_email, details)
  values (p_event_id, 'expense_account_created', auth.uid(), actor_email, jsonb_build_object(
    'account_id', account_id,
    'code', clean_code,
    'name', clean_name
  ));

  return jsonb_build_object(
    'id', account_id,
    'code', clean_code,
    'name', clean_name,
    'account_type', 'expense',
    'statement_group', 'Operating expenses',
    'is_payment_source', false
  );
end;
$fn$;

revoke all on function public.financial_create_expense_account(text, text, text) from public, anon;
grant execute on function public.financial_create_expense_account(text, text, text) to authenticated, service_role;

commit;

notify pgrst, 'reload schema';
