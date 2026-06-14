# Phase 8 - Off Ground Multi-Event Platform

Phase 8 changes the structure from a single marathon website into an Off Ground event platform.

## What Changed

Public website:

- `index.html` is now the Off Ground Events landing page.
- It lists events managed by Off Ground.
- Kasanggayahan Marathon is the first event.
- Event cards link to `event.html?event=skm2026`.

Event page:

- `event.html` is the event-specific registration page.
- It loads settings based on the selected event.
- The old “Prototype” label/button has been removed.
- Banner image, QR codes, product images, fees, claiming sites, and form settings are loaded from Supabase.

Admin dashboard:

- Owner, Verifier, and Viewer can select which event to manage.
- Registration lists are filtered by selected event.
- Owner settings apply to the selected event.
- Verifiers/Viewers only see events assigned to their email.

Owner settings can now edit:

- Event text and details
- Banner photo
- Race fees
- Claiming sites
- Waiver/privacy copy
- Product and QR images
- Basic form field visibility:
  - Team/running club
  - Emergency contact
  - Optional purchases
  - Race kit claiming/shipping
  - J&T shipping option

## Required Supabase Step

Run this SQL file:

`10-multi-event-platform.sql`

This creates:

- `events`
- `event_admins`
- event-specific settings
- event-specific registration assignment
- safer event-specific approval permissions

It also keeps existing registrations under the first event:

`skm2026`

## Redeploy Step

After running the SQL, redeploy these files to Vercel:

- `index.html`
- `event.html`
- `admin.html`
- `vercel.json`
- `README.md`

## How To Test

1. Open the public Vercel URL.
2. Confirm it shows Off Ground Events.
3. Click the Kasanggayahan Marathon event card.
4. Submit a test registration.
5. Log in to admin.
6. Select the event from the event dropdown.
7. Confirm the registration appears under that event.
8. As Owner, open Event Settings and try changing a small field like contact phone.
9. Refresh the event page and confirm the change appears.

## Future Expansion

The database is now ready for multiple events. A later phase can add a full Owner UI for creating brand-new events from the dashboard.
