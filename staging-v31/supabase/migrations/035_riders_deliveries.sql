-- 035_riders_deliveries.sql (V3.1 Arc B - STAGING ONLY until approved)
-- Riders + deliveries + private rider helpers. RPC-only writes (no client
-- INSERT/UPDATE/DELETE policies). Riders NEVER gain is_account_member access.

-- PREFLIGHT
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='branches') THEN
    RAISE EXCEPTION 'PREFLIGHT 035: branches missing - 032 not applied';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid=e.enumtypid WHERE t.typname='account_role_enum' AND e.enumlabel='rider') THEN
    RAISE EXCEPTION 'PREFLIGHT 035: rider enum value missing - 034 not applied';
  END IF;
END $$;

-- FORWARD
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO authenticated, service_role;

CREATE TABLE IF NOT EXISTS riders (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  user_id UUID NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  branch_code TEXT NOT NULL REFERENCES branches(code),
  full_name TEXT NOT NULL,
  phone TEXT,
  is_available BOOLEAN NOT NULL DEFAULT FALSE,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_riders_account_branch ON riders(account_id, branch_code);
DROP TRIGGER IF EXISTS trg_riders_updated ON riders;
CREATE TRIGGER trg_riders_updated BEFORE UPDATE ON riders
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TABLE IF NOT EXISTS deliveries (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  order_id UUID NOT NULL REFERENCES vts_orders(id) ON DELETE CASCADE,
  rider_id UUID NOT NULL REFERENCES riders(id),
  branch_code TEXT NOT NULL REFERENCES branches(code),
  status TEXT NOT NULL DEFAULT 'assigned'
    CHECK (status IN ('assigned','collected','delivered','failed','reassigned')),
  amount_to_collect INTEGER NOT NULL DEFAULT 0,
  failure_reason TEXT,
  assigned_by UUID REFERENCES auth.users(id),
  assigned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  collected_at TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_deliveries_active_per_order
  ON deliveries(order_id) WHERE status IN ('assigned','collected');
CREATE INDEX IF NOT EXISTS idx_deliveries_rider ON deliveries(rider_id, status);
CREATE INDEX IF NOT EXISTS idx_deliveries_account_branch ON deliveries(account_id, branch_code);
DROP TRIGGER IF EXISTS trg_deliveries_updated ON deliveries;
CREATE TRIGGER trg_deliveries_updated BEFORE UPDATE ON deliveries
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- PRIVATE HELPERS (empty search_path, fully qualified, explicit grants)
CREATE OR REPLACE FUNCTION private.current_rider_id()
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT r.id FROM public.riders r WHERE r.user_id = auth.uid() AND r.is_active $$;
REVOKE ALL ON FUNCTION private.current_rider_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.current_rider_id() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION private.rider_assigned_to_order(p_order_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT EXISTS (SELECT 1 FROM public.deliveries d JOIN public.riders r ON r.id = d.rider_id
  WHERE d.order_id = p_order_id AND r.user_id = auth.uid() AND d.status IN ('assigned','collected')) $$;
REVOKE ALL ON FUNCTION private.rider_assigned_to_order(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.rider_assigned_to_order(UUID) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION private.can_view_branch(p_account_id UUID, p_branch TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT EXISTS (SELECT 1 FROM public.profiles p WHERE p.user_id = auth.uid()
  AND p.account_id = p_account_id
  AND ( p.account_role IN ('owner','admin')
        OR (p.account_role IN ('agent','viewer') AND p.branch_code IS NOT NULL
            AND p.branch_code = p_branch) )) $$;
REVOKE ALL ON FUNCTION private.can_view_branch(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.can_view_branch(UUID, TEXT) TO authenticated, service_role;

-- RLS
ALTER TABLE riders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS riders_staff_select ON riders;
CREATE POLICY riders_staff_select ON riders FOR SELECT USING (is_account_member(account_id));
DROP POLICY IF EXISTS riders_self_select ON riders;
CREATE POLICY riders_self_select ON riders FOR SELECT USING (user_id = auth.uid());
DROP POLICY IF EXISTS riders_admin_write ON riders;
CREATE POLICY riders_admin_write ON riders FOR ALL
  USING (is_account_member(account_id, 'admin')) WITH CHECK (is_account_member(account_id, 'admin'));

ALTER TABLE deliveries ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS deliveries_staff_select ON deliveries;
CREATE POLICY deliveries_staff_select ON deliveries FOR SELECT USING (is_account_member(account_id));
DROP POLICY IF EXISTS deliveries_rider_select ON deliveries;
CREATE POLICY deliveries_rider_select ON deliveries FOR SELECT
  USING (EXISTS (SELECT 1 FROM riders r WHERE r.id = deliveries.rider_id AND r.user_id = auth.uid()));
-- no client INSERT/UPDATE/DELETE: RPC-only (Arc C)

DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE deliveries;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- VERIFY: tables exist; helpers in private; policies riders=3, deliveries=2.
-- ROLLBACK:
--   DROP TABLE IF EXISTS deliveries; DROP TABLE IF EXISTS riders;
--   DROP FUNCTION IF EXISTS private.rider_assigned_to_order(UUID);
--   DROP FUNCTION IF EXISTS private.current_rider_id();
--   DROP FUNCTION IF EXISTS private.can_view_branch(UUID, TEXT);
