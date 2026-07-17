-- seed/001_pdn_branches_seed.sql (STAGING; parameterized - no hardcoded IDs)
-- Seeds the 6 PDN branches for ONE target account.
-- Usage (psql): \set account_id '<uuid-of-target-account>'
--               \i seed/001_pdn_branches_seed.sql
-- Staging target = synthetic test tenant. Any future approved production run
-- resolves the PDN account at run time - never hardcoded here.
-- Codes/names = engine AZ_AREAS ground truth (parse29). Hours informational;
-- Tariq Road change BLOCKED on official doc -> NULL for BR_TRQ until then.
INSERT INTO branches (code, account_id, name, is_active, opens_at, closes_at)
VALUES
  ('BR_DHA', :'account_id', 'DHA',           TRUE, '12:00', '05:00'),
  ('BR_FBA', :'account_id', 'FB Area',       TRUE, '12:00', '05:00'),
  ('BR_JHR', :'account_id', 'Johar',         TRUE, '12:00', '05:00'),
  ('BR_NKH', :'account_id', 'North Karachi', TRUE, '17:00', '05:00'),
  ('BR_NZB', :'account_id', 'Nazimabad',     TRUE, '17:00', '05:00'),
  ('BR_TRQ', :'account_id', 'Tariq Road',    TRUE, NULL,    NULL)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, is_active = EXCLUDED.is_active;

-- Post-seed verification (apply runbook):
-- SELECT COUNT(*) FROM branches;  -- 6
-- SELECT DISTINCT branch_id FROM vts_orders WHERE branch_id IS NOT NULL
--   AND branch_id NOT IN (SELECT code FROM branches);  -- 0 rows
-- ALTER TABLE vts_orders VALIDATE CONSTRAINT fk_vts_orders_branch;
