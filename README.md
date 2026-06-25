# Off Ground Events Latest Upload

This is the latest full upload package for the Off Ground Events website.

## Upload To GitHub

Upload or replace these website files in your GitHub repository:

- `index.html`
- `event.html`
- `admin.html`
- `vercel.json`
- `favicon.png`
- `favicon.ico`
- `apple-touch-icon.png`

Keep the `supabase-sql` folder in GitHub too, but SQL files are not run by Vercel. They are there so you have a record of what to run in Supabase.

## Run In Supabase

Run this new SQL file once in the Supabase SQL Editor:

- `supabase-sql/20-free-events-verifier-export-create-events.sql`

This assumes you already ran the earlier SQL files from the previous phases. If you are setting up a totally fresh Supabase project, run the earlier setup files first, then run this latest SQL file.

Only when you are ready to remove test registrations before launch, run:

- `supabase-sql/21-clear-test-registrations-before-launch.sql`

That cleanup file clears SKM 2026 test registration rows and resets reference/bib counters. It does not delete old uploaded proof images from Supabase Storage.

## What This Adds

- Verifier accounts can now export CSV registration reports.
- The payment page now states that payment verification can take up to 24 hours.
- Virtual runners now see J&T delivery as the actual kit delivery method, not a future placeholder.
- Owner accounts can create new events from the admin dashboard.
- New events can be created as either paid events or free registration-only events.
- Free events skip the payment page and submit directly after the registration form.
- Registration/payment tab buttons are removed from the runner page.
- After final payment submission, the runner cannot go back, edit, or resubmit in the same session.
- The small inclusion boxes were removed and the Sorsogon destination photo section was enlarged.
- Runner name is now captured as surname, first name, middle name, plus optional nickname.
- Runner address now uses Region, Province, Municipality/City, Barangay, and Street fields.
- Text fields are automatically converted to ALL CAPS, except practical fields like email.
- Event banner photo, event card photo, and Off Ground landing banner photo are separate owner-editable images.
- The existing banner image is preserved when you save settings without uploading a new banner.
- Event status now includes `Coming Soon`.
- Owner can enable/disable J&T shipping for Physical Run categories.
- 42K and 21K now include finisher shirts by default, and the finisher-shirt add-on is hidden for those categories.
- 3K is included in the latest event catalog update.

After uploading to GitHub, Vercel should redeploy automatically.
