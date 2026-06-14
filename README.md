# Off Ground Events - Final Combined Backend Improvements

This package combines Phase 1 and Phase 2.

This is the clean GitHub upload folder. Upload the contents of this folder to your GitHub repository.

## Included

Phase 1:

- Owner-managed race categories
- Physical Run and Virtual Run category type
- Category price, capacity, status, inclusions, and inclusion flags
- Owner-managed products/add-ons
- Product stock, active status, applicable categories, image, and variants
- Dynamic registration payment summary
- Backend recalculation of totals

Phase 2:

- Owner-managed custom registration fields
- Frontend content editor
- FAQ editor
- Route highlight photo/caption editor
- General event settings
- Event status, registration dates, payment account details, confirmation message, and maintenance mode

## Supabase SQL Order

Run these in Supabase SQL Editor in order:

1. `supabase-sql/11-categories-products-phase1.sql`
2. `supabase-sql/12-phase2-content-form-settings.sql`

These scripts keep existing registrations and add the new backend structures.

## Deploy Files

Deploy this folder to Vercel:

- `index.html`
- `event.html`
- `admin.html`
- `vercel.json`
- `README.md`
- SQL files can stay in the package for reference, but they are not served as website pages.

## Owner Workflow After Deployment

1. Log in to `admin.html`.
2. Select the event.
3. Open Event Settings.
4. Use the tabs:
   - Content
   - Catalog
   - Form Fields
   - Route Highlights
   - General
5. Save settings or save categories/products as needed.
6. Refresh the public event page to see updates.

Normal frontend edits such as text, FAQ, route photos, banner, logo, QR codes, payment details, form fields, categories, and products no longer require redeployment.
