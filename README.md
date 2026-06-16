# Runner Flow, Media Settings, And Address Update

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

- `supabase-sql/18-runner-name-address-media-settings.sql`

This assumes you already ran the earlier SQL files from the previous phases. If you are setting up a totally fresh Supabase project, run SQL files `11` through `18` in order.

## What This Adds

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

After uploading to GitHub, Vercel should redeploy automatically.
