begin;

create table if not exists public.timing_manual_participants (
  id uuid primary key default gen_random_uuid(),
  event_id text not null references public.events(id) on delete cascade,
  reference_number text not null,
  bib_number text not null,
  last_name text not null,
  first_name text not null,
  full_name text not null,
  category_id uuid not null references public.event_categories(id) on delete restrict,
  category_name text not null,
  birthdate date not null,
  age_on_race_day integer not null check (age_on_race_day between 0 and 120),
  sex text not null check (sex in ('Male', 'Female')),
  email text not null,
  is_competitive boolean not null default false,
  is_active boolean not null default true,
  created_by text not null,
  created_at timestamptz not null default now(),
  updated_by text,
  updated_at timestamptz not null default now(),
  unique (event_id, reference_number)
);

create unique index if not exists timing_manual_participants_event_bib_uidx
  on public.timing_manual_participants(event_id, upper(btrim(bib_number)))
  where is_active;
create index if not exists timing_manual_participants_event_category_idx
  on public.timing_manual_participants(event_id, category_id, is_competitive)
  where is_active;

alter table public.timing_manual_participants enable row level security;
revoke all on table public.timing_manual_participants from public, anon, authenticated;
grant all on table public.timing_manual_participants to service_role;

alter table public.rfid_assignments
  add column if not exists manual_participant_id uuid references public.timing_manual_participants(id) on delete cascade,
  add column if not exists is_competitive boolean not null default true;

alter table public.rfid_assignments
  drop constraint if exists rfid_assignments_exactly_one_participant,
  drop constraint if exists rfid_assignments_participant_source;

alter table public.rfid_assignments
  add constraint rfid_assignments_participant_source
    check (participant_source in ('main', 'student', 'manual')),
  add constraint rfid_assignments_exactly_one_participant
    check (
      (participant_source = 'main' and registration_id is not null and student_registration_id is null and manual_participant_id is null)
      or (participant_source = 'student' and registration_id is null and student_registration_id is not null and manual_participant_id is null)
      or (participant_source = 'manual' and registration_id is null and student_registration_id is null and manual_participant_id is not null)
    );

create unique index if not exists rfid_assignments_active_manual_uidx
  on public.rfid_assignments(event_id, manual_participant_id)
  where is_active and manual_participant_id is not null;

