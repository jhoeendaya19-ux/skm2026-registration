# Phase 6 - Race Kit Options And Admin Analytics

This folder contains the updated website files for race kit fulfillment and stronger organizer analytics.

## What Phase 6 Adds

Participant registration form:

- Race kit option: pickup or ship via J&T
- Pickup claiming sites:
  - Ayala Malls Legazpi
  - SM City Sorsogon
  - Beans N Grapes Gubat
- Shipping address and contact number when shipping is selected

Admin dashboard:

- Submitted revenue
- Verified revenue
- Simple forecast revenue
- Shipping request count
- Analytics snapshot by category, payment method, and sex
- Filters for sex, payment method, approver, and race kit option
- Race kit details in review view
- Race kit fields included in CSV export

## Required Supabase Step

Before deploying the new website files, run this in Supabase SQL Editor:

`08-race-kit-and-analytics.sql`

This adds the new race kit/shipping columns and updates the registration submit function.

## Redeploy Step

After the SQL succeeds, redeploy these updated files to Vercel:

- `index.html`
- `admin.html`
- `vercel.json`
- `README.md`

## Future J&T Integration

The current system records that the runner wants shipping via J&T.

Later, we can add:

- Shipping fee calculation
- Automatic J&T booking
- Tracking number storage
- Shipping status updates
- Delivery notifications
