-- Phase 8 multi-event Off Ground platform.
-- Run this after Phase 7 setup.

create table if not exists public.events (
  id text primary key,
  name text not null,
  slug text not null unique,
  event_date text,
  venue text,
  status text not null default 'draft' check (status in ('draft', 'open', 'closed', 'archived')),
  banner_image text,
  summary text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.event_admins (
  id uuid primary key default gen_random_uuid(),
  event_id text not null references public.events(id) on delete cascade,
  email text not null,
  role text not null check (role in ('owner', 'verifier', 'viewer')),
  created_at timestamptz not null default now(),
  unique (event_id, email)
);

insert into public.events (id, name, slug, event_date, venue, status, summary)
values (
  'skm2026',
  'Sorsogon Kasanggayahan Marathon 2026',
  'sorsogon-kasanggayahan-marathon-2026',
  'October 18, 2026',
  'Sorsogon Sports Complex',
  'open',
  'A festival running experience celebrating health, fitness, sports tourism, and the culture of Sorsogon.'
)
on conflict (id) do update set
  name = excluded.name,
  slug = excluded.slug,
  event_date = excluded.event_date,
  venue = excluded.venue,
  status = excluded.status,
  summary = excluded.summary,
  updated_at = now();

insert into public.event_admins (event_id, email, role)
values
  ('skm2026', 'owner@offgroundevents.com', 'owner'),
  ('skm2026', 'verifier@offgroundevents.com', 'verifier'),
  ('skm2026', 'viewer@offgroundevents.com', 'viewer')
on conflict (event_id, email) do update set role = excluded.role;

alter table public.events enable row level security;
alter table public.event_admins enable row level security;

drop policy if exists "Public can view listed events" on public.events;
create policy "Public can view listed events"
on public.events
for select
to anon, authenticated
using (status in ('open', 'closed'));

drop policy if exists "Admins can view managed events" on public.events;
create policy "Admins can view managed events"
on public.events
for select
to authenticated
using (
  public.current_admin_role() = 'owner'
  or exists (
    select 1
    from public.event_admins ea
    where ea.event_id = events.id
      and lower(ea.email) = lower(auth.jwt() ->> 'email')
  )
);

drop policy if exists "Owners can manage events" on public.events;
create policy "Owners can manage events"
on public.events
for all
to authenticated
using (public.current_admin_role() = 'owner')
with check (public.current_admin_role() = 'owner');

drop policy if exists "Admins can view event assignments" on public.event_admins;
create policy "Admins can view event assignments"
on public.event_admins
for select
to authenticated
using (
  public.current_admin_role() = 'owner'
  or lower(email) = lower(auth.jwt() ->> 'email')
);

drop policy if exists "Owners can manage event assignments" on public.event_admins;
create policy "Owners can manage event assignments"
on public.event_admins
for all
to authenticated
using (public.current_admin_role() = 'owner')
with check (public.current_admin_role() = 'owner');

alter table public.registrations
add column if not exists event_id text not null default 'skm2026';

update public.registrations
set event_id = 'skm2026'
where event_id is null;

-- Phase 7 event_settings had one row named main. Phase 8 allows one row per event.
do $$
declare
  constraint_name text;
begin
  select conname
  into constraint_name
  from pg_constraint
  where conrelid = 'public.event_settings'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) like '%id = ''main''%'
  limit 1;

  if constraint_name is not null then
    execute format('alter table public.event_settings drop constraint %I', constraint_name);
  end if;
end $$;

insert into public.event_settings (id, content)
select
  'skm2026',
  jsonb_set(
    jsonb_set(
      coalesce(content, '{}'::jsonb),
      '{bannerImage}',
      '""'::jsonb,
      true
    ),
    '{formFields}',
    '{
      "showTeam": true,
      "requireTeam": false,
      "showEmergencyContact": true,
      "showOptionalPurchases": true,
      "showRaceKit": true,
      "showShipping": true
    }'::jsonb,
    true
  )
from public.event_settings
where id = 'main'
on conflict (id) do nothing;

