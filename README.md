# Off Ground Events Latest Upload

This is the latest full upload package for the Off Ground Events website.

## Upload To GitHub

Upload or replace these website files in your GitHub repository:

- `index.html`
- `event.html`
- `completion.html`
- `medical.html`
- `admin.html`
- `vercel.json`
- `favicon.png`
- `favicon.ico`
- `apple-touch-icon.png`

Keep the `supabase-sql` folder in GitHub too, but SQL files are not run by Vercel. They are there so you have a record of what to run in Supabase.

## Run In Supabase

If your Supabase already has the previous event/admin/virtual-run setup, run only this newest SQL file once in the Supabase SQL Editor:

- `supabase-sql/25-launch-polish-21k-medical-slots-photo.sql`

If you are setting up a totally fresh Supabase project, run the earlier setup files first, then run file `25` last.

Only when you are ready to remove test registrations before launch, run:

- `supabase-sql/21-clear-test-registrations-before-launch.sql`

That cleanup file clears SKM 2026 test registration rows and resets reference/bib counters. It does not delete old uploaded proof images from Supabase Storage.

## Redeploy Supabase Edge Function

Redeploy the updated email function so virtual completion approval can send the shipping confirmation email:

- `supabase/functions/send-registration-email/index.ts`

## What This Adds

- 21K runners now follow the same Fit-to-Run Medical Clearance workflow as 42K runners.
- Public categories now show remaining slots and the current rate period: Early Bird, Regular, or Late Registration.
- The event page now includes a registration countdown.
- Payment details now display editable Account Name, Position, Bank, and Account Number lines per QR method.
- Payment reminder styling is calmer and the default verification time is now up to 48 hours.
- Participant photo upload is optional and includes a consent checkbox for official promotional use.
- Virtual submission and medical clearance action links stay on the event page, not the Off Ground home page.
- J&T shipping remains automatic for virtual runners and disabled for physical/on-site runners unless the owner enables it.
- The visual theme was refreshed toward a cleaner blue-and-white style.

- Verifier accounts can now export CSV registration reports.
- The payment page now states that payment verification can take up to 48 hours.
- Virtual runners now see J&T delivery as the actual kit delivery method, not a future placeholder.
- Owner accounts can create new events from the admin dashboard.
- New events can be created as either paid events or free registration-only events.
- Free events skip the payment page and submit directly after the registration form.
- Virtual runners can submit Strava/activity links or completion screenshots after registration approval.
- Owner/verifier accounts can review and approve virtual completion submissions.
- Approved virtual completion submissions generate a certificate number.
- The virtual completion page displays a printable/downloadable certificate after approval.
- Virtual completion approval sends an email confirming that entitlements will be prepared for J&T shipping.
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
- Virtual completion approval email logging now accepts `virtual_completion_approved`.
- Virtual runners no longer choose a claiming site; they use J&T shipping details.
- Virtual runner shipping address now uses Region, Province, Municipality/City, Barangay, ZIP code, and Street fields, with a "same as address above" checkbox.
- Virtual runners automatically add a PHP 100 shipping fee to the payment total.
- Virtual runners receive virtual bib numbers such as `VR21-0012` upon approval.
- Bib numbering now uses one continuous sequence across all categories.
- Owner settings now include editable virtual certificate text, certificate logo, and certificate signature image.
- The public site now includes a Virtual Run Submission link.
- Virtual-run confirmation emails include the Virtual Run Submission link.
- Size chart images now also appear below the public Optional Add-ons section.
- Singlet size options are owner-editable and default from `3XS` to `3XL`.
- Nickname is now required.
- Name fields no longer accept numbers.
- Emergency contact number cannot match the participant contact number.
- Required fields show red asterisks and missing fields highlight after Proceed is clicked.
- 21K and 42K runners must acknowledge the Fit-to-Run Medical Certificate requirement before checkout.
- Added a 21K / 42K medical clearance upload page.
- Added private medical document storage and admin review.
- Admins can approve or reject 21K / 42K medical clearance with remarks.
- 21K / 42K race kit review shows a warning until medical clearance is approved.
- Rejected medical clearances can send an email with resubmission instructions.

After uploading to GitHub, Vercel should redeploy automatically.
