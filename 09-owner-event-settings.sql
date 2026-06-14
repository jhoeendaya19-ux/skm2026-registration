-- Phase 7 owner-editable event settings.
-- Run this in Supabase SQL Editor before deploying Phase 7 files.

create table if not exists public.event_settings (
  id text primary key default 'main' check (id = 'main'),
  content jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by text
);

-- Phase 6 originally restricted claiming sites to the first three options.
-- Phase 7 makes claiming sites owner-editable, so remove that rigid check if it exists.
do $$
declare
  constraint_name text;
begin
  select conname
  into constraint_name
  from pg_constraint
  where conrelid = 'public.registrations'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) like '%race_kit_claiming_site%'
  limit 1;

  if constraint_name is not null then
    execute format('alter table public.registrations drop constraint %I', constraint_name);
  end if;
end $$;

insert into public.event_settings (id, content)
values (
  'main',
  '{
    "eventName": "Sorsogon Kasanggayahan Marathon 2026",
    "eventDate": "October 18, 2026",
    "venue": "Sorsogon Sports Complex",
    "organizer": "Off Ground",
    "heroSubtitle": "A festival running experience celebrating health, fitness, sports tourism, and the culture of Sorsogon.",
    "contactEmail": "hello@example.com",
    "contactPhone": "09XX XXX XXXX",
    "raceFees": {
      "42K": 2400,
      "21K": 2000,
      "10K": 1450,
      "5K": 1100,
      "3K": 950
    },
    "claimingSites": [
      "Ayala Malls Legazpi",
      "SM City Sorsogon",
      "Beans N Grapes Gubat"
    ],
    "assets": {
      "eventLogo": "",
      "heroImage": "",
      "singletImage": "",
      "medalImage": "",
      "finisherShirtImage": "",
      "warmerImage": "",
      "tumblerImage": "",
      "gcashQr": "",
      "mayaQr": "",
      "bankQr": ""
    },
    "waiverText": "I confirm that I accept the event waiver and understand the physical risks of joining a running event.",
    "privacyText": "I consent to the collection and processing of my information for registration, verification, race operations, and event communication."
  }'::jsonb
)
on conflict (id) do nothing;

alter table public.event_settings enable row level security;

drop policy if exists "Public can view event settings" on public.event_settings;
create policy "Public can view event settings"
on public.event_settings
for select
to anon, authenticated
using (id = 'main');

drop policy if exists "Owners can update event settings" on public.event_settings;
create policy "Owners can update event settings"
on public.event_settings
for update
to authenticated
using (public.current_admin_role() = 'owner')
with check (public.current_admin_role() = 'owner');

drop policy if exists "Owners can insert event settings" on public.event_settings;
create policy "Owners can insert event settings"
on public.event_settings
for insert
to authenticated
with check (public.current_admin_role() = 'owner');

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  (
    'site-assets',
    'site-assets',
    true,
    10485760,
    array['image/png', 'image/jpeg', 'image/webp', 'image/gif', 'image/svg+xml']
  )
on conflict (id) do nothing;

drop policy if exists "Public can view site assets" on storage.objects;
create policy "Public can view site assets"
on storage.objects
for select
to anon, authenticated
using (bucket_id = 'site-assets');

drop policy if exists "Owners can upload site assets" on storage.objects;
create policy "Owners can upload site assets"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'site-assets'
  and public.current_admin_role() = 'owner'
);

drop policy if exists "Owners can update site assets" on storage.objects;
create policy "Owners can update site assets"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'site-assets'
  and public.current_admin_role() = 'owner'
)
with check (
  bucket_id = 'site-assets'
  and public.current_admin_role() = 'owner'
);

drop policy if exists "Owners can delete site assets" on storage.objects;
create policy "Owners can delete site assets"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'site-assets'
  and public.current_admin_role() = 'owner'
);