insert into public.event_settings (id, content)
values (
  'skm2026',
  '{
    "eventName": "Sorsogon Kasanggayahan Marathon 2026",
    "eventDate": "October 18, 2026",
    "venue": "Sorsogon Sports Complex",
    "organizer": "Off Ground",
    "heroSubtitle": "A festival running experience celebrating health, fitness, sports tourism, and the culture of Sorsogon.",
    "contactEmail": "hello@example.com",
    "contactPhone": "09XX XXX XXXX",
    "raceFees": { "42K": 2400, "21K": 2000, "10K": 1450, "5K": 1100, "3K": 950 },
    "claimingSites": ["Ayala Malls Legazpi", "SM City Sorsogon", "Beans N Grapes Gubat"],
    "assets": {},
    "bannerImage": "",
    "waiverText": "I confirm that I accept the event waiver and understand the physical risks of joining a running event.",
    "privacyText": "I consent to the collection and processing of my information for registration, verification, race operations, and event communication.",
    "formFields": {
      "showTeam": true,
      "requireTeam": false,
      "showEmergencyContact": true,
      "showOptionalPurchases": true,
      "showRaceKit": true,
      "showShipping": true
    }
  }'::jsonb
)
on conflict (id) do nothing;

drop policy if exists "Public can view event settings" on public.event_settings;
create policy "Public can view event settings"
on public.event_settings
for select
to anon, authenticated
using (true);

drop policy if exists "Owners can update event settings" on public.event_settings;
create policy "Owners can update event settings"
on public.event_settings
for update
to authenticated
using (
  public.current_admin_role() = 'owner'
  or exists (
    select 1 from public.event_admins ea
    where ea.event_id = event_settings.id
      and lower(ea.email) = lower(auth.jwt() ->> 'email')
      and ea.role = 'owner'
  )
)
with check (
  public.current_admin_role() = 'owner'
  or exists (
    select 1 from public.event_admins ea
    where ea.event_id = event_settings.id
      and lower(ea.email) = lower(auth.jwt() ->> 'email')
      and ea.role = 'owner'
  )
);

drop policy if exists "Owners can insert event settings" on public.event_settings;
create policy "Owners can insert event settings"
on public.event_settings
for insert
to authenticated
with check (public.current_admin_role() = 'owner');

drop policy if exists "Admins can view registrations" on public.registrations;
create policy "Admins can view registrations"
on public.registrations
for select
to authenticated
using (
  public.current_admin_role() = 'owner'
  or exists (
    select 1 from public.event_admins ea
    where ea.event_id = registrations.event_id
      and lower(ea.email) = lower(auth.jwt() ->> 'email')
  )
);

create or replace function public.submit_registration(payload jsonb)
returns table(id uuid, reference_number text, payment_status text)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  new_id uuid;
  new_reference text;
  race_day date := date '2026-10-18';
  runner_birthdate date;
  runner_age integer;
  runner_is_minor boolean;
  kit_method text;
  target_event_id text;
