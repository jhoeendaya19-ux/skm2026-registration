-- Close SKM2026 virtual-run proof submissions while preserving lookups,
-- existing submissions, reviews, and approved certificates.

update public.event_settings
set
  content = jsonb_set(
    coalesce(content, '{}'::jsonb),
    '{virtualRunSubmissionOpen}',
    'false'::jsonb,
    true
  ),
  updated_at = now()
where id = 'skm2026';

create or replace function public.lookup_virtual_completion(
  p_event_id text,
  p_reference_number text,
  p_email text
)
returns table (
  registration_id uuid,
  event_id text,
  reference_number text,
  full_name text,
  email text,
  race_category text,
  payment_status text,
  category_type text,
  can_submit boolean,
  message text,
  submission_id uuid,
  completion_status text,
  completion_distance text,
  completion_date date,
  elapsed_time text,
  strava_activity_url text,
  runner_note text,
  verifier_note text,
  certificate_number text,
  reviewed_at timestamptz,
  submitted_at timestamptz,
  proof_entries jsonb,
  total_distance_km numeric,
  required_distance_km numeric
)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  registration_record record;
  submission_record public.virtual_completion_submissions%rowtype;
  selected_event_id text;
  category_distance numeric;
  submissions_open boolean := true;
begin
  selected_event_id := coalesce(nullif(p_event_id, ''), 'skm2026');

  select coalesce(
    nullif(es.content ->> 'virtualRunSubmissionOpen', '')::boolean,
    true
  )
  into submissions_open
  from public.event_settings es
  where es.id = selected_event_id;

  submissions_open := coalesce(submissions_open, true);

  select
    r.id,
    r.event_id,
    r.reference_number,
    r.full_name,
    r.email,
    r.race_category,
    r.payment_status,
    coalesce(ec.category_type, 'physical') as category_type
  into registration_record
  from public.registrations r
  left join public.event_categories ec on ec.id = r.category_id
  where r.event_id = selected_event_id
    and lower(r.reference_number) = lower(trim(p_reference_number))
    and lower(r.email) = lower(trim(p_email))
  limit 1;

  if not found then
    return;
  end if;

  category_distance := nullif(
    substring(upper(registration_record.race_category) from '([0-9]+([.][0-9]+)?)\s*K'),
    ''
  )::numeric;

  select *
  into submission_record
  from public.virtual_completion_submissions vcs
  where vcs.registration_id = registration_record.id
  limit 1;

  return query
  select
    registration_record.id::uuid,
    registration_record.event_id::text,
    registration_record.reference_number::text,
    registration_record.full_name::text,
    registration_record.email::text,
    registration_record.race_category::text,
    registration_record.payment_status::text,
    registration_record.category_type::text,
    (
      submissions_open
      and registration_record.category_type = 'virtual'
      and registration_record.payment_status = 'approved'
      and coalesce(submission_record.status, '') in ('', 'needs_correction')
    )::boolean,
    case
      when registration_record.category_type <> 'virtual'
        then 'This completion page is only for Virtual Run categories.'
      when registration_record.payment_status <> 'approved'
        then 'Your registration must be approved before completion proof can be submitted.'
      when submission_record.status = 'approved'
        then 'Your virtual run completion has been approved. Your certificate is ready.'
      when submission_record.status = 'pending_review'
        then 'Your completion proof is already submitted and waiting for verifier review.'
      when submission_record.status = 'rejected'
        then 'Your previous completion proof was rejected. Contact the organizer if you need help.'
      when not submissions_open
        then 'Virtual Run submissions are now closed. Existing submissions and approved certificates remain available.'
      when submission_record.status = 'needs_correction'
        then 'Your previous completion proof needs correction. You may submit an updated proof.'
      else 'You may submit your virtual run completion proof.'
    end::text,
    submission_record.id::uuid,
    submission_record.status::text,
    submission_record.completion_distance::text,
    submission_record.completion_date::date,
    submission_record.elapsed_time::text,
    submission_record.strava_activity_url::text,
    submission_record.runner_note::text,
    submission_record.verifier_note::text,
    submission_record.certificate_number::text,
    submission_record.reviewed_at::timestamptz,
    submission_record.submitted_at::timestamptz,
    coalesce(submission_record.proof_entries, '[]'::jsonb)::jsonb,
    submission_record.total_distance_km::numeric,
    coalesce(submission_record.required_distance_km, category_distance)::numeric;
