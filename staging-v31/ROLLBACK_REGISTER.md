# Staging Rollback Register - V3.1 (started 2026-07-17)
Production: LOCKED READ-ONLY. Live verified 2026-07-17: bot gppIrpdPfxmGqeAB active,
142 nodes, versionId f7f3a4db-1290-431d-93bb-83dc9c1cad23, engine eb4ce44b459828dd
(P29), sgate 66534aec2d058d1b, updatedAt 2026-07-12T01:57:38Z (no saves since P29).
Whole-workflow rollback/staging seed: (57b) sha16 04a38ee2a0899026 ONLY.
CRM main @ 03ff23a; dev/v3-staging cut from 03ff23a on 2026-07-17.

## Harness baseline (2026-07-17 20:36 PKT, node v22, engine parse29.js)
h22 13/13 | h23 21/21 | h24 21/21 | h25 8/8 | h26 8/8 | h27 18/18 | h28 10/10 |
h29 8/8 (=107/107) | h18 31/36 evening (run: node outputs/harness18.js parse29.js).
h18 discrepancy stays documented, not fixed (authority 2026-07-13 s6.5).

## Artifact ledger
| Artifact | Status | Rollback |
|---|---|---|
| supabase/migrations/032_branches_foundation.sql | committed, NOT APPLIED | inline block (drop FK/columns/table; no data loss) |
| supabase/migrations/033_order_status_expansion.sql | committed, NOT APPLIED | inline (restore 6-state CHECK; precondition in file) |
| supabase/migrations/034_rider_role_enum.sql | committed, NOT APPLIED | compensating (inert enum value) |
| supabase/seed/001_pdn_branches_seed.sql | committed, NOT APPLIED | DELETE FROM branches WHERE code LIKE 'BR_%' (staging) |

## Apply rules
One migration per apply; verify block passes before next; every apply logged here
with timestamp+result; nothing marked PASS without execution evidence; production
application only via approval package (MFA + key-rotation gates).

## Blockers (2026-07-17)
B2 staging Supabase (in progress) | B3 staging n8n (needs Docker host) |
B4 official menu/hours doc | B5 sandbox: no Postgres/no installs/no VPS-git-push.
