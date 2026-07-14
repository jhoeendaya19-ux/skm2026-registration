HOTFIX 63 - Singlet add-on supplier cost correction

Upload only admin.html to GitHub/Vercel.
No Supabase SQL change is needed.
No Edge Function change is needed.

Supplier payable now treats add-ons with 'singlet' in the name as PHP 220 each.
This fixes 3K Singlet Add-on rows showing blank supplier cost/payable.