end;
$fn$;

create or replace function public.submit_virtual_completion(payload jsonb)
returns table (
  submission_id uuid,
  status text,
  certificate_number text
)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  registration_record record;
  existing_record record;
  new_id uuid;
  selected_event_id text;
  proof_value text;
  strava_value text;
  proof_entries_value jsonb;
  normalized_proof_entries jsonb := '[]'::jsonb;
  proof_item jsonb;
  proof_distance numeric;
  proof_date date;
  total_distance_value numeric := 0;
  required_distance_value numeric;
  final_completion_date date;
  submissions_open boolean := true;
begin
  if payload is null or jsonb_typeof(payload) <> 'object' then
    raise exception 'Completion submission is invalid.';
  end if;

  selected_event_id := coalesce(nullif(payload ->> 'event_id', ''), 'skm2026');

  select coalesce(
    nullif(es.content ->> 'virtualRunSubmissionOpen', '')::boolean,
    true
  )
  into submissions_open
  from public.event_settings es
  where es.id = selected_event_id;

  if not coalesce(submissions_open, true) then
    raise exception 'Virtual Run submissions are now closed.';
  end if;

  strava_value := nullif(trim(payload ->> 'strava_activity_url'), '');
  proof_entries_value := coalesce(payload -> 'proof_entries', '[]'::jsonb);

  if jsonb_typeof(proof_entries_value) <> 'array' then
    raise exception 'Run screenshots must be submitted as a list.';
  end if;

  if jsonb_array_length(proof_entries_value) > 20 then
    raise exception 'A maximum of 20 run screenshots is allowed.';
  end if;

  select
    r.id,
    r.event_id,
    r.reference_number,
    r.full_name,
    r.email,
    r.race_category,
    r.payment_status,
    coalesce(ec.category_type, 'physical') as category_type
  into registration_record
  from public.registrations r
  left join public.event_categories ec on ec.id = r.category_id
  where r.event_id = selected_event_id
    and lower(r.reference_number) = lower(trim(payload ->> 'reference_number'))
    and lower(r.email) = lower(trim(payload ->> 'email'))
  limit 1;

  if not found then
    raise exception 'Registration could not be found. Please check the reference number and email.';
  end if;

  if registration_record.category_type <> 'virtual' then
    raise exception 'Completion proof is only required for Virtual Run categories.';
  end if;

  if registration_record.payment_status <> 'approved' then
    raise exception 'Registration must be approved before completion proof can be submitted.';
  end if;

  required_distance_value := nullif(
    substring(upper(registration_record.race_category) from '([0-9]+([.][0-9]+)?)\s*K'),
    ''
  )::numeric;

  for proof_item in select value from jsonb_array_elements(proof_entries_value)
  loop
    if jsonb_typeof(proof_item) <> 'object'
       or nullif(trim(proof_item ->> 'proof_path'), '') is null then
      raise exception 'Every run screenshot must include a valid uploaded file.';
    end if;

    if coalesce(proof_item ->> 'distance_km', '') !~ '^[0-9]+([.][0-9]+)?$' then
      raise exception 'Every run screenshot must include a valid positive distance.';
    end if;
    proof_distance := (proof_item ->> 'distance_km')::numeric;
    if proof_distance <= 0 or proof_distance > 1000 then
      raise exception 'Every run screenshot distance must be greater than zero.';
    end if;

    begin
      proof_date := nullif(proof_item ->> 'activity_date', '')::date;
    exception when others then
      raise exception 'Every run screenshot must include a valid run date.';
    end;
    if proof_date is null then
      raise exception 'Every run screenshot must include a run date.';
    end if;

    total_distance_value := total_distance_value + proof_distance;
    final_completion_date := greatest(coalesce(final_completion_date, proof_date), proof_date);
    normalized_proof_entries := normalized_proof_entries || jsonb_build_array(jsonb_build_object(
      'proof_path', left(trim(proof_item ->> 'proof_path'), 1000),
      'file_name', left(coalesce(nullif(trim(proof_item ->> 'file_name'), ''), 'Run screenshot'), 255),
      'distance_km', round(proof_distance, 2),
      'activity_date', proof_date
    ));
  end loop;

  if jsonb_array_length(normalized_proof_entries) = 0 then
    if strava_value is null then
      raise exception 'Please submit a Strava/activity link or upload at least one run screenshot.';
    end if;
    if coalesce(payload ->> 'total_distance_km', payload ->> 'completion_distance', '') !~ '^[0-9]+([.][0-9]+)?$' then
      raise exception 'Enter a valid completed distance for the activity link.';
    end if;
    total_distance_value := coalesce(payload ->> 'total_distance_km', payload ->> 'completion_distance')::numeric;
    begin
      final_completion_date := nullif(payload ->> 'completion_date', '')::date;
    exception when others then
      raise exception 'Enter a valid completion date.';
    end;
    if final_completion_date is null then
      raise exception 'Enter the completion date.';
    end if;
  end if;

  total_distance_value := round(total_distance_value, 2);
  if total_distance_value <= 0 or total_distance_value > 1000 then
    raise exception 'The cumulative completed distance is invalid.';
  end if;
  if required_distance_value is not null and total_distance_value < required_distance_value then
    raise exception 'Cumulative distance is % km. It must reach % km for %.',
      total_distance_value, required_distance_value, registration_record.race_category;
  end if;

  proof_value := nullif(normalized_proof_entries -> 0 ->> 'proof_path', '');

  select *
  into existing_record
  from public.virtual_completion_submissions vcs
  where vcs.registration_id = registration_record.id
  limit 1;

  if found and existing_record.status = 'approved' then
    raise exception 'This virtual run completion has already been approved.';
  end if;

  if found then
    update public.virtual_completion_submissions
    set
      completion_distance = to_char(total_distance_value, 'FM999999990.00') || ' km',
      total_distance_km = total_distance_value,
      required_distance_km = required_distance_value,
      completion_date = final_completion_date,
      elapsed_time = nullif(payload ->> 'elapsed_time', ''),
      strava_activity_url = strava_value,
      proof_path = proof_value,
      proof_entries = normalized_proof_entries,
      runner_note = nullif(payload ->> 'runner_note', ''),
      status = 'pending_review',
      verifier_note = null,
      reviewed_by = null,
      reviewed_at = null,
      updated_at = now()
    where id = existing_record.id
    returning id into new_id;
  else
    insert into public.virtual_completion_submissions (
      event_id, registration_id, reference_number, full_name, email, race_category,
      completion_distance, total_distance_km, required_distance_km, completion_date,
      elapsed_time, strava_activity_url, proof_path, proof_entries, runner_note, status
    )
    values (
      registration_record.event_id, registration_record.id, registration_record.reference_number,
      registration_record.full_name, registration_record.email, registration_record.race_category,
      to_char(total_distance_value, 'FM999999990.00') || ' km',
      total_distance_value,
      required_distance_value,
      final_completion_date,
      nullif(payload ->> 'elapsed_time', ''),
      strava_value,
      proof_value,
      normalized_proof_entries,
      nullif(payload ->> 'runner_note', ''),
      'pending_review'
    )
    returning id into new_id;
  end if;

  return query
  select vcs.id, vcs.status, vcs.certificate_number
  from public.virtual_completion_submissions vcs
  where vcs.id = new_id;
end;
$fn$;

grant execute on function public.lookup_virtual_completion(text, text, text) to anon, authenticated;
grant execute on function public.submit_virtual_completion(jsonb) to anon, authenticated;