create or replace function public.admin_save_timing_manual_participant(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  target_event_id text := btrim(coalesce(p_payload ->> 'event_id', ''));
  target_category_id uuid := nullif(p_payload ->> 'category_id', '')::uuid;
  target_bib text := upper(btrim(coalesce(p_payload ->> 'bib_number', '')));
  target_last_name text := upper(btrim(coalesce(p_payload ->> 'last_name', '')));
  target_first_name text := upper(btrim(coalesce(p_payload ->> 'first_name', '')));
  target_email text := lower(btrim(coalesce(p_payload ->> 'email', '')));
  target_birthdate date := nullif(p_payload ->> 'birthdate', '')::date;
  target_sex text;
  target_is_competitive boolean := coalesce((p_payload ->> 'is_competitive')::boolean, false);
  category_row public.event_categories%rowtype;
  event_date_text text;
  race_date date;
  saved public.timing_manual_participants%rowtype;
  actor text := lower(coalesce(auth.jwt() ->> 'email', 'unknown'));
begin
  if target_event_id = '' or not public.can_access_timing(target_event_id, true) then
    raise exception 'You are not authorized to add timing runners for this event.';
  end if;
  if target_bib = '' then raise exception 'Bib number is required.'; end if;
  if target_last_name = '' then raise exception 'Last name is required.'; end if;
  if target_first_name = '' then raise exception 'First name is required.'; end if;
  if target_email = '' or target_email !~* '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then
    raise exception 'A valid email address is required.';
  end if;
  if target_birthdate is null then raise exception 'Birthday is required.'; end if;

  target_sex := case lower(btrim(coalesce(p_payload ->> 'sex', '')))
    when 'male' then 'Male'
    when 'm' then 'Male'
    when 'female' then 'Female'
    when 'f' then 'Female'
    else null
  end;
  if target_sex is null then raise exception 'Gender must be Male or Female.'; end if;

  select category.* into category_row
  from public.event_categories category
  where category.id = target_category_id
    and category.event_id = target_event_id
    and coalesce(category.category_type, 'physical') = 'physical'
    and not coalesce(category.is_deleted, false)
  limit 1;
  if category_row.id is null then raise exception 'Choose a valid physical race category.'; end if;

  select event_row.event_date into event_date_text
  from public.events event_row where event_row.id = target_event_id;
  if event_date_text is null then raise exception 'The selected event was not found.'; end if;
  begin
    race_date := case
      when event_date_text ~ '^\d{4}-\d{2}-\d{2}$' then event_date_text::date
      when event_date_text ~* '^[A-Za-z]+\s+[0-9]{1,2},\s+[0-9]{4}$' then to_date(event_date_text, 'Month DD, YYYY')
      else null
    end;
  exception when others then
    race_date := null;
  end;
  if race_date is null then raise exception 'Set a valid event date before adding timing runners.'; end if;
  if target_birthdate > race_date then raise exception 'Birthday cannot be after the event date.'; end if;

  if exists (
    select 1 from public.registrations registration
    where registration.event_id = target_event_id
      and upper(btrim(coalesce(registration.bib_number, ''))) = target_bib
  ) or exists (
    select 1 from public.student_registrations student
    where target_event_id = 'skm2026'
      and upper(btrim(coalesce(student.bib_number, ''))) = target_bib
      and student.status = 'active'
  ) or exists (
    select 1 from public.timing_manual_participants participant
    where participant.event_id = target_event_id
      and participant.is_active
      and upper(btrim(participant.bib_number)) = target_bib
  ) then
    raise exception 'Bib % is already assigned to another runner in this event.', target_bib;
  end if;

  insert into public.timing_manual_participants(
    event_id, reference_number, bib_number, last_name, first_name, full_name,
    category_id, category_name, birthdate, age_on_race_day, sex, email,
    is_competitive, created_by, updated_by
  ) values (
    target_event_id,
    'TIM-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)),
    target_bib, target_last_name, target_first_name,
    target_last_name || ', ' || target_first_name,
    category_row.id, category_row.name, target_birthdate,
    extract(year from age(race_date, target_birthdate))::integer,
    target_sex, target_email, target_is_competitive, actor, actor
  ) returning * into saved;

  insert into public.timing_audit_logs(event_id, action, actor_email, details)
  values (
    target_event_id,
    'add_manual_timing_participant',
    actor,
    jsonb_build_object(
      'participant_id', saved.id,
      'bib_number', saved.bib_number,
      'category_name', saved.category_name,
      'is_competitive', saved.is_competitive
    )
  );

  return to_jsonb(saved) || jsonb_build_object('participant_id', saved.id, 'participant_source', 'manual');
end;
$fn$;

create or replace function public.admin_set_timing_manual_participant_competition(
  p_event_id text,
  p_participant_id uuid,
  p_is_competitive boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  saved public.timing_manual_participants%rowtype;
  actor text := lower(coalesce(auth.jwt() ->> 'email', 'unknown'));
begin
  if not public.can_access_timing(p_event_id, true) then
    raise exception 'You are not authorized to change competition eligibility.';
  end if;
  update public.timing_manual_participants participant
  set is_competitive = coalesce(p_is_competitive, false),
      updated_by = actor,
      updated_at = now()
  where participant.id = p_participant_id
    and participant.event_id = p_event_id
    and participant.is_active
  returning * into saved;
  if saved.id is null then raise exception 'Timing-only runner was not found.'; end if;

  update public.rfid_assignments assignment
  set is_competitive = saved.is_competitive,
      updated_at = now()
  where assignment.event_id = p_event_id
    and assignment.manual_participant_id = p_participant_id
    and assignment.is_active;

  insert into public.timing_audit_logs(event_id, action, actor_email, details)
  values (
    p_event_id,
    'set_manual_timing_competition_eligibility',
    actor,
    jsonb_build_object('participant_id', saved.id, 'is_competitive', saved.is_competitive)
  );
  return to_jsonb(saved) || jsonb_build_object('participant_id', saved.id, 'participant_source', 'manual');
end;
$fn$;

drop function if exists public.admin_list_timing_participants_page(text, integer, integer);
drop function if exists public.admin_list_timing_participants(text);

create function public.admin_list_timing_participants(p_event_id text)
returns table (
  registration_id uuid,
  reference_number text,
  bib_number text,
  runner_name text,
  sex text,
  birthdate date,
  age_on_race_day integer,
  age_group_name text,
  category_id uuid,
  category_name text,
  category_type text,
  payment_status text,
  assignment_id uuid,
  epc text,
  assignment_status text,
  wave_id uuid,
  wave_name text,
  assigned_at timestamptz,
  participant_source text,
  is_competitive boolean,
  email text
)
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not public.can_access_timing(p_event_id, false) then
    raise exception 'You are not authorized to access timing for this event.';
  end if;

  return query
  with event_context as (
    select case
      when event_row.event_date ~ '^\d{4}-\d{2}-\d{2}$' then event_row.event_date::date
      when event_row.event_date ~* '^[A-Za-z]+\s+[0-9]{1,2},\s+[0-9]{4}$' then to_date(event_row.event_date, 'Month DD, YYYY')
      else current_date
    end as race_date
    from public.events event_row where event_row.id = p_event_id
  ), main_rows as (
    select registration.id as participant_id, registration.reference_number,
      registration.bib_number,
      coalesce(nullif(btrim(registration.full_name), ''), registration.reference_number) as runner_name,
      registration.sex, registration.birthdate, registration.age_on_race_day,
      age_group.name as age_group_name, registration.category_id,
      coalesce(category.name, nullif(btrim(registration.race_category), ''), 'Community Run') as category_name,
      coalesce(category.category_type,
        case when registration.race_category ilike '%virtual%' then 'virtual' else 'physical' end) as category_type,
      registration.payment_status, assignment.id as assignment_id, assignment.epc,
      assignment.assignment_status, assignment.wave_id, wave.name as wave_name,
      assignment.assigned_at, 'main'::text as participant_source,
      true as is_competitive, registration.email
    from public.registrations registration
    left join public.event_categories category on category.id = registration.category_id
    left join public.rfid_assignments assignment
      on assignment.registration_id = registration.id
     and assignment.student_registration_id is null
     and assignment.manual_participant_id is null
     and assignment.event_id = registration.event_id and assignment.is_active
    left join public.timing_waves wave on wave.id = assignment.wave_id
    left join lateral (
      select candidate.name
      from public.timing_age_groups candidate
      where candidate.event_id = registration.event_id and candidate.is_active
        and (candidate.category_id = registration.category_id or candidate.category_id is null)
        and registration.age_on_race_day between candidate.minimum_age and candidate.maximum_age
      order by case when candidate.category_id = registration.category_id then 0 else 1 end,
        candidate.sort_order, candidate.minimum_age limit 1
    ) age_group on true
    where registration.event_id = p_event_id
      and lower(coalesce(registration.payment_status, '')) = 'approved'
      and nullif(btrim(coalesce(registration.bib_number, '')), '') is not null
      and coalesce(category.category_type,
        case when registration.race_category ilike '%virtual%' then 'virtual' else 'physical' end) = 'physical'
  ), student_base as (
    select student.id as participant_id, student.reference_number, student.bib_number,
      upper(student.last_name) || ', ' || upper(student.first_name) as runner_name,
      student.sex, student.birth_date as birthdate,
      extract(year from age(coalesce((select race_date from event_context), current_date), student.birth_date))::integer as age_on_race_day,
      category.id as category_id, student.distance as category_name, student.email
    from public.student_registrations student
    left join lateral (
      select candidate.id
      from public.event_categories candidate
      where candidate.event_id = p_event_id
        and coalesce(candidate.category_type, 'physical') = 'physical'
        and regexp_replace(lower(candidate.name), '[^a-z0-9]', '', 'g') = lower(student.distance)
      order by candidate.created_at limit 1
    ) category on true
    where p_event_id = 'skm2026' and student.status = 'active'
      and nullif(btrim(coalesce(student.bib_number, '')), '') is not null
  ), student_rows as (
    select student.participant_id, student.reference_number, student.bib_number,
      student.runner_name, student.sex, student.birthdate, student.age_on_race_day,
      age_group.name as age_group_name, student.category_id, student.category_name,
      'physical'::text as category_type, 'approved'::text as payment_status,
      assignment.id as assignment_id, assignment.epc, assignment.assignment_status,
      assignment.wave_id, wave.name as wave_name, assignment.assigned_at,
      'student'::text as participant_source, true as is_competitive, student.email
    from student_base student
    left join public.rfid_assignments assignment
      on assignment.student_registration_id = student.participant_id
     and assignment.registration_id is null
     and assignment.manual_participant_id is null
     and assignment.event_id = p_event_id and assignment.is_active
    left join public.timing_waves wave on wave.id = assignment.wave_id
    left join lateral (
      select candidate.name
      from public.timing_age_groups candidate
      where candidate.event_id = p_event_id and candidate.is_active
        and (candidate.category_id = student.category_id or candidate.category_id is null)
        and student.age_on_race_day between candidate.minimum_age and candidate.maximum_age
      order by case when candidate.category_id = student.category_id then 0 else 1 end,
        candidate.sort_order, candidate.minimum_age limit 1
    ) age_group on true
  ), manual_rows as (
    select participant.id, participant.reference_number, participant.bib_number,
      participant.full_name, participant.sex, participant.birthdate,
      participant.age_on_race_day, age_group.name, participant.category_id,
      participant.category_name, 'physical'::text, 'approved'::text,
      assignment.id, assignment.epc, assignment.assignment_status,
      assignment.wave_id, wave.name, assignment.assigned_at,
      'manual'::text, participant.is_competitive, participant.email
    from public.timing_manual_participants participant
    left join public.rfid_assignments assignment
      on assignment.manual_participant_id = participant.id
     and assignment.registration_id is null
     and assignment.student_registration_id is null
     and assignment.event_id = participant.event_id and assignment.is_active
    left join public.timing_waves wave on wave.id = assignment.wave_id
    left join lateral (
      select candidate.name
      from public.timing_age_groups candidate
      where candidate.event_id = participant.event_id and candidate.is_active
        and (candidate.category_id = participant.category_id or candidate.category_id is null)
        and participant.age_on_race_day between candidate.minimum_age and candidate.maximum_age
      order by case when candidate.category_id = participant.category_id then 0 else 1 end,
        candidate.sort_order, candidate.minimum_age limit 1
    ) age_group on true
    where participant.event_id = p_event_id and participant.is_active
  )
  select combined.*
  from (
    select * from main_rows
    union all select * from student_rows
    union all select * from manual_rows
  ) combined
  order by combined.category_name, combined.bib_number, combined.reference_number;
end;
$fn$;

create function public.admin_list_timing_participants_page(
  p_event_id text,
  p_offset integer default 0,
  p_limit integer default 500
)
returns table (
  registration_id uuid,
  reference_number text,
  bib_number text,
  runner_name text,
  sex text,
  birthdate date,
  age_on_race_day integer,
  age_group_name text,
  category_id uuid,
  category_name text,
  category_type text,
  payment_status text,
  assignment_id uuid,
  epc text,
  assignment_status text,
  wave_id uuid,
  wave_name text,
  assigned_at timestamptz,
  participant_source text,
  is_competitive boolean,
  email text
)
language sql
set search_path = public
as $fn$
  select participants.*
  from public.admin_list_timing_participants(p_event_id) participants
  order by participants.category_name, participants.bib_number, participants.reference_number
  offset greatest(coalesce(p_offset, 0), 0)
  limit least(greatest(coalesce(p_limit, 500), 1), 500)
$fn$;

create or replace function public.admin_assign_rfid(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  target_event_id text := btrim(coalesce(p_payload ->> 'event_id', ''));
  target_participant_id uuid := nullif(p_payload ->> 'registration_id', '')::uuid;
  target_epc text := public.normalize_epc(p_payload ->> 'epc');
  target_wave_id uuid := nullif(p_payload ->> 'wave_id', '')::uuid;
  reg record;
  old_assignment public.rfid_assignments%rowtype;
  saved public.rfid_assignments%rowtype;
  actor text := lower(coalesce(auth.jwt() ->> 'email', 'unknown'));
begin
  if not public.can_access_timing(target_event_id, true) then
    raise exception 'You are not authorized to assign chips for this event.';
  end if;
  if target_participant_id is null then raise exception 'Choose a timing runner first.'; end if;
  if target_epc = '' or length(target_epc) < 4 then raise exception 'A valid hexadecimal EPC is required.'; end if;

  select participant.* into reg
  from (
    select 'main'::text as participant_source, registration.id,
      registration.reference_number, registration.bib_number,
      coalesce(nullif(btrim(registration.full_name), ''), registration.reference_number) as runner_name,
      registration.email, registration.sex, registration.birthdate, registration.age_on_race_day,
      registration.category_id,
      coalesce(category.name, registration.race_category) as timing_category_name,
      coalesce(category.category_type,
        case when registration.race_category ilike '%virtual%' then 'virtual' else 'physical' end) as timing_category_type,
      registration.payment_status, true as is_competitive
    from public.registrations registration
    left join public.event_categories category on category.id = registration.category_id
    where registration.id = target_participant_id and registration.event_id = target_event_id
    union all
    select 'student'::text, student.id, student.reference_number, student.bib_number,
      upper(student.last_name) || ', ' || upper(student.first_name), student.email,
      student.sex, student.birth_date,
      extract(year from age(
        case
          when event_row.event_date ~ '^\d{4}-\d{2}-\d{2}$' then event_row.event_date::date
          when event_row.event_date ~* '^[A-Za-z]+\s+[0-9]{1,2},\s+[0-9]{4}$' then to_date(event_row.event_date, 'Month DD, YYYY')
          else current_date
        end,
        student.birth_date))::integer,
      category.id, student.distance, 'physical'::text, 'approved'::text, true
    from public.student_registrations student
    join public.events event_row on event_row.id = target_event_id
    left join lateral (
      select candidate.id
      from public.event_categories candidate
      where candidate.event_id = target_event_id
        and coalesce(candidate.category_type, 'physical') = 'physical'
        and regexp_replace(lower(candidate.name), '[^a-z0-9]', '', 'g') = lower(student.distance)
      order by candidate.created_at limit 1
    ) category on true
    where target_event_id = 'skm2026' and student.id = target_participant_id and student.status = 'active'
    union all
    select 'manual'::text, participant.id, participant.reference_number,
      participant.bib_number, participant.full_name, participant.email,
      participant.sex, participant.birthdate, participant.age_on_race_day,
      participant.category_id, participant.category_name, 'physical'::text,
      'approved'::text, participant.is_competitive
    from public.timing_manual_participants participant
    where participant.id = target_participant_id
      and participant.event_id = target_event_id
      and participant.is_active
  ) participant
  limit 1;

  if reg.id is null then raise exception 'Approved timing runner was not found.'; end if;
  if lower(coalesce(reg.payment_status, '')) <> 'approved' then raise exception 'Only approved registrations can receive a timing chip.'; end if;
  if reg.timing_category_type <> 'physical' then raise exception 'Virtual runners do not receive physical timing chips.'; end if;
  if nullif(btrim(coalesce(reg.bib_number, '')), '') is null then raise exception 'Assign a bib number before assigning a timing chip.'; end if;

  if target_wave_id is null then
    select wave.id into target_wave_id
    from public.timing_waves wave
    where wave.event_id = target_event_id
      and (wave.category_id = reg.category_id
        or regexp_replace(lower(coalesce(wave.category_name, wave.name, '')), '[^a-z0-9]', '', 'g')
          = regexp_replace(lower(coalesce(reg.timing_category_name, '')), '[^a-z0-9]', '', 'g'))
    order by case when wave.category_id = reg.category_id then 0 else 1 end,
      wave.sort_order, wave.created_at
    limit 1;
  end if;

  select * into old_assignment
  from public.rfid_assignments assignment
  where assignment.event_id = target_event_id and assignment.is_active
    and (
      (reg.participant_source = 'main' and assignment.registration_id = target_participant_id)
      or (reg.participant_source = 'student' and assignment.student_registration_id = target_participant_id)
      or (reg.participant_source = 'manual' and assignment.manual_participant_id = target_participant_id)
    )
  for update;

  if exists (
    select 1 from public.rfid_assignments assignment
    where assignment.event_id = target_event_id and assignment.epc = target_epc and assignment.is_active
      and not (
        (reg.participant_source = 'main' and assignment.registration_id = target_participant_id)
        or (reg.participant_source = 'student' and assignment.student_registration_id = target_participant_id)
        or (reg.participant_source = 'manual' and assignment.manual_participant_id = target_participant_id)
      )
  ) then raise exception 'This EPC is already assigned to another runner.'; end if;

  if old_assignment.id is not null and old_assignment.epc <> target_epc then
    update public.rfid_assignments
    set is_active = false, assignment_status = 'replaced',
      unassigned_at = now(), unassigned_by = actor, updated_at = now()
    where id = old_assignment.id;
    update public.rfid_tags set status = 'available', updated_at = now()
    where epc = old_assignment.epc;
  elsif old_assignment.id is not null then
    update public.rfid_assignments
    set wave_id = target_wave_id,
      participant_source = reg.participant_source,
      runner_name = reg.runner_name,
      category_id = reg.category_id,
      category_name = reg.timing_category_name,
      category_type = reg.timing_category_type,
      sex = reg.sex,
      birthdate = reg.birthdate,
      age_on_race_day = reg.age_on_race_day,
      is_competitive = reg.is_competitive,
      assignment_status = case
        when coalesce((p_payload ->> 'qc_passed')::boolean, false) then 'qc_passed'
        else assignment_status end,
      qc_checked_at = case when coalesce((p_payload ->> 'qc_passed')::boolean, false) then now() else qc_checked_at end,
      qc_checked_by = case when coalesce((p_payload ->> 'qc_passed')::boolean, false) then actor else qc_checked_by end,
      notes = nullif(btrim(p_payload ->> 'notes'), ''),
      updated_at = now()
    where id = old_assignment.id
    returning * into saved;
  end if;

  insert into public.rfid_tags(epc, event_id, display_code, status, first_seen_at, last_seen_at, last_reader_id)
  values (
    target_epc, target_event_id,
    coalesce(nullif(btrim(p_payload ->> 'display_code'), ''), right(target_epc, 8)),
    'assigned', now(), now(), nullif(btrim(p_payload ->> 'reader_id'), '')
  )
  on conflict (epc) do update
  set event_id = excluded.event_id,
    display_code = coalesce(excluded.display_code, public.rfid_tags.display_code),
    status = 'assigned',
    last_seen_at = now(),
    last_reader_id = coalesce(excluded.last_reader_id, public.rfid_tags.last_reader_id),
    updated_at = now();

  if saved.id is null then
    insert into public.rfid_assignments(
      event_id, registration_id, student_registration_id, manual_participant_id,
      participant_source, epc, reference_number, bib_number, runner_name,
      sex, birthdate, age_on_race_day, category_id, category_name, category_type,
      wave_id, assignment_status, is_competitive, assigned_by,
      qc_checked_at, qc_checked_by, notes
    ) values (
      target_event_id,
      case when reg.participant_source = 'main' then reg.id else null end,
      case when reg.participant_source = 'student' then reg.id else null end,
      case when reg.participant_source = 'manual' then reg.id else null end,
      reg.participant_source, target_epc, reg.reference_number, reg.bib_number,
      reg.runner_name, reg.sex, reg.birthdate, reg.age_on_race_day,
      reg.category_id, reg.timing_category_name, reg.timing_category_type,
      target_wave_id,
      case when coalesce((p_payload ->> 'qc_passed')::boolean, false) then 'qc_passed' else 'assigned' end,
      reg.is_competitive,
      actor,
      case when coalesce((p_payload ->> 'qc_passed')::boolean, false) then now() else null end,
      case when coalesce((p_payload ->> 'qc_passed')::boolean, false) then actor else null end,
      nullif(btrim(p_payload ->> 'notes'), '')
    ) returning * into saved;
  end if;

  insert into public.timing_audit_logs(
    event_id, action, registration_id, student_registration_id,
    assignment_id, wave_id, actor_email, details
  ) values (
    target_event_id,
    case when old_assignment.id is null then 'assign_chip' else 'update_chip_assignment' end,
    saved.registration_id, saved.student_registration_id,
    saved.id, target_wave_id, actor,
    jsonb_build_object(
      'epc', target_epc,
      'previous_epc', old_assignment.epc,
      'participant_source', saved.participant_source,
      'participant_id', target_participant_id,
      'is_competitive', saved.is_competitive
    )
  );
  return to_jsonb(saved) || jsonb_build_object('participant_id', target_participant_id);
end;
$fn$;

create or replace function public.admin_unassign_registration_rfid(
  p_event_id text,
  p_registration_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare target public.rfid_assignments%rowtype;
begin
  if not public.can_access_timing(p_event_id, true) then
    raise exception 'You are not authorized to remove chip assignments.';
  end if;
  if exists (
    select 1 from public.timing_race_sessions session
    where session.event_id = p_event_id
      and session.session_type = 'official'
      and session.status = 'active'
  ) then
    raise exception 'Chip assignments cannot be removed while an official timing session is active.';
  end if;
  select * into target
  from public.rfid_assignments assignment
  where assignment.event_id = p_event_id and assignment.is_active
    and (
      assignment.registration_id = p_registration_id
      or assignment.student_registration_id = p_registration_id
      or assignment.manual_participant_id = p_registration_id
    )
  limit 1;
  if target.id is null then raise exception 'This runner has no active chip assignment.'; end if;
  return public.admin_unassign_rfid(
    target.id,
    coalesce(nullif(btrim(p_reason), ''), 'Removed from timing console')
  );
end;
$fn$;

create or replace function public.admin_timing_dashboard(p_event_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare result_value jsonb;
begin
  if not public.can_access_timing(p_event_id, false) then
    raise exception 'You are not authorized to access timing for this event.';
  end if;
  select jsonb_build_object(
    'participants',
      (select count(*) from public.registrations registration
       left join public.event_categories category on category.id = registration.category_id
       where registration.event_id = p_event_id
         and lower(coalesce(registration.payment_status, '')) = 'approved'
         and nullif(btrim(coalesce(registration.bib_number, '')), '') is not null
         and coalesce(category.category_type,
           case when registration.race_category ilike '%virtual%' then 'virtual' else 'physical' end) = 'physical')
      + case when p_event_id = 'skm2026' then
          (select count(*) from public.student_registrations student
           where student.status = 'active'
             and nullif(btrim(coalesce(student.bib_number, '')), '') is not null)
        else 0 end
      + (select count(*) from public.timing_manual_participants participant
         where participant.event_id = p_event_id and participant.is_active),
    'non_competitive',
      (select count(*) from public.timing_manual_participants participant
       where participant.event_id = p_event_id
         and participant.is_active
         and not participant.is_competitive),
    'assigned', (select count(*) from public.rfid_assignments where event_id = p_event_id and is_active),
    'qc_passed', (select count(*) from public.rfid_assignments where event_id = p_event_id and is_active and assignment_status = 'qc_passed'),
    'waves', (select count(*) from public.timing_waves where event_id = p_event_id),
    'stations', (select count(*) from public.timing_stations where event_id = p_event_id and is_active),
    'reads', (select count(*) from public.timing_reads where event_id = p_event_id),
    'unmatched_reads', (select count(*) from public.timing_reads where event_id = p_event_id and assignment_id is null)
  ) into result_value;
  return result_value;
end;
$fn$;

create or replace function public.admin_timing_results(p_event_id text)
returns table (
  registration_id uuid,
  reference_number text,
  bib_number text,
  runner_name text,
  sex text,
  age_on_race_day integer,
  category_name text,
  age_group_name text,
  wave_name text,
  gun_start_at timestamptz,
  chip_start_at timestamptz,
  finish_at timestamptz,
  gun_time interval,
  chip_time interval,
  overall_sex_place bigint,
  age_group_sex_place bigint,
  award_status text,
  result_status text
)
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not public.can_access_timing(p_event_id, false) then
    raise exception 'You are not authorized to view timing results.';
  end if;
  return query
  with reads as (
    select assignment.id as assignment_id,
      min(timing_read.read_at) filter (
        where station.station_type = 'start' and timing_read.is_valid and not timing_read.is_duplicate
      ) as chip_start,
      min(timing_read.read_at) filter (
        where station.station_type = 'finish' and timing_read.is_valid and not timing_read.is_duplicate
      ) as finish
    from public.rfid_assignments assignment
    left join public.timing_reads timing_read on timing_read.assignment_id = assignment.id
    left join public.timing_stations station on station.id = timing_read.station_id
    where assignment.event_id = p_event_id and assignment.is_active
    group by assignment.id
  ), base as (
    select assignment.id as assignment_id,
      coalesce(assignment.registration_id, assignment.student_registration_id, assignment.manual_participant_id) as participant_id,
      assignment.reference_number, assignment.bib_number, assignment.runner_name,
      case lower(btrim(coalesce(assignment.sex, '')))
        when 'male' then 'Male' when 'm' then 'Male'
        when 'female' then 'Female' when 'f' then 'Female'
        else 'Unspecified' end as runner_sex,
      assignment.age_on_race_day, assignment.category_name,
      age_group.name as age_group_name, effective_wave.name as wave_name,
      effective_wave.actual_start_at, reads.chip_start, reads.finish,
      case when reads.finish is not null and effective_wave.actual_start_at is not null
        then reads.finish - effective_wave.actual_start_at end as gun_elapsed,
      case when reads.finish is not null and reads.chip_start is not null
        then reads.finish - reads.chip_start end as chip_elapsed,
      assignment.is_competitive,
      coalesce(award_settings.ranking_basis, 'gun_time') as ranking_basis,
      coalesce(award_settings.overall_places_per_sex, 3) as overall_places_per_sex,
      coalesce(award_settings.age_group_places_per_sex, 3) as age_group_places_per_sex,
      coalesce(award_settings.exclude_overall_from_age_group, true) as exclude_overall_from_age_group
    from public.rfid_assignments assignment
    left join lateral (
      select wave.id, wave.name, wave.actual_start_at
      from public.timing_waves wave
      where wave.event_id = assignment.event_id
        and (wave.id = assignment.wave_id
          or (assignment.category_id is not null and wave.category_id = assignment.category_id)
          or regexp_replace(lower(coalesce(wave.category_name, wave.name, '')), '[^a-z0-9]', '', 'g')
             = regexp_replace(lower(coalesce(assignment.category_name, '')), '[^a-z0-9]', '', 'g'))
      order by case when wave.id = assignment.wave_id then 0
        when assignment.category_id is not null and wave.category_id = assignment.category_id then 1
        else 2 end, wave.sort_order, wave.created_at
      limit 1
    ) effective_wave on true
    left join reads on reads.assignment_id = assignment.id
    left join public.timing_award_settings award_settings on award_settings.event_id = assignment.event_id
    left join lateral (
      select candidate.name
      from public.timing_age_groups candidate
      where candidate.event_id = assignment.event_id and candidate.is_active
        and (candidate.category_id = assignment.category_id or candidate.category_id is null)
        and assignment.age_on_race_day between candidate.minimum_age and candidate.maximum_age
      order by case when candidate.category_id = assignment.category_id then 0 else 1 end,
        candidate.sort_order, candidate.minimum_age limit 1
    ) age_group on true
    where assignment.event_id = p_event_id and assignment.is_active
  ), competitive_overall as (
    select base.*, rank() over (
      partition by base.category_name, base.runner_sex
      order by case when base.ranking_basis = 'chip_time' then base.chip_elapsed else base.gun_elapsed end nulls last,
        base.finish nulls last, base.bib_number
    ) as overall_place
    from base
    where base.is_competitive
  ), competitive_ranked as (
    select competitive_overall.*,
      case when competitive_overall.age_group_name is null then null
        when competitive_overall.exclude_overall_from_age_group
          and competitive_overall.overall_place <= competitive_overall.overall_places_per_sex then null
        else sum(case when competitive_overall.exclude_overall_from_age_group
          and competitive_overall.overall_place <= competitive_overall.overall_places_per_sex then 0 else 1 end)
          over (partition by competitive_overall.category_name, competitive_overall.runner_sex, competitive_overall.age_group_name
            order by case when competitive_overall.ranking_basis = 'chip_time' then competitive_overall.chip_elapsed else competitive_overall.gun_elapsed end nulls last,
              competitive_overall.finish nulls last, competitive_overall.bib_number
            rows between unbounded preceding and current row)
      end as age_group_place
    from competitive_overall
  )
  select base.participant_id, base.reference_number, base.bib_number, base.runner_name,
    base.runner_sex, base.age_on_race_day, base.category_name, base.age_group_name,
    base.wave_name, base.actual_start_at, base.chip_start, base.finish,
    base.gun_elapsed, base.chip_elapsed,
    case when base.finish is not null and base.is_competitive then ranked.overall_place end,
    case when base.finish is not null and base.is_competitive and base.age_group_name is not null then ranked.age_group_place end,
    case when base.finish is null then null
      when not base.is_competitive then 'Non-competitive'
      when base.runner_sex not in ('Male', 'Female') then 'Review Sex'
      when ranked.overall_place <= base.overall_places_per_sex then 'Overall Podium'
      when ranked.age_group_place is not null and ranked.age_group_place <= base.age_group_places_per_sex
        then 'Age Group Podium' else 'Finisher' end,
    case when base.actual_start_at is null then 'wave_not_started'
      when base.finish is null then 'no_finish'
      when not base.is_competitive then 'timed_non_competitive'
      when base.chip_start is null then 'gun_time_only' else 'timed' end
  from base
  left join competitive_ranked ranked on ranked.assignment_id = base.assignment_id
  order by base.category_name, base.runner_sex,
    ranked.overall_place nulls last, base.finish nulls last, base.bib_number;
end;
$fn$;

create or replace function public.admin_timing_session_results(p_event_id text, p_session_id uuid)
returns table (
  registration_id uuid,
  reference_number text,
  bib_number text,
  runner_name text,
  sex text,
  age_on_race_day integer,
  category_name text,
  age_group_name text,
  wave_name text,
  gun_start_at timestamptz,
  chip_start_at timestamptz,
  finish_at timestamptz,
  gun_time interval,
  chip_time interval,
  overall_sex_place bigint,
  age_group_sex_place bigint,
  award_status text,
  result_status text
)
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not public.can_access_timing(p_event_id, false) then
    raise exception 'You are not authorized to view timing results.';
  end if;
  if not exists (
    select 1 from public.timing_race_sessions session
    where session.id = p_session_id and session.event_id = p_event_id
  ) then
    raise exception 'Timing session was not found for this event.';
  end if;

  return query
  with reads as (
    select assignment.id as assignment_id,
      min(timing_read.read_at) filter (
        where station.station_type = 'start' and timing_read.is_valid and not timing_read.is_duplicate
      ) as chip_start,
      min(timing_read.read_at) filter (
        where station.station_type = 'finish' and timing_read.is_valid and not timing_read.is_duplicate
      ) as finish
    from public.rfid_assignments assignment
    left join public.timing_reads timing_read
      on timing_read.assignment_id = assignment.id and timing_read.race_session_id = p_session_id
    left join public.timing_stations station on station.id = timing_read.station_id
    where assignment.event_id = p_event_id and assignment.is_active
    group by assignment.id
  ), base as (
    select assignment.id as assignment_id,
      coalesce(assignment.registration_id, assignment.student_registration_id, assignment.manual_participant_id) as participant_id,
      assignment.reference_number, assignment.bib_number, assignment.runner_name,
      case lower(btrim(coalesce(assignment.sex, '')))
        when 'male' then 'Male' when 'm' then 'Male'
        when 'female' then 'Female' when 'f' then 'Female'
        else 'Unspecified' end as runner_sex,
      assignment.age_on_race_day, assignment.category_name,
      age_group.name as age_group_name, effective_wave.name as wave_name,
      session_start.actual_start_at, reads.chip_start, reads.finish,
      case when reads.finish is not null and session_start.actual_start_at is not null
        then reads.finish - session_start.actual_start_at end as gun_elapsed,
      case when reads.finish is not null and reads.chip_start is not null
        then reads.finish - reads.chip_start end as chip_elapsed,
      assignment.is_competitive,
      coalesce(award_settings.ranking_basis, 'gun_time') as ranking_basis,
      coalesce(award_settings.overall_places_per_sex, 3) as overall_places_per_sex,
      coalesce(award_settings.age_group_places_per_sex, 3) as age_group_places_per_sex,
      coalesce(award_settings.exclude_overall_from_age_group, true) as exclude_overall_from_age_group
    from public.rfid_assignments assignment
    left join lateral (
      select wave.id, wave.name
      from public.timing_waves wave
      where wave.event_id = assignment.event_id
        and (wave.id = assignment.wave_id
          or (assignment.category_id is not null and wave.category_id = assignment.category_id)
          or regexp_replace(lower(coalesce(wave.category_name, wave.name, '')), '[^a-z0-9]', '', 'g')
             = regexp_replace(lower(coalesce(assignment.category_name, '')), '[^a-z0-9]', '', 'g'))
      order by case when wave.id = assignment.wave_id then 0
        when assignment.category_id is not null and wave.category_id = assignment.category_id then 1
        else 2 end, wave.sort_order, wave.created_at
      limit 1
    ) effective_wave on true
    left join public.timing_session_wave_starts session_start
      on session_start.session_id = p_session_id and session_start.wave_id = effective_wave.id
    left join reads on reads.assignment_id = assignment.id
    left join public.timing_award_settings award_settings on award_settings.event_id = assignment.event_id
    left join lateral (
      select candidate.name
      from public.timing_age_groups candidate
      where candidate.event_id = assignment.event_id and candidate.is_active
        and (candidate.category_id = assignment.category_id or candidate.category_id is null)
        and assignment.age_on_race_day between candidate.minimum_age and candidate.maximum_age
      order by case when candidate.category_id = assignment.category_id then 0 else 1 end,
        candidate.sort_order, candidate.minimum_age limit 1
    ) age_group on true
    where assignment.event_id = p_event_id and assignment.is_active
  ), competitive_overall as (
    select base.*, rank() over (
      partition by base.category_name, base.runner_sex
      order by case when base.ranking_basis = 'chip_time' then base.chip_elapsed else base.gun_elapsed end nulls last,
        base.finish nulls last, base.bib_number
    ) as overall_place
    from base
    where base.is_competitive
  ), competitive_ranked as (
    select competitive_overall.*,
      case when competitive_overall.age_group_name is null then null
        when competitive_overall.exclude_overall_from_age_group
          and competitive_overall.overall_place <= competitive_overall.overall_places_per_sex then null
        else sum(case when competitive_overall.exclude_overall_from_age_group
          and competitive_overall.overall_place <= competitive_overall.overall_places_per_sex then 0 else 1 end)
          over (partition by competitive_overall.category_name, competitive_overall.runner_sex, competitive_overall.age_group_name
            order by case when competitive_overall.ranking_basis = 'chip_time' then competitive_overall.chip_elapsed else competitive_overall.gun_elapsed end nulls last,
              competitive_overall.finish nulls last, competitive_overall.bib_number
            rows between unbounded preceding and current row)
      end as age_group_place
    from competitive_overall
  )
  select base.participant_id, base.reference_number, base.bib_number, base.runner_name,
    base.runner_sex, base.age_on_race_day, base.category_name, base.age_group_name,
    base.wave_name, base.actual_start_at, base.chip_start, base.finish,
    base.gun_elapsed, base.chip_elapsed,
    case when base.finish is not null and base.is_competitive then ranked.overall_place end,
    case when base.finish is not null and base.is_competitive and base.age_group_name is not null then ranked.age_group_place end,
    case when base.finish is null then null
      when not base.is_competitive then 'Non-competitive'
      when base.runner_sex not in ('Male', 'Female') then 'Review Sex'
      when ranked.overall_place <= base.overall_places_per_sex then 'Overall Podium'
      when ranked.age_group_place is not null and ranked.age_group_place <= base.age_group_places_per_sex
        then 'Age Group Podium' else 'Finisher' end,
    case when base.actual_start_at is null then 'wave_not_started'
      when base.finish is null then 'no_finish'
      when not base.is_competitive then 'timed_non_competitive'
      when base.chip_start is null then 'gun_time_only' else 'timed' end
  from base
  left join competitive_ranked ranked on ranked.assignment_id = base.assignment_id
  order by base.category_name, base.runner_sex,
    ranked.overall_place nulls last, base.finish nulls last, base.bib_number;
end;
$fn$;

create or replace function public.public_timing_leaderboard(p_event_key text, p_session_key text)
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
declare
  target_event_id text;
  target_session_id uuid;
begin
  if coalesce(p_event_key, '') like 'cloud:%' then
    target_event_id := substring(p_event_key from 7);
    begin
      target_session_id := p_session_key::uuid;
    exception when others then
      return;
    end;
    if not exists (
      select 1 from public.timing_race_sessions session_row
      where session_row.id = target_session_id
        and session_row.event_id = target_event_id
        and session_row.status in ('active', 'completed')
    ) then return; end if;

    return query
    with reads as (
      select assignment.id as assignment_id,
        min(timing_read.read_at) filter (
          where station.station_type = 'start' and timing_read.is_valid and not timing_read.is_duplicate
        ) as chip_start,
        min(timing_read.read_at) filter (
          where station.station_type = 'finish' and timing_read.is_valid and not timing_read.is_duplicate
        ) as finish
      from public.rfid_assignments assignment
      left join public.timing_reads timing_read
        on timing_read.assignment_id = assignment.id and timing_read.race_session_id = target_session_id
      left join public.timing_stations station on station.id = timing_read.station_id
      where assignment.event_id = target_event_id and assignment.is_active
      group by assignment.id
    ), base as (
      select assignment.id as assignment_id,
        assignment.bib_number, assignment.runner_name,
        case lower(btrim(coalesce(assignment.sex, '')))
          when 'male' then 'Male' when 'm' then 'Male'
          when 'female' then 'Female' when 'f' then 'Female'
          else 'Unspecified' end as runner_sex,
        coalesce(nullif(assignment.category_name, ''), effective_wave.name, 'Open') as category_name,
        age_group.name as age_group_name, effective_wave.name as wave_name,
        wave_start.actual_start_at, reads.finish,
        extract(epoch from (reads.finish - wave_start.actual_start_at))::bigint as gun_seconds,
        case when reads.chip_start is not null
          then extract(epoch from (reads.finish - reads.chip_start))::bigint end as chip_seconds,
        assignment.is_competitive,
        coalesce(award.overall_places_per_sex, 3) as overall_places_per_sex,
        coalesce(award.age_group_places_per_sex, 3) as age_group_places_per_sex,
        coalesce(award.exclude_overall_from_age_group, true) as exclude_overall_from_age_group
      from public.rfid_assignments assignment
      join reads on reads.assignment_id = assignment.id and reads.finish is not null
      left join lateral (
        select wave.id, wave.name
        from public.timing_waves wave
        where wave.event_id = assignment.event_id
          and (wave.id = assignment.wave_id
            or (assignment.category_id is not null and wave.category_id = assignment.category_id)
            or regexp_replace(lower(coalesce(wave.category_name, wave.name, '')), '[^a-z0-9]', '', 'g')
               = regexp_replace(lower(coalesce(assignment.category_name, '')), '[^a-z0-9]', '', 'g'))
        order by case when wave.id = assignment.wave_id then 0
          when assignment.category_id is not null and wave.category_id = assignment.category_id then 1
          else 2 end, wave.sort_order, wave.created_at
        limit 1
      ) effective_wave on true
      left join public.timing_session_wave_starts wave_start
        on wave_start.session_id = target_session_id and wave_start.wave_id = effective_wave.id
      left join public.timing_award_settings award on award.event_id = assignment.event_id
      left join lateral (
        select candidate.name
        from public.timing_age_groups candidate
        where candidate.event_id = assignment.event_id and candidate.is_active
          and (candidate.category_id = assignment.category_id or candidate.category_id is null)
          and assignment.age_on_race_day between candidate.minimum_age and candidate.maximum_age
        order by case when candidate.category_id = assignment.category_id then 0 else 1 end,
          candidate.sort_order, candidate.minimum_age limit 1
      ) age_group on true
      where assignment.event_id = target_event_id and assignment.is_active
        and wave_start.actual_start_at is not null and reads.finish >= wave_start.actual_start_at
    ), competitive_ranked as (
      select base.*,
        rank() over (partition by base.category_name
          order by base.gun_seconds, base.finish, base.bib_number) as overall_rank,
        rank() over (partition by base.category_name, base.runner_sex
          order by base.gun_seconds, base.finish, base.bib_number) as sex_rank,
        case when base.age_group_name is null then null else rank() over (
          partition by base.category_name, base.runner_sex, base.age_group_name
          order by base.gun_seconds, base.finish, base.bib_number) end as age_rank
      from base
      where base.is_competitive
    ), competitive_awarded as (
      select competitive_ranked.*,
        case when competitive_ranked.age_group_name is null then null else
          sum(case when competitive_ranked.exclude_overall_from_age_group
            and competitive_ranked.sex_rank <= competitive_ranked.overall_places_per_sex then 0 else 1 end)
          over (partition by competitive_ranked.category_name, competitive_ranked.runner_sex, competitive_ranked.age_group_name
            order by competitive_ranked.gun_seconds, competitive_ranked.finish, competitive_ranked.bib_number
            rows between unbounded preceding and current row) end as award_age_rank
      from competitive_ranked
    )
    select base.bib_number, base.runner_name, base.runner_sex,
      base.category_name, base.age_group_name, base.wave_name,
      base.actual_start_at, base.finish, base.gun_seconds, base.chip_seconds,
      ranked.overall_rank, ranked.sex_rank, ranked.age_rank,
      case when not base.is_competitive then 'Non-competitive'
        when base.runner_sex not in ('Male', 'Female') then 'Finisher'
        when ranked.sex_rank <= base.overall_places_per_sex then 'Overall Podium'
        when base.age_group_name is not null
          and ranked.award_age_rank <= base.age_group_places_per_sex
          and (not base.exclude_overall_from_age_group
            or ranked.sex_rank > base.overall_places_per_sex) then 'Age Group Podium'
        else 'Finisher' end
    from base
    left join competitive_awarded ranked on ranked.assignment_id = base.assignment_id
    order by base.category_name, ranked.overall_rank nulls last, base.finish, base.bib_number;
    return;
  end if;

  if coalesce(p_event_key, '') like 'local:%' then
    return query
    with base as (
      select local_result.*,
        coalesce(nullif(local_result.sex, ''), 'Unspecified') as runner_sex
      from public.timing_public_local_results local_result
      join public.timing_public_local_events local_event
        on local_event.event_key = local_result.event_key
       and local_event.session_key = local_result.session_key
      where local_result.event_key = p_event_key and local_result.session_key = p_session_key
        and local_event.session_status in ('active', 'completed')
    ), ranked as (
      select base.*,
        rank() over (partition by base.category_name
          order by base.gun_time_seconds, base.finish_at, base.bib_number) as overall_rank,
        rank() over (partition by base.category_name, base.runner_sex
          order by base.gun_time_seconds, base.finish_at, base.bib_number) as sex_rank,
        case when base.age_group_name is null then null else rank() over (
          partition by base.category_name, base.runner_sex, base.age_group_name
          order by base.gun_time_seconds, base.finish_at, base.bib_number) end as age_rank
      from base
    )
    select ranked.bib_number, ranked.runner_name, ranked.runner_sex,
      ranked.category_name, ranked.age_group_name, ranked.wave_name,
      ranked.gun_start_at, ranked.finish_at, ranked.gun_time_seconds,
      ranked.chip_time_seconds, ranked.overall_rank, ranked.sex_rank,
      ranked.age_rank, coalesce(ranked.award_status, 'Finisher')
    from ranked
    order by ranked.category_name, ranked.overall_rank, ranked.bib_number;
  end if;
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
    select * from public.admin_timing_session_results(p_event_id, p_session_id)
  )
  select result.registration_id::text,
    result.registration_id,
    result.reference_number,
    result.bib_number,
    result.runner_name,
    coalesce(registration.email, student.email, manual_participant.email),
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
    select assignment.registration_id,
      assignment.student_registration_id,
      assignment.manual_participant_id
    from public.rfid_assignments assignment
    where assignment.event_id = p_event_id
      and assignment.is_active
      and coalesce(
        assignment.registration_id,
        assignment.student_registration_id,
        assignment.manual_participant_id
      ) = result.registration_id
    order by assignment.created_at desc
    limit 1
  ) source_assignment on true
  left join public.registrations registration
    on registration.id = source_assignment.registration_id
  left join public.student_registrations student
    on student.id = source_assignment.student_registration_id
  left join public.timing_manual_participants manual_participant
    on manual_participant.id = source_assignment.manual_participant_id
  where result.finish_at is not null
    and result.gun_time is not null
    and result.result_status in ('timed', 'gun_time_only', 'timed_non_competitive')
  order by result.category_name, result.overall_sex_place nulls last, result.bib_number;
end;
$fn$;

revoke all on function public.admin_save_timing_manual_participant(jsonb) from public, anon;
revoke all on function public.admin_set_timing_manual_participant_competition(text, uuid, boolean) from public, anon;
revoke all on function public.admin_list_timing_participants(text) from public, anon;
revoke all on function public.admin_list_timing_participants_page(text, integer, integer) from public, anon;
revoke all on function public.admin_assign_rfid(jsonb) from public, anon;
revoke all on function public.admin_unassign_registration_rfid(text, uuid, text) from public, anon;
revoke all on function public.admin_timing_dashboard(text) from public, anon;
revoke all on function public.admin_timing_results(text) from public, anon;
revoke all on function public.admin_timing_session_results(text, uuid) from public, anon;
revoke all on function public.admin_timing_result_email_candidates(text, uuid) from public, anon;

grant execute on function public.admin_save_timing_manual_participant(jsonb) to authenticated, service_role;
grant execute on function public.admin_set_timing_manual_participant_competition(text, uuid, boolean) to authenticated, service_role;
grant execute on function public.admin_list_timing_participants(text) to authenticated, service_role;
grant execute on function public.admin_list_timing_participants_page(text, integer, integer) to authenticated, service_role;
grant execute on function public.admin_assign_rfid(jsonb) to authenticated, service_role;
grant execute on function public.admin_unassign_registration_rfid(text, uuid, text) to authenticated, service_role;
grant execute on function public.admin_timing_dashboard(text) to authenticated, service_role;
grant execute on function public.admin_timing_results(text) to authenticated, service_role;
grant execute on function public.admin_timing_session_results(text, uuid) to authenticated, service_role;
grant execute on function public.admin_timing_result_email_candidates(text, uuid) to authenticated, service_role;

revoke all on function public.public_timing_leaderboard(text, text) from public;
grant execute on function public.public_timing_leaderboard(text, text) to anon, authenticated, service_role;

commit;

notify pgrst, 'reload schema';




