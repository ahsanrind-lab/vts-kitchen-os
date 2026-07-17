-- 036_branch_scoped_rls.sql (V3.1 Arc B - STAGING ONLY until approved)
-- Replaces 031's account-wide vts_orders/vts_alerts policies with role-explicit
-- branch scoping + rider assigned-order visibility. Direct client status writes
-- REMOVED (RPC-only doctrine; Arc C provides RPCs).
-- NOTE for production cutover (future, approved): CRM UI must be on RPCs first
-- (FF_BRANCH_SCOPING arc), else staff status buttons lose write access.

-- PREFLIGHT
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='private' AND p.proname='can_view_branch') THEN
    RAISE EXCEPTION 'PREFLIGHT 036: private.can_view_branch missing - 035 not applied';
  END IF;
END $$;

-- FORWARD - vts_orders
DROP POLICY IF EXISTS vts_orders_select ON vts_orders;
DROP POLICY IF EXISTS vts_orders_update ON vts_orders;
DROP POLICY IF EXISTS vts_orders_staff_select ON vts_orders;
CREATE POLICY vts_orders_staff_select ON vts_orders FOR SELECT
  USING (private.can_view_branch(account_id, branch_id));
DROP POLICY IF EXISTS vts_orders_rider_select ON vts_orders;
CREATE POLICY vts_orders_rider_select ON vts_orders FOR SELECT
  USING (private.rider_assigned_to_order(id));
-- NO client UPDATE policy: all writes via SECURITY DEFINER RPCs / service ingest.

-- FORWARD - vts_alerts (branch_code NULL = account-wide handoff BY DESIGN)
DROP POLICY IF EXISTS vts_alerts_select ON vts_alerts;
DROP POLICY IF EXISTS vts_alerts_ack ON vts_alerts;
DROP POLICY IF EXISTS vts_alerts_scoped_select ON vts_alerts;
CREATE POLICY vts_alerts_scoped_select ON vts_alerts FOR SELECT
  USING (is_account_member(account_id)
         AND (branch_code IS NULL OR private.can_view_branch(account_id, branch_code)));
DROP POLICY IF EXISTS vts_alerts_scoped_ack ON vts_alerts;
CREATE POLICY vts_alerts_scoped_ack ON vts_alerts FOR UPDATE
  USING (is_account_member(account_id, 'agent')
         AND (branch_code IS NULL OR private.can_view_branch(account_id, branch_code)))
  WITH CHECK (is_account_member(account_id, 'agent')
         AND (branch_code IS NULL OR private.can_view_branch(account_id, branch_code)));

-- VERIFY: matrix tests (owner all; agent DHA only BR_DHA; viewer JHR only BR_JHR;
-- rider only assigned; agent direct UPDATE = 0 rows; NULL alert account-wide).
-- ROLLBACK (restore 031 policies):
--   DROP POLICY IF EXISTS vts_orders_staff_select ON vts_orders;
--   DROP POLICY IF EXISTS vts_orders_rider_select ON vts_orders;
--   CREATE POLICY vts_orders_select ON vts_orders FOR SELECT USING (is_account_member(account_id));
--   CREATE POLICY vts_orders_update ON vts_orders FOR UPDATE
--     USING (is_account_member(account_id,'agent')) WITH CHECK (is_account_member(account_id,'agent'));
--   DROP POLICY IF EXISTS vts_alerts_scoped_select ON vts_alerts;
--   DROP POLICY IF EXISTS vts_alerts_scoped_ack ON vts_alerts;
--   CREATE POLICY vts_alerts_select ON vts_alerts FOR SELECT USING (is_account_member(account_id));
--   CREATE POLICY vts_alerts_ack ON vts_alerts FOR UPDATE
--     USING (is_account_member(account_id,'agent')) WITH CHECK (is_account_member(account_id,'agent'));

