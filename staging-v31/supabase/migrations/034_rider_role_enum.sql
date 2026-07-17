-- 034_rider_role_enum.sql  (V3.1 Arc A - STAGING ONLY until approved)
-- Adds 'rider' to account_role_enum. ISOLATED migration on purpose:
-- ALTER TYPE ... ADD VALUE cannot be added AND used in one transaction.
--
-- SECURITY PROPERTY (verified against 017's is_account_member source):
-- its role-rank CASE has no 'rider' arm => rank IS NULL => comparisons NULL
-- => EXISTS()=false => ALL existing is_account_member() policies DENY riders
-- automatically (fail-closed across the whole legacy schema). Rider access is
-- granted ONLY by rider-specific helpers/policies in Arc B (035+).
-- Do NOT widen is_account_member to know about riders - that would silently
-- grant riders viewer-level SELECT everywhere.

-- PREFLIGHT
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='account_role_enum') THEN
    RAISE EXCEPTION 'PREFLIGHT 034: account_role_enum missing - 017 not applied';
  END IF;
END $$;

-- FORWARD
ALTER TYPE account_role_enum ADD VALUE IF NOT EXISTS 'rider';

-- VERIFY: SELECT unnest(enum_range(NULL::account_role_enum));
--   expect owner,admin,agent,viewer,rider. pgTAP (Arc B): rider profile gets
--   ZERO rows from contacts/conversations/messages/vts_orders/vts_alerts.
-- ROLLBACK: enum values cannot be dropped in place. Compensating: ensure no
--   profiles row uses 'rider'; the unused value is inert (grants nothing).
