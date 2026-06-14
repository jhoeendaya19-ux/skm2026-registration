# Phase 7 - Owner Event Settings

This phase adds an Owner-only settings area so key website content can be changed without redeploying.

## What The Owner Can Edit

From the admin dashboard, the Owner can update:

- Event name
- Event date
- Venue
- Organizer name
- Hero subtitle
- Contact email and phone
- Race fees
- Race kit claiming sites
- Waiver text
- Data privacy consent text
- Event logo
- Singlet image
- Medal image
- Finisher shirt image
- Warmer image
- Tumbler image
- GCash QR
- Maya QR
- Bank QR

The public site reads these settings from Supabase when it loads.

## Required Supabase Step

Run this SQL file in Supabase SQL Editor:

`09-owner-event-settings.sql`

This creates:

- `event_settings` table
- `site-assets` public storage bucket
- Owner-only settings update rules
- Owner-only asset upload rules

It also removes the hard-coded claiming-site restriction so future claiming sites can be edited by the Owner.

## Redeploy Step

After running the SQL, redeploy these files to Vercel:

- `index.html`
- `admin.html`
- `vercel.json`
- `README.md`

## How To Use

1. Log in to `admin.html` as Owner.
2. Click **Event Settings**.
3. Edit content or upload images.
4. Click **Save Settings**.
5. Refresh the public site.

No redeploy is needed after changing settings inside the Owner dashboard.

## Notes

Uploaded images are stored in Supabase Storage under the `site-assets` bucket.

Public visitors can view those assets, but only Owner accounts can upload or change them.
