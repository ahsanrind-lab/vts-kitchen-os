# Schema baseline (real repo, main @ 03ff23a) - read 2026-07-17
Source: supabase/migrations/ in this repo @ 03ff23a. Migrations present: 001-031.

## Facts V3.1 must honour (verified from 017 + 031 contents)
1. Role model: account_role_enum = (owner,admin,agent,viewer) on profiles.account_role;
   ONE account per user; helper is_account_member(target_account_id, min_role)
   SECURITY DEFINER, LANGUAGE sql, SET search_path = public, numeric CASE 4>3>2>1.
   -> Adding 'rider' makes the CASE return NULL => every existing is_account_member()
   policy DENIES riders automatically (fail-closed). Do NOT widen is_account_member;
   riders get their own helpers (Arc B). ALTER TYPE ADD VALUE = isolated migration.
2. Branch key is TEXT: vts_orders.branch_id TEXT carries engine BR_* codes
   (BR_DHA/FBA/JHR/NKH/NZB/TRQ). uuid-FK design is WRONG here. V3.1: branches.code
   TEXT PRIMARY KEY + FK on existing column (NOT VALID -> VALIDATE after seed).
3. vts_orders.status CHECK = 6 states; 033 adds ready/collected/delivery_failed.
4. vts_daily_sales view ALREADY has security_invoker = true.
5. vts_alerts: NO branch column pre-032; select viewer+, update agent+.
6. vts_orders RLS: select viewer+, update agent+; INSERT service-role only (Tap C).
7. realtime publication already includes vts_orders + vts_alerts.
8. updated_at via trigger update_updated_at_column() (001).
9. profiles.role TEXT is legacy/unused - distinct from account_role.
10. 017 rewrote ALL policies across ~26 tables - V3.1 policies land in NEW
    migrations only, never by editing 017.
