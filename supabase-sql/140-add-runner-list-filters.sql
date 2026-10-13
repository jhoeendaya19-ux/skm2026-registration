drop function if exists public.skm2026_public_runner_list();

create function public.skm2026_public_runner_list(
  p_category text default null,
  p_sex text default null,
  p_age_group text default null,
  p_runner_group text default null
)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog
as $$
  with raw_runners as (
    select
      nullif(btrim(r.full_name), '') as runner_name,
      btrim(r.bib_number) as bib_number,
      btrim(r.race_category) as category,
      case lower(btrim(coalesce(r.sex, '')))
        when 'male' then 'Male'
        when 'female' then 'Female'
        else 'Unspecified'
      end as sex,
      case when r.age_on_race_day between 1 and 100 then r.age_on_race_day else null end as runner_age,
      r.category_id,
      case when lower(coalesce(r.race_category, '')) like '%virtual%' then 'Virtual' else 'Standard' end as runner_group
    from public.registrations r
    where r.event_id = 'skm2026'
      and r.payment_status = 'approved'
      and r.voided_at is null
      and coalesce(r.is_test_registration, false) = false
      and nullif(btrim(r.full_name), '') is not null
      and nullif(btrim(r.bib_number), '') is not null

    union all

    select
      nullif(btrim(concat_ws(' ', sr.first_name, sr.last_name)), '') as runner_name,
      btrim(sr.bib_number) as bib_number,
      btrim(sr.distance) as category,
      case lower(btrim(coalesce(sr.sex, '')))
        when 'male' then 'Male'
        when 'female' then 'Female'
        else 'Unspecified'
      end as sex,
      case
        when date_part('year', age(date '2026-10-18', sr.birth_date))::integer between 1 and 100
          then date_part('year', age(date '2026-10-18', sr.birth_date))::integer
        else null
      end as runner_age,
      null::uuid as category_id,
      'Student'::text as runner_group
    from public.student_registrations sr
    where sr.status = 'active'
      and nullif(btrim(concat_ws(' ', sr.first_name, sr.last_name)), '') is not null
      and nullif(btrim(sr.bib_number), '') is not null
  ),
  official_runners as (
    select
      rr.runner_name,
      rr.bib_number,
      rr.category,
      rr.sex,
      rr.runner_group,
      coalesce((
        select tag.name
        from public.timing_age_groups tag
        where tag.event_id = 'skm2026'
          and tag.is_active
          and rr.runner_age between tag.minimum_age and tag.maximum_age
          and (tag.category_id is null or tag.category_id = rr.category_id)
        order by case when tag.category_id = rr.category_id then 0 else 1 end, tag.sort_order
        limit 1
      ), 'Unspecified') as age_group
    from raw_runners rr
  ),
  filtered_runners as (
    select *
    from official_runners r
    where (nullif(btrim(p_category), '') is null or lower(r.category) = lower(btrim(p_category)))
      and (nullif(btrim(p_sex), '') is null or lower(r.sex) = lower(btrim(p_sex)))
      and (nullif(btrim(p_age_group), '') is null or lower(r.age_group) = lower(btrim(p_age_group)))
      and (nullif(btrim(p_runner_group), '') is null or lower(r.runner_group) = lower(btrim(p_runner_group)))
  )
  select jsonb_build_object(
    'generated_at', current_timestamp,
    'total', (select count(*) from official_runners),
    'filtered_total', (select count(*) from filtered_runners),
    'filters', jsonb_build_object(
      'categories', coalesce((
        select jsonb_agg(category order by
          case
            when upper(category) = '42K' then 1 when upper(category) = '42K VIRTUAL' then 2
            when upper(category) = '21K' then 3 when upper(category) = '21K VIRTUAL' then 4
            when upper(category) = '10K' then 5 when upper(category) = '10K VIRTUAL' then 6
            when upper(category) = '5K' then 7 when upper(category) = '5K VIRTUAL' then 8
            when upper(category) = '3K' then 9 else 99 end,
          category)
        from (select distinct category from official_runners where nullif(category, '') is not null) c
      ), '[]'::jsonb),
      'sexes', coalesce((
        select jsonb_agg(sex order by case sex when 'Male' then 1 when 'Female' then 2 else 3 end)
        from (select distinct sex from official_runners) s
      ), '[]'::jsonb),
      'age_groups', coalesce((
        select jsonb_agg(age_group order by
          case age_group
            when '18 and Below' then 1 when '19 to 29' then 2 when '30 to 39' then 3
            when '40 to 49' then 4 when '50 to 59' then 5 when '60 and Above' then 6 else 99 end)
        from (select distinct age_group from official_runners) a
      ), '[]'::jsonb),
      'runner_groups', coalesce((
        select jsonb_agg(runner_group order by case runner_group when 'Standard' then 1 when 'Student' then 2 else 3 end)
        from (select distinct runner_group from official_runners) g
      ), '[]'::jsonb)
    ),
    'runners', coalesce((
      select jsonb_agg(
        jsonb_build_object('name', runner_name, 'bib_number', bib_number)
        order by lower(runner_name), bib_number collate "C"
      )
      from filtered_runners
    ), '[]'::jsonb)
  );
$$;

revoke all on function public.skm2026_public_runner_list(text, text, text, text) from public;
grant execute on function public.skm2026_public_runner_list(text, text, text, text) to anon, authenticated, service_role;

comment on function public.skm2026_public_runner_list(text, text, text, text) is
  'Public, read-only SKM 2026 directory with server-side category, sex, age-group, and runner-group filtering. Runner rows expose only name and bib number.';

