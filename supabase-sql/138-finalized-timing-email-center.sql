-- FEATURE 138
-- Finalized timing sessions and private local-recipient handoff for the web Email Center.

begin;

create table if not exists public.timing_local_result_recipients (
  event_key text not null,
  session_key text not null,
  result_key text not null,
  recipient_email text not null,
  finalized_by text not null,
  finalized_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (event_key, session_key, result_key),
  foreign key (event_key, session_key, result_key)
    references public.timing_public_local_results(event_key, session_key, result_key)
    on delete cascade
);

create index if not exists timing_local_result_recipients_session_idx
  on public.timing_local_result_recipients(event_key, session_key);

alter table public.timing_local_result_recipients enable row level security;
revoke all on table public.timing_local_result_recipients from public, anon, authenticated;
grant all on table public.timing_local_result_recipients to service_role;
drop policy if exists "No direct timing recipient access" on public.timing_local_result_recipients;
create policy "No direct timing recipient access"
  on public.timing_local_result_recipients
  for all
  to anon, authenticated
  using (false)
  with check (false);

create or replace function public.finalize_timing_local_results(
  p_event jsonb,
  p_results jsonb,
  p_recipients jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  target_event_key text := left(trim(p_event ->> 'event_key'), 160);
  target_session_key text := left(trim(p_event ->> 'session_key'), 160);
  actor text := lower(coalesce(auth.jwt() ->> 'email', ''));
  item jsonb;
  recipient_count integer := 0;
  publish_result jsonb;
begin
  if auth.uid() is null
     or coalesce(public.current_admin_role(), '') not in ('owner', 'timing_staff') then
    raise exception 'Only the owner or authorized timing staff can finalize timing results.';
  end if;
  if target_event_key = '' or target_event_key !~ '^local:' or target_session_key = '' then
    raise exception 'A valid local event and session are required.';
  end if;
  if jsonb_typeof(coalesce(p_recipients, '[]'::jsonb)) <> 'array' then
    raise exception 'p_recipients must be a JSON array.';
  end if;
  if jsonb_array_length(coalesce(p_recipients, '[]'::jsonb)) > 5000 then
    raise exception 'A finalized timing session cannot exceed 5,000 recipients.';
  end if;
  if exists (
    select 1 from public.timing_public_local_events event_row
    where event_row.event_key = target_event_key
      and event_row.session_key = target_session_key
      and event_row.session_status = 'completed'
  ) then
    raise exception 'This local timing session is already finalized.';
  end if;

  publish_result := public.publish_timing_local_snapshot(
    p_event || jsonb_build_object('session_status', 'completed', 'is_live', false),
    p_results
  );

  delete from public.timing_local_result_recipients
  where event_key = target_event_key and session_key = target_session_key;

  for item in select value from jsonb_array_elements(coalesce(p_recipients, '[]'::jsonb))
  loop
    if nullif(trim(item ->> 'result_key'), '') is null
       or nullif(lower(trim(item ->> 'email')), '') is null then
      continue;
    end if;
    if lower(trim(item ->> 'email')) !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      continue;
    end if;
    if not exists (
      select 1 from public.timing_public_local_results result_row
      where result_row.event_key = target_event_key
        and result_row.session_key = target_session_key
        and result_row.result_key = left(trim(item ->> 'result_key'), 160)
    ) then
      continue;
    end if;

    insert into public.timing_local_result_recipients (
      event_key, session_key, result_key, recipient_email,
      finalized_by, finalized_at, updated_at
    ) values (
      target_event_key,
      target_session_key,
      left(trim(item ->> 'result_key'), 160),
      left(lower(trim(item ->> 'email')), 320),
      actor,
      now(),
      now()
    )
    on conflict (event_key, session_key, result_key) do update set
      recipient_email = excluded.recipient_email,
      finalized_by = excluded.finalized_by,
      finalized_at = excluded.finalized_at,
      updated_at = excluded.updated_at;
    recipient_count := recipient_count + 1;
  end loop;

  return publish_result || jsonb_build_object(
    'session_status', 'completed',
    'recipients', recipient_count,
    'finalized_by', actor,
    'finalized_at', now()
  );
end;
$fn$;

create or replace function public.admin_local_timing_result_email_candidates(
  p_event_key text,
  p_session_key text
)
returns table (
  result_key text,
  participant_id uuid,
  reference_number text,
  bib_number text,
  runner_name text,
  email text,
  category_name text,
  age_group_name text,
  wave_name text,
  gun_start_at timestamptz,
  finish_at timestamptz,
  gun_time bigint,
  chip_time bigint,
  overall_sex_place bigint,
  age_group_sex_place bigint,
  award_status text,
  result_status text,
  event_name text,
  event_date text,
  session_name text,
  session_type text
)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor text := lower(coalesce(auth.jwt() ->> 'email', ''));
  actor_role text := coalesce(public.current_admin_role(), '');
begin
  if auth.uid() is null or actor_role not in ('owner', 'timing_staff') then
    raise exception 'Only the owner or authorized timing staff can access finalized result recipients.';
  end if;
  if not exists (
    select 1 from public.timing_public_local_events event_row
    where event_row.event_key = p_event_key
      and event_row.session_key = p_session_key
      and event_row.session_status = 'completed'
      and (actor_role = 'owner' or lower(event_row.published_by) = actor)
  ) then
    raise exception 'This local timing session is not finalized or is not assigned to you.';
  end if;

  return query
  with ranked as (
    select
      result_row.*,
      rank() over (
        partition by result_row.category_name, coalesce(nullif(result_row.sex, ''), 'Unspecified')
        order by result_row.gun_time_seconds, result_row.finish_at, result_row.bib_number
      ) as sex_rank,
      case when result_row.age_group_name is null then null else
        rank() over (
          partition by result_row.category_name, coalesce(nullif(result_row.sex, ''), 'Unspecified'), result_row.age_group_name
          order by result_row.gun_time_seconds, result_row.finish_at, result_row.bib_number
        )
      end as age_rank
    from public.timing_public_local_results result_row
    where result_row.event_key = p_event_key
      and result_row.session_key = p_session_key
      and result_row.finish_at is not null
      and result_row.gun_time_seconds is not null
  )
  select
    ranked.result_key,
    null::uuid,
    null::text,
    ranked.bib_number,
    ranked.runner_name,
    recipient.recipient_email,
    ranked.category_name,
    ranked.age_group_name,
    ranked.wave_name,
    ranked.gun_start_at,
    ranked.finish_at,
    ranked.gun_time_seconds,
    ranked.chip_time_seconds,
    ranked.sex_rank,
    ranked.age_rank,
    coalesce(ranked.award_status, 'Finisher'),
    'finished'::text,
    event_row.event_name,
    event_row.event_date::text,
    event_row.session_name,
    event_row.session_type
  from ranked
  join public.timing_public_local_events event_row
    on event_row.event_key = ranked.event_key
   and event_row.session_key = ranked.session_key
  left join public.timing_local_result_recipients recipient
    on recipient.event_key = ranked.event_key
   and recipient.session_key = ranked.session_key
   and recipient.result_key = ranked.result_key
  order by ranked.category_name, ranked.gun_time_seconds, ranked.bib_number;
end;
$fn$;

create or replace function public.admin_timing_email_sessions()
returns table (
  source text,
  event_key text,
  session_key text,
  event_id text,
  race_session_id uuid,
  event_name text,
  event_date date,
  session_name text,
  session_type text,
  completed_at timestamptz,
  finisher_count bigint,
  categories jsonb,
  sent_count bigint,
  failed_count bigint
)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor text := lower(coalesce(auth.jwt() ->> 'email', ''));
  actor_role text := coalesce(public.current_admin_role(), '');
begin
  if auth.uid() is null or actor_role not in ('owner', 'timing_staff') then
    raise exception 'Only the owner or authorized timing staff can use final result emails.';
  end if;

  return query
  with cloud as (
    select
      'cloud'::text as source,
      'cloud:' || session_row.event_id as event_key,
      session_row.id::text as session_key,
      session_row.event_id,
      session_row.id as race_session_id,
      event_row.name as event_name,
      case when coalesce(event_row.event_date, '') ~ '^\d{4}-\d{2}-\d{2}$'
        then event_row.event_date::date else null end as event_date,
      session_row.name as session_name,
      session_row.session_type,
      coalesce(session_row.ended_at, session_row.updated_at) as completed_at,
      coalesce(result_stats.finisher_count, 0) as finisher_count,
      coalesce(result_stats.categories, '[]'::jsonb) as categories,
      coalesce(log_stats.sent_count, 0) as sent_count,
      coalesce(log_stats.failed_count, 0) as failed_count
    from public.timing_race_sessions session_row
    join public.events event_row on event_row.id = session_row.event_id
    left join lateral (
      select
        count(distinct timing_read.assignment_id) filter (
          where station.station_type = 'finish'
            and timing_read.is_valid
            and not timing_read.is_duplicate
            and timing_read.assignment_id is not null
        ) as finisher_count,
        coalesce(jsonb_agg(distinct assignment.category_name)
          filter (where assignment.category_name is not null), '[]'::jsonb) as categories
      from public.timing_reads timing_read
      left join public.timing_stations station on station.id = timing_read.station_id
      left join public.rfid_assignments assignment on assignment.id = timing_read.assignment_id
      where timing_read.race_session_id = session_row.id
    ) result_stats on true
    left join lateral (
      select
        count(*) filter (where email_log.status = 'sent') as sent_count,
        count(*) filter (where email_log.status = 'failed') as failed_count
      from public.timing_result_email_logs email_log
      where email_log.event_key = 'cloud:' || session_row.event_id
        and email_log.session_key = session_row.id::text
    ) log_stats on true
    where session_row.status = 'completed'
      and public.can_access_timing(session_row.event_id, false)
  ), local as (
    select
      'local'::text,
      local_event.event_key,
      local_event.session_key,
      null::text,
      null::uuid,
      local_event.event_name,
      local_event.event_date,
      local_event.session_name,
      local_event.session_type,
      local_event.updated_at,
      count(local_result.result_key),
      coalesce(jsonb_agg(distinct local_result.category_name)
        filter (where local_result.category_name is not null), '[]'::jsonb),
      count(email_log.result_key) filter (where email_log.status = 'sent'),
      count(email_log.result_key) filter (where email_log.status = 'failed')
    from public.timing_public_local_events local_event
    left join public.timing_public_local_results local_result
      on local_result.event_key = local_event.event_key
     and local_result.session_key = local_event.session_key
    left join public.timing_result_email_logs email_log
      on email_log.event_key = local_event.event_key
     and email_log.session_key = local_event.session_key
     and email_log.result_key = local_result.result_key
    where local_event.session_status = 'completed'
      and (actor_role = 'owner' or lower(local_event.published_by) = actor)
    group by local_event.event_key, local_event.session_key, local_event.event_name,
      local_event.event_date, local_event.session_name, local_event.session_type,
      local_event.updated_at
  )
  select * from cloud
  union all
  select * from local
  order by completed_at desc, event_name, session_name;
end;
$fn$;

create or replace function public.admin_timing_result_email_candidates(
  p_event_id text,
  p_session_id uuid
)
returns table (
  result_key text,
  participant_id uuid,
  reference_number text,
  bib_number text,
  runner_name text,
  email text,
  category_name text,
  age_group_name text,
  wave_name text,
  gun_start_at timestamptz,
  finish_at timestamptz,
  gun_time interval,
  chip_time interval,
  overall_sex_place bigint,
  age_group_sex_place bigint,
  award_status text,
  result_status text,
  event_name text,
  event_date text,
  session_name text,
  session_type text
)
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null
     or coalesce(public.current_admin_role(), '') not in ('owner', 'timing_staff')
     or not public.can_access_timing(p_event_id, false) then
    raise exception 'You are not authorized to email timing results for this event.';
  end if;
  if not exists (
    select 1 from public.timing_race_sessions session_row
    where session_row.id = p_session_id
      and session_row.event_id = p_event_id
      and session_row.status = 'completed'
  ) then
    raise exception 'Finalize this timing session before emailing results.';
  end if;

  return query
  with result_rows as (
    select *
    from public.admin_timing_session_results(p_event_id, p_session_id)
  )
  select
    result.registration_id::text,
    result.registration_id,
    result.reference_number,
    result.bib_number,
    result.runner_name,
    coalesce(registration.email, student.email),
    result.category_name,
    result.age_group_name,
    result.wave_name,
    result.gun_start_at,
    result.finish_at,
    result.gun_time,
    result.chip_time,
    result.overall_sex_place,
    result.age_group_sex_place,
    result.award_status,
    result.result_status,
    event_row.name,
    event_row.event_date,
    race_session.name,
    race_session.session_type
  from result_rows result
  join public.events event_row on event_row.id = p_event_id
  join public.timing_race_sessions race_session
    on race_session.id = p_session_id
   and race_session.event_id = p_event_id
   and race_session.status = 'completed'
  left join lateral (
    select assignment.registration_id, assignment.student_registration_id
    from public.rfid_assignments assignment
    where assignment.event_id = p_event_id
      and assignment.is_active
      and coalesce(assignment.registration_id, assignment.student_registration_id) = result.registration_id
    order by assignment.created_at desc
    limit 1
  ) source_assignment on true
  left join public.registrations registration
    on registration.id = source_assignment.registration_id
  left join public.student_registrations student
    on student.id = source_assignment.student_registration_id
  where result.finish_at is not null
    and result.gun_time is not null
    and result.result_status in ('timed', 'gun_time_only')
  order by result.category_name, result.overall_sex_place nulls last, result.bib_number;
end;
$fn$;

revoke all on function public.finalize_timing_local_results(jsonb, jsonb, jsonb) from public, anon;
revoke all on function public.admin_local_timing_result_email_candidates(text, text) from public, anon;
revoke all on function public.admin_timing_email_sessions() from public, anon;
revoke all on function public.admin_timing_result_email_candidates(text, uuid) from public, anon;

grant execute on function public.finalize_timing_local_results(jsonb, jsonb, jsonb) to authenticated;
grant execute on function public.admin_local_timing_result_email_candidates(text, text) to authenticated, service_role;
grant execute on function public.admin_timing_email_sessions() to authenticated, service_role;
grant execute on function public.admin_timing_result_email_candidates(text, uuid) to authenticated, service_role;

commit;

notify pgrst, 'reload schema';
