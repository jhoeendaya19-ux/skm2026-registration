-- Keep test and dry-run history available to timing staff, but publish only
-- official race sessions on the public results websites.

create or replace function public.public_timing_result_events()
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
language sql
stable
security definer
set search_path = public
as $fn$
  with cloud_sessions as (
    select
      'cloud:' || e.id as event_key,
      s.id::text as session_key,
      e.name as event_name,
      case when coalesce(e.event_date, '') ~ '^\d{4}-\d{2}-\d{2}$'
        then e.event_date::date else null end as event_date,
      nullif(trim(e.venue), '') as venue,
      s.name as session_name,
      s.session_type,
      s.status as session_status,
      s.status = 'active' as is_live,
      coalesce(read_stats.finisher_count, 0) as finisher_count,
      coalesce(assignment_stats.category_count, 0) as category_count,
      coalesce(wave_stats.waves_started, 0) as waves_started,
      read_stats.last_result_at,
      greatest(s.updated_at, coalesce(read_stats.last_update_at, s.updated_at)) as updated_at
    from public.events e
    join public.timing_race_sessions s on s.event_id = e.id
    left join lateral (
      select
        count(distinct timing_read.assignment_id) filter (
          where station.station_type = 'finish'
            and timing_read.is_valid and not timing_read.is_duplicate
            and timing_read.assignment_id is not null
        ) as finisher_count,
        max(timing_read.read_at) filter (
          where station.station_type = 'finish'
            and timing_read.is_valid and not timing_read.is_duplicate
        ) as last_result_at,
        max(timing_read.read_at) as last_update_at
      from public.timing_reads timing_read
      left join public.timing_stations station on station.id = timing_read.station_id
      where timing_read.race_session_id = s.id
    ) read_stats on true
    left join lateral (
      select count(distinct assignment.category_name) as category_count
      from public.rfid_assignments assignment
      where assignment.event_id = e.id and assignment.is_active
    ) assignment_stats on true
    left join lateral (
      select count(distinct wave_start.wave_id) as waves_started
      from public.timing_session_wave_starts wave_start
      where wave_start.session_id = s.id
    ) wave_stats on true
    where s.status in ('active', 'completed')
      and s.session_type = 'official'
  ), local_sessions as (
    select
      local_event.event_key,
      local_event.session_key,
      local_event.event_name,
      local_event.event_date,
      local_event.venue,
      local_event.session_name,
      local_event.session_type,
      local_event.session_status,
      local_event.is_live,
      count(local_result.result_key) as finisher_count,
      count(distinct local_result.category_name) as category_count,
      count(distinct local_result.wave_name) filter (
        where local_result.gun_start_at is not null
      ) as waves_started,
      max(local_result.finish_at) as last_result_at,
      local_event.updated_at
    from public.timing_public_local_events local_event
    left join public.timing_public_local_results local_result
      on local_result.event_key = local_event.event_key
     and local_result.session_key = local_event.session_key
    where local_event.session_status in ('active', 'completed')
      and local_event.session_type = 'official'
    group by local_event.event_key, local_event.session_key, local_event.event_name,
      local_event.event_date, local_event.venue, local_event.session_name,
      local_event.session_type, local_event.session_status, local_event.is_live,
      local_event.updated_at
  )
  select * from cloud_sessions
  union all
  select * from local_sessions
  order by event_date desc nulls last, is_live desc, updated_at desc, event_name;
$fn$;

revoke all on function public.public_timing_result_events() from public;
grant execute on function public.public_timing_result_events() to anon, authenticated;
