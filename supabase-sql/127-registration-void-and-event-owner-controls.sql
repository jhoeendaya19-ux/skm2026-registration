alter table public.registrations
  add column if not exists voided_at timestamptz,
  add column if not exists voided_by text,
  add column if not exists void_reason text;

create index if not exists registrations_event_voided_at_idx
  on public.registrations (event_id, voided_at)
  where voided_at is not null;

create or replace function public.admin_void_registration(
  p_registration_id uuid,
  p_reason text
)
returns table (
  id uuid,
  reference_number text,
  payment_status text,
  voided_at timestamptz,
  voided_by text,
  void_reason text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_registration public.registrations%rowtype;
  v_actor_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_global_role text := coalesce(public.current_admin_role(), '');
  v_event_role text;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  if v_actor_email = '' then
    raise exception 'A signed-in admin account is required.' using errcode = '42501';
  end if;

  if v_reason is null then
    raise exception 'A reason is required to void a registration.';
  end if;

  if char_length(v_reason) > 500 then
    raise exception 'The void reason must be 500 characters or fewer.';
  end if;

  select registration.*
  into v_registration
  from public.registrations registration
  where registration.id = p_registration_id
  for update;

  if not found then
    raise exception 'Registration not found.';
  end if;

  select event_admin.role
  into v_event_role
  from public.event_admins event_admin
  where event_admin.event_id = v_registration.event_id
    and lower(event_admin.email) = v_actor_email
  limit 1;

  if v_global_role <> 'owner'
    and coalesce(v_event_role, '') not in ('owner', 'verifier') then
    raise exception 'Only an owner or registration verifier assigned to this event can void registrations.' using errcode = '42501';
  end if;

  if v_registration.voided_at is not null
    or coalesce(v_registration.test_registration_note, '') ~* '^VOIDED:' then
    raise exception 'This registration has already been voided.';
  end if;

  if coalesce(v_registration.production_locked, false) then
    raise exception 'This registration is already production-locked. Remove it from production before voiding.';
  end if;

  if exists (
    select 1
    from public.fulfillment_packages package
    where package.registration_id = p_registration_id
      and package.is_active
  ) then
    raise exception 'This registration has an active fulfillment package. Clear that package before voiding.';
  end if;

  if exists (
    select 1
    from public.locked_additional_orders additional_order
    where additional_order.registration_id = p_registration_id
      and additional_order.status <> 'cancelled'
  ) then
    raise exception 'This registration has an active locked add-on order. Cancel that order before voiding.';
  end if;

  if exists (
    select 1
    from public.rfid_assignments assignment
    where assignment.registration_id = p_registration_id
      and assignment.is_active
  ) then
    raise exception 'This registration has an active RFID assignment. Unassign the chip before voiding.';
  end if;

  return query
  update public.registrations registration
  set
    payment_status = 'rejected',
    is_test_registration = true,
    test_registration_note = 'VOIDED: ' || v_reason,
    voided_at = now(),
    voided_by = v_actor_email,
    void_reason = v_reason,
    approved_at = null,
    approved_by = null,
    edited_at = now(),
    edited_by = v_actor_email,
    edit_note = 'Registration voided: ' || v_reason,
    admin_note = concat_ws(E'\n', nullif(registration.admin_note, ''), 'Registration voided: ' || v_reason),
    updated_at = now()
  where registration.id = p_registration_id
  returning
    registration.id,
    registration.reference_number,
    registration.payment_status,
    registration.voided_at,
    registration.voided_by,
    registration.void_reason;
end;
$$;

revoke all on function public.admin_void_registration(uuid, text) from public, anon;
grant execute on function public.admin_void_registration(uuid, text) to authenticated;

revoke all on function public.admin_void_test_registration(uuid, text) from public, anon, authenticated;

drop policy if exists "Event owners can update own event" on public.events;
create policy "Event owners can update own event"
on public.events
for update
to authenticated
using (
  exists (
    select 1
    from public.event_admins event_admin
    where event_admin.event_id = events.id
      and lower(event_admin.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and event_admin.role = 'owner'
  )
)
with check (
  exists (
    select 1
    from public.event_admins event_admin
    where event_admin.event_id = events.id
      and lower(event_admin.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and event_admin.role = 'owner'
  )
);

drop policy if exists "Event owners can insert own settings" on public.event_settings;
create policy "Event owners can insert own settings"
on public.event_settings
for insert
to authenticated
with check (
  exists (
    select 1
    from public.event_admins event_admin
    where event_admin.event_id = event_settings.id
      and lower(event_admin.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and event_admin.role = 'owner'
  )
);

drop policy if exists "Event owners can upload own site assets" on storage.objects;
create policy "Event owners can upload own site assets"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'site-assets'
  and exists (
    select 1
    from public.event_admins event_admin
    where event_admin.event_id = split_part(objects.name, '/', 2)
      and lower(event_admin.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and event_admin.role = 'owner'
  )
);

drop policy if exists "Event owners can update own site assets" on storage.objects;
create policy "Event owners can update own site assets"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'site-assets'
  and exists (
    select 1
    from public.event_admins event_admin
    where event_admin.event_id = split_part(objects.name, '/', 2)
      and lower(event_admin.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and event_admin.role = 'owner'
  )
)
with check (
  bucket_id = 'site-assets'
  and exists (
    select 1
    from public.event_admins event_admin
    where event_admin.event_id = split_part(objects.name, '/', 2)
      and lower(event_admin.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and event_admin.role = 'owner'
  )
);

drop policy if exists "Event owners can delete own site assets" on storage.objects;
create policy "Event owners can delete own site assets"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'site-assets'
  and exists (
    select 1
    from public.event_admins event_admin
    where event_admin.event_id = split_part(objects.name, '/', 2)
      and lower(event_admin.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and event_admin.role = 'owner'
  )
);
