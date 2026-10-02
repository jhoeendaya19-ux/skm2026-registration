create or replace function public.public_timing_runner_detail(
  p_event_key text,
  p_session_key text,
  p_bib_number text
)
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
  overall_place bigint,
  sex_place bigint,
  age_group_place bigint,
  overall_field_size bigint,
  sex_field_size bigint,
  age_group_field_size bigint,
  award_status text
)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  with leaderboard as (
    select *
    from public.public_timing_leaderboard(p_event_key, p_session_key)
  ), detailed as (
    select
      leaderboard.*,
      count(*) over (partition by leaderboard.category_name) as overall_size,
      count(*) over (partition by leaderboard.category_name, leaderboard.sex) as sex_size,
      case when leaderboard.age_group_name is null then 0::bigint else
        count(*) over (
          partition by leaderboard.category_name, leaderboard.sex, leaderboard.age_group_name
        )
      end as age_group_size
    from leaderboard
  )
  select
    detailed.bib_number,
    detailed.runner_name,
    detailed.sex,
    detailed.category_name,
    detailed.age_group_name,
    detailed.wave_name,
    detailed.gun_start_at,
    detailed.finish_at,
    detailed.gun_time_seconds,
    detailed.overall_place,
    detailed.sex_place,
    detailed.age_group_place,
    detailed.overall_size,
    detailed.sex_size,
    detailed.age_group_size,
    detailed.award_status
  from detailed
  where nullif(trim(coalesce(p_bib_number, '')), '') is not null
    and lower(trim(detailed.bib_number)) = lower(trim(p_bib_number))
  order by detailed.finish_at
  limit 1;
$$;

revoke all on function public.public_timing_runner_detail(text, text, text) from public;
grant execute on function public.public_timing_runner_detail(text, text, text) to anon, authenticated, service_role;

comment on function public.public_timing_runner_detail(text, text, text) is
  'Returns one runner result card for an active or completed public timing session.';
