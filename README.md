# Two-Step Checkout, Product Photos, Size Charts, And Vouchers

This is a focused update package for the current Off Ground Events website.

## Upload To GitHub

Replace these existing website files in your GitHub repository:

- `index.html`
- `event.html`
- `admin.html`
- `favicon.png`
- `favicon.ico`
- `apple-touch-icon.png`

Keep your existing `vercel.json` and older support files. You do not need to delete them.

## Run In Supabase

Run this new SQL file once in the Supabase SQL Editor:

- `supabase-sql/17-two-step-checkout-vouchers.sql`

This assumes you already ran the earlier SQL files from the previous phases. If you are setting up a totally fresh Supabase project, use the full `offground-github-upload` package and run SQL files `11` through `17` in order.

## What This Adds

- Registration now has Step 1: runner details, size choices, add-ons, and size charts.
- Payment now has Step 2: payment summary, QR code, voucher field, payment reference code, and receipt screenshot upload.
- QR codes are larger for easier phone scanning.
- The public pages now have a fuller Off Ground footer with explore links, contact details, legal/admin access, and social links.
- Payment instruction text and proof-of-payment reminder text are editable from the owner account.
- Footer/about text and footer contact address are editable from the owner account.
- Product/add-on photos now appear on the public event page and inside the registration add-on list.
- Two checkout size chart images can be uploaded from the owner account.
- The owner can create active/inactive vouchers in the Catalog tab.
- Voucher discounts are recalculated by Supabase during final registration submission.
- The admin dashboard has clearer guidance, easier filter clearing, and more readable table rows.

After uploading to GitHub, Vercel should redeploy automatically.