begin
  target_event_id := coalesce(nullif(payload ->> 'event_id', ''), 'skm2026');
  runner_birthdate := (payload ->> 'birthdate')::date;
  runner_age := date_part('year', age(race_day, runner_birthdate))::integer;
  runner_is_minor := runner_age < 18;
  kit_method := payload ->> 'race_kit_delivery_method';
  new_reference := 'SKM2026-' || lpad(nextval('registration_ref_seq')::text, 3, '0');

  if runner_is_minor and (
    nullif(payload ->> 'guardian_name', '') is null
    or nullif(payload ->> 'guardian_relationship', '') is null
    or nullif(payload ->> 'guardian_contact_number', '') is null
    or nullif(payload ->> 'parental_consent_path', '') is null
  ) then
    raise exception 'Parental consent details are required for minor participants.';
  end if;

  if kit_method = 'pickup' and nullif(payload ->> 'race_kit_claiming_site', '') is null then
    raise exception 'Race kit claiming site is required.';
  end if;

  if kit_method = 'shipping' and (
    nullif(payload ->> 'shipping_address', '') is null
    or nullif(payload ->> 'shipping_contact_number', '') is null
  ) then
    raise exception 'Shipping address and contact number are required.';
  end if;

  insert into public.registrations (
    event_id, reference_number, full_name, birthdate, age_on_race_day, sex,
    complete_address, contact_number, email, race_category, race_fee, singlet_size,
    team, emergency_contact_name, emergency_relationship, emergency_contact_number,
    add_finisher_shirt, finisher_shirt_size, add_warmer, warmer_size, add_tumbler,
    total_amount, payment_method, transaction_reference, proof_of_payment_path,
    race_kit_delivery_method, race_kit_claiming_site, shipping_address,
    shipping_contact_number, shipping_status, race_kit_fulfillment_status,
    is_minor, guardian_name, guardian_relationship, guardian_contact_number,
    parental_consent_path, waiver_accepted, privacy_accepted
  )
  values (
    target_event_id, new_reference, payload ->> 'full_name', runner_birthdate, runner_age,
    payload ->> 'sex', payload ->> 'complete_address', payload ->> 'contact_number',
    payload ->> 'email', payload ->> 'race_category', (payload ->> 'race_fee')::numeric,
    payload ->> 'singlet_size', nullif(payload ->> 'team', ''),
    payload ->> 'emergency_contact_name', payload ->> 'emergency_relationship',
    payload ->> 'emergency_contact_number',
    coalesce((payload ->> 'add_finisher_shirt')::boolean, false), nullif(payload ->> 'finisher_shirt_size', ''),
    coalesce((payload ->> 'add_warmer')::boolean, false), nullif(payload ->> 'warmer_size', ''),
    coalesce((payload ->> 'add_tumbler')::boolean, false), (payload ->> 'total_amount')::numeric,
    payload ->> 'payment_method', payload ->> 'transaction_reference', payload ->> 'proof_of_payment_path',
    kit_method, nullif(payload ->> 'race_kit_claiming_site', ''), nullif(payload ->> 'shipping_address', ''),
    nullif(payload ->> 'shipping_contact_number', ''),
    case when kit_method = 'shipping' then 'requested' else 'not_applicable' end,
    case when kit_method = 'shipping' then 'for_shipping' else 'not_claimed' end,
    runner_is_minor, nullif(payload ->> 'guardian_name', ''), nullif(payload ->> 'guardian_relationship', ''),
    nullif(payload ->> 'guardian_contact_number', ''), nullif(payload ->> 'parental_consent_path', ''),
    (payload ->> 'waiver_accepted')::boolean, (payload ->> 'privacy_accepted')::boolean
  )
  returning registrations.id into new_id;

  return query
  select new_id, new_reference, 'pending_payment_verification'::text;
end;
$fn$;

grant execute on function public.submit_registration(jsonb) to anon;
grant execute on function public.submit_registration(jsonb) to authenticated;

create or replace function public.admin_update_registration_status(
  registration_id uuid,
  decision text,
  note text default ''
)
returns table(reference_number text, payment_status text, bib_number text, admin_note text)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  admin_role text;
  runner public.registrations%rowtype;
  counter public.bib_counters%rowtype;
  assigned_bib text;
  event_role text;
begin
  admin_role := public.current_admin_role();

  if decision not in ('approved', 'needs_correction', 'rejected') then
    raise exception 'Invalid admin decision.';
  end if;

  select *
  into runner
  from public.registrations
  where id = registration_id
  for update;

  if not found then
    raise exception 'Registration not found.';
  end if;

  select role
  into event_role
  from public.event_admins
  where event_id = runner.event_id
    and lower(email) = lower(auth.jwt() ->> 'email')
  limit 1;

  if admin_role <> 'owner' and event_role not in ('owner', 'verifier') then
    raise exception 'Only assigned Owner and Verifier admins can update this event registration.';
  end if;

  assigned_bib := runner.bib_number;

  if decision = 'approved' and assigned_bib is null then
    select *
    into counter
    from public.bib_counters
    where race_category = runner.race_category
    for update;

    if not found then
      raise exception 'Bib counter not found for race category.';
    end if;

    assigned_bib := counter.bib_prefix || '-' || lpad(counter.next_number::text, 4, '0');

    update public.bib_counters
    set next_number = next_number + 1
    where race_category = runner.race_category;
  end if;

  update public.registrations
  set
    payment_status = decision,
    bib_number = case when decision = 'approved' then assigned_bib else public.registrations.bib_number end,
    admin_note = nullif(note, ''),
    approved_at = case when decision = 'approved' then now() else public.registrations.approved_at end,
    approved_by = case when decision = 'approved' then auth.jwt() ->> 'email' else public.registrations.approved_by end,
    updated_at = now()
  where id = registration_id
  returning registrations.reference_number, registrations.payment_status, registrations.bib_number, registrations.admin_note
  into reference_number, payment_status, bib_number, admin_note;

  return next;
end;
$fn$;

grant execute on function public.admin_update_registration_status(uuid, text, text) to authenticated;
