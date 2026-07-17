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

## Test classification note
All matrix tests so far = DATABASE-CONTEXT/RLS tests (SET LOCAL ROLE + jwt.claims
simulation). NOT full real-auth E2E: actual JWT login + UI flows happen when CRM
staging connects, using the real Auth identities below.

## Real staging Auth identities (2026-07-17)
8 GoTrue users (owner/admin/agent-DHA/viewer-JHR/rider-DHA x2/rider-JHR/tenant2),
ids ...101..108, emails @pdn-staging.test/@other.test. Passwords = random bcrypt
of discarded entropy (unknowable, stored nowhere). GoTrue admin list 200 OK.
Future login: admin generateLink (recovery) in-page when CRM staging connects.

## Repo layout normalization (2026-07-17)
032-039 copied into supabase/migrations/ (exact SQL, one commit each, no
collisions, NOT reapplied). CLI discovery now 001-041 complete.

## Arc C apply log (2026-07-17)
040 outbox (service-role claim/lease/dead-letter) HTTP 201 '040'; 041 RPCs
(10 public + 3 private) HTTP 201 '041'. History = 001-041.
EVIDENCE: anon RPC + SELECT denied; authenticated denied outbox_claim_batch;
unknown sub fail-closed; staff preparing->ready ok + duplicate-safe; cross-branch
+ cross-tenant fail-closed; PARALLEL assign race -> exactly one winner, loser
already_assigned same id; wrong rider not_assigned_to_you; parallel collect-vs-
fail serialized to legal collected->failed; reassign -> new delivery rider-108;
outbox dup key collapsed to 1 row; lease: A=3, B=3, third claim 0; complete ok=
delivered, fail=backoff pending, max_attempts=dead; admin_correct notes ok,
total blocked (field_not_correctable).
