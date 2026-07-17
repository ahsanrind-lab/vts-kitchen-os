-- 038_deliveries_riders_branch_scope.sql (V3.1 Arc B fix - STAGING ONLY)
-- Matrix run 2026-07-17 found: deliveries/riders staff SELECT was account-wide,
-- leaking cross-branch rows to agent/viewer (violates branch isolation). Scope
-- both via private.can_view_branch (owner/admin all; agent/viewer own branch
-- fail-closed). Rider self-policies unchanged.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='private' AND p.proname='can_view_branch') THEN
    RAISE EXCEPTION 'PREFLIGHT 038: 035 not applied';
  END IF;
END $$;

DROP POLICY IF EXISTS deliveries_staff_select ON deliveries;
CREATE POLICY deliveries_staff_select ON deliveries FOR SELECT
  USING (private.can_view_branch(account_id, branch_code));

DROP POLICY IF EXISTS riders_staff_select ON riders;
CREATE POLICY riders_staff_select ON riders FOR SELECT
  USING (private.can_view_branch(account_id, branch_code));

-- VERIFY: viewer JHR sees 0 BR_DHA deliveries and only BR_JHR riders.
-- ROLLBACK:
--   CREATE POLICY deliveries_staff_select ON deliveries FOR SELECT USING (is_account_member(account_id));
--   CREATE POLICY riders_staff_select ON riders FOR SELECT USING (is_account_member(account_id));


