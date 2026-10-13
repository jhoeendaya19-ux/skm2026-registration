create or replace function public.skm2026_public_runner_list()
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog
as $$
  with official_runners as (
    select
      nullif(btrim(r.full_name), '') as runner_name,
      btrim(r.bib_number) as bib_number
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
      btrim(sr.bib_number) as bib_number
    from public.student_registrations sr
    where sr.status = 'active'
      and nullif(btrim(concat_ws(' ', sr.first_name, sr.last_name)), '') is not null
      and nullif(btrim(sr.bib_number), '') is not null
  )
  select jsonb_build_object(
    'generated_at', current_timestamp,
    'total', count(*),
    'runners', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'name', runner_name,
          'bib_number', bib_number
        )
        order by lower(runner_name), bib_number collate "C"
      ),
      '[]'::jsonb
    )
  )
  from official_runners;
$$;

revoke all on function public.skm2026_public_runner_list() from public;
grant execute on function public.skm2026_public_runner_list() to anon, authenticated, service_role;

comment on function public.skm2026_public_runner_list() is
  'Public, read-only SKM 2026 directory exposing only confirmed runner names and assigned bib numbers.';

