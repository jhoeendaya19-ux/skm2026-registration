begin;

alter table public.registrations
  drop constraint if exists registrations_bib_number_key;

alter table public.registrations
  drop constraint if exists registrations_event_bib_number_key;

alter table public.registrations
  add constraint registrations_event_bib_number_key unique (event_id, bib_number);

update public.registrations
set bib_number = '10-001',
    updated_at = now()
where event_id = 'mcdonalds-neon-run-2026'
  and bib_number = '10-1457'
  and payment_status = 'approved';

with neon_next_bib as (
  select coalesce(
    max((regexp_match(bib_number, '([0-9]+)$'))[1]::bigint),
    0
  ) + 1 as next_value
  from public.registrations
  where event_id = 'mcdonalds-neon-run-2026'
    and bib_number is not null
)
insert into public.event_counters(event_id, counter_key, next_value, updated_at)
select 'mcdonalds-neon-run-2026', 'bib', next_value, now()
from neon_next_bib
on conflict (event_id, counter_key) do update
set next_value = greatest(public.event_counters.next_value, excluded.next_value),
    updated_at = now();

create or replace function public.admin_update_registration_status(
  registration_id uuid,
  decision text,
  note text default ''::text
)
returns table(reference_number text, payment_status text, bib_number text, admin_note text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  admin_role text;
  runner public.registrations%rowtype;
  assigned_bib text;
  assigned_number bigint;
  event_role text;
  selected_category public.event_categories%rowtype;
  should_assign_bib boolean := true;
  category_is_virtual boolean := false;
  derived_prefix text;
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

  if admin_role <> 'owner' and coalesce(event_role, '') not in ('owner', 'verifier') then
    raise exception 'Only assigned Owner and Verifier admins can update this event registration.';
  end if;

  assigned_bib := runner.bib_number;

  if runner.category_id is not null then
    select *
    into selected_category
    from public.event_categories
    where id = runner.category_id;

    if found then
      category_is_virtual := selected_category.category_type = 'virtual';
      should_assign_bib := selected_category.requires_bib_number or category_is_virtual;
    end if;
  end if;

  if decision = 'approved' and assigned_bib is null and should_assign_bib then
    if category_is_virtual then
      derived_prefix := 'VR' || nullif(regexp_replace(runner.race_category, '[^0-9]+', '', 'g'), '');
      if derived_prefix is null or derived_prefix = 'VR' then
        derived_prefix := 'VR';
      end if;
    else
      derived_prefix := nullif(regexp_replace(runner.race_category, '[^0-9]+', '', 'g'), '');
      if derived_prefix is null then
        derived_prefix := upper(nullif(regexp_replace(runner.race_category, '[^0-9A-Za-z]+', '', 'g'), ''));
      end if;
      if derived_prefix is null then
        derived_prefix := 'BIB';
      end if;
    end if;

    if runner.event_id = 'mcdonalds-neon-run-2026' then
      insert into public.event_counters(event_id, counter_key, next_value, updated_at)
      values (runner.event_id, 'bib', 1, now())
      on conflict (event_id, counter_key) do nothing;

      update public.event_counters
      set next_value = next_value + 1,
          updated_at = now()
      where event_id = runner.event_id
        and counter_key = 'bib'
      returning next_value - 1 into assigned_number;

      assigned_bib := derived_prefix || '-' || lpad(assigned_number::text, 3, '0');
    else
      assigned_bib := derived_prefix || '-' || lpad(nextval('public.bib_global_seq')::text, 4, '0');
    end if;
  end if;

  update public.registrations
  set payment_status = decision,
      bib_number = case when decision = 'approved' then assigned_bib else public.registrations.bib_number end,
      admin_note = nullif(note, ''),
      approved_at = case when decision = 'approved' then now() else public.registrations.approved_at end,
      approved_by = case when decision = 'approved' then auth.jwt() ->> 'email' else public.registrations.approved_by end,
      updated_at = now()
  where id = registration_id
  returning registrations.reference_number,
            registrations.payment_status,
            registrations.bib_number,
            registrations.admin_note
  into reference_number, payment_status, bib_number, admin_note;

  return next;
end;
$function$;

revoke execute on function public.admin_update_registration_status(uuid, text, text) from public, anon;
grant execute on function public.admin_update_registration_status(uuid, text, text) to authenticated, service_role;

update public.event_settings
set content = jsonb_set(
      coalesce(content, '{}'::jsonb),
      '{faqItems}',
      $faqs$
      [
        {"id":"neon-faq-01","active":true,"sort_order":1,"question":"What is the McDonald's Neon Run 2026?","answer":"The McDonald's Neon Run 2026 is a neon-themed, non-competitive fun run organized by McDonald's Sorsogon for the benefit of Ronald McDonald House Charities Philippines. It brings the community together through fitness, music, fun, and a vibrant nighttime running experience while helping support families of children receiving medical care."},
        {"id":"neon-faq-02","active":true,"sort_order":2,"question":"Is there an age limit?","answer":"There is no age limit. Participants who are 17 years old or younger must complete the required parental or guardian consent process and should be accompanied by a parent or guardian."},
        {"id":"neon-faq-03","active":true,"sort_order":3,"question":"How can I register?","answer":"Register online at mcdonalds-neonrun.com, choose your experience, complete the participant and sizing details, pay the exact amount through QRPh, and upload a clear payment receipt."},
        {"id":"neon-faq-04","active":true,"sort_order":4,"question":"When is the registration period?","answer":"Online registration opens on September 30, 2026 and continues while slots and supplies are available. Follow the official McDonald's Neon Run channels for announcements."},
        {"id":"neon-faq-05","active":true,"sort_order":5,"question":"Is the online registration system secure?","answer":"Registration details and payment proofs are submitted through the official event platform and are accessible only to authorized event staff for registration, verification, and event operations."},
        {"id":"neon-faq-06","active":true,"sort_order":6,"question":"Can I register directly at a McDonald's store?","answer":"Registration is completed online through mcdonalds-neonrun.com. Any official onsite registration arrangements will be announced separately by the organizers."},
        {"id":"neon-faq-07","active":true,"sort_order":7,"question":"When and where is the event?","answer":"The McDonald's Neon Run 2026 will be held on December 13, 2026 at Sorsogon Capitol Park, Sorsogon City."},
        {"id":"neon-faq-08","active":true,"sort_order":8,"question":"What is included in my registration?","answer":"Participants receive the inclusions shown for their selected experience, including the official race singlet, race bib with timing chip, collector's cup, Burger McDo with bottled water, and a finisher's medal upon completing the race. Optional add-ons are listed separately at checkout."},
        {"id":"neon-faq-09","active":true,"sort_order":9,"question":"What is the material of the race singlet?","answer":"The official race singlet is made of dri-fit, 100% polyester material."},
        {"id":"neon-faq-10","active":true,"sort_order":10,"question":"Will there be onsite registration on race day?","answer":"No. Race-day onsite registration will not be available. Online registration remains open only while slots and supplies last."},
        {"id":"neon-faq-11","active":true,"sort_order":11,"question":"If I cannot attend, can I still claim the meal and finisher's medal?","answer":"No. The meal, collector's cup, and finisher's medal are race-day entitlements and are released only through the event redemption process."},
        {"id":"neon-faq-12","active":true,"sort_order":12,"question":"Can I change my race category after registering?","answer":"No. Once submitted and confirmed, registrations are non-transferable and the selected race category cannot be changed."},
        {"id":"neon-faq-13","active":true,"sort_order":13,"question":"Can I request a refund?","answer":"No. Registration payments are non-refundable and registrations are non-transferable, as stated in the participation terms accepted before submission."},
        {"id":"neon-faq-14","active":true,"sort_order":14,"question":"How much is delivery for virtual runners?","answer":"The applicable shipment fee is calculated and displayed on the payment page before submission. The organizer can update this fee when courier rates or fulfillment arrangements change."},
        {"id":"neon-faq-15","active":true,"sort_order":15,"question":"How will I know that my registration was successful?","answer":"You will receive a submission email after registering. After the organizer verifies your payment, you will receive an approval email containing your confirmed registration details and bib number. Check your inbox, promotions, and spam folders."},
        {"id":"neon-faq-16","active":true,"sort_order":16,"question":"What should I do if I do not receive an email?","answer":"Check your registration status using your MCDO2026 reference number and registered email address. You may also contact mcdosorsogon@lkygroup.com or message the official McDonald's Neon Run Facebook page."},
        {"id":"neon-faq-17","active":true,"sort_order":17,"question":"How will virtual runners receive their race kits?","answer":"Virtual race kits will be delivered to the registered shipping address through the organizer's courier. Delivery is expected during November 2026, subject to the announced fulfillment schedule."},
        {"id":"neon-faq-18","active":true,"sort_order":18,"question":"Can an unclaimed physical race kit be collected on event day?","answer":"Yes. Unclaimed physical race kits may be claimed on December 13, 2026 from 2:00 PM to 4:00 PM at the designated race-kit claiming booth, subject to the organizer's final advisory."},
        {"id":"neon-faq-19","active":true,"sort_order":19,"question":"Can I change my singlet or shirt size after registration?","answer":"No. Sizes cannot be changed after the registration form has been submitted. Please review the size charts carefully before confirming your order."},
        {"id":"neon-faq-20","active":true,"sort_order":20,"question":"Will there be winners for the fastest runners?","answer":"Yes. The top three finishers in the 5K and 10K race categories will be declared as winners."},
        {"id":"neon-faq-21","active":true,"sort_order":21,"question":"Where will the awarding ceremony take place?","answer":"The awarding ceremony will take place inside the Neon Run Race Village."},
        {"id":"neon-faq-22","active":true,"sort_order":22,"question":"Is the official race singlet required during the race?","answer":"Yes. Participants are required to wear the official McDonald's Neon Run race singlet during the event."},
        {"id":"neon-faq-23","active":true,"sort_order":23,"question":"When will the finisher's medal be given?","answer":"The finisher's medal will be awarded after the participant crosses the finish line. Keep your race bib visible so event staff can identify your entitlement."},
        {"id":"neon-faq-24","active":true,"sort_order":24,"question":"How do I claim the finisher's medal, collector's cup, and meal?","answer":"Present the applicable race-bib stubs at the designated redemption booths inside the Neon Run Race Village."},
        {"id":"neon-faq-25","active":true,"sort_order":25,"question":"Will there be baggage counters and changing areas?","answer":"Yes. Baggage counters and changing areas will be available at the Neon Run Race Village. Follow the posted event-day instructions for use."},
        {"id":"neon-faq-26","active":true,"sort_order":26,"question":"Will portalets be available?","answer":"No portalets will be available inside the Neon Run Race Village. Please plan accordingly before arriving at the venue."},
        {"id":"neon-faq-27","active":true,"sort_order":27,"question":"Will there be road closures and parking facilities?","answer":"Parts of the race route will be closed to traffic on event day. Refer to the official race and LGU traffic advisories, which are expected to be released before the event, for closure times and parking guidance."},
        {"id":"neon-faq-28","active":true,"sort_order":28,"question":"Are Senior Citizen or PWD discounts available?","answer":"No. The Neon Run is a fundraising activity for Ronald McDonald House Charities Philippines, and the event registration fee is not covered by the Senior Citizen or PWD discounts applicable to qualifying personal purchases of food, beverages, and other consumables."}
      ]
      $faqs$::jsonb,
      true
    ),
    updated_at = now(),
    updated_by = 'system:neon-faq-import'
where id = 'mcdonalds-neon-run-2026';

commit;
