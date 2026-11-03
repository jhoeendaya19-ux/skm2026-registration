begin;

-- Preserve the existing result implementations behind owner-only function ACLs.
alter function public.public_timing_result_events() rename to staff_timing_result_events_internal;
alter function public.public_timing_leaderboard(text, text) rename to staff_timing_leaderboard_internal;

revoke all on function public.staff_timing_result_events_internal() from public, anon, authenticated;
revoke all on function public.staff_timing_leaderboard_internal(text, text) from public, anon, authenticated;

create function public.public_timing_result_events()
returns table (
  event_key text,
  session_key text,
  event_name text,
  event_date date,
  venue text,
  session_name text,
  session_type text,
  session_status text,
  is_live boolean,
  finisher_count bigint,
  category_count bigint,
  waves_started bigint,
  last_result_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not (
    (auth.uid() is not null and coalesce(public.current_admin_role(), '') in ('owner', 'timing_staff'))
    or coalesce(auth.jwt() ->> 'role', '') = 'service_role'
  ) then
    raise exception 'Only the owner or authorized timing staff can access timing results.';
  end if;

  return query select * from public.staff_timing_result_events_internal();
end;
$fn$;

create function public.public_timing_leaderboard(p_event_key text, p_session_key text)
returns table (
  bib_number text,
  runner_name text,
  sex text,
  category_name text,
  age_group_name text,
  wave_name text,
  gun_start_at timestamptz,
  finish_at timestamptz,
  gun_time_seconds bigint,
  chip_time_seconds bigint,
  overall_place bigint,
  sex_place bigint,
  age_group_place bigint,
  award_status text
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not (
    (auth.uid() is not null and coalesce(public.current_admin_role(), '') in ('owner', 'timing_staff'))
    or coalesce(auth.jwt() ->> 'role', '') = 'service_role'
  ) then
    raise exception 'Only the owner or authorized timing staff can access timing results.';
  end if;

  return query
  select * from public.staff_timing_leaderboard_internal(p_event_key, p_session_key);
end;
$fn$;

revoke all on function public.public_timing_result_events() from public, anon;
revoke all on function public.public_timing_leaderboard(text, text) from public, anon;
revoke all on function public.public_timing_runner_detail(text, text, text) from public, anon;

grant execute on function public.public_timing_result_events() to authenticated, service_role;
grant execute on function public.public_timing_leaderboard(text, text) to authenticated, service_role;
grant execute on function public.public_timing_runner_detail(text, text, text) to authenticated, service_role;

commit;

notify pgrst, 'reload schema';
