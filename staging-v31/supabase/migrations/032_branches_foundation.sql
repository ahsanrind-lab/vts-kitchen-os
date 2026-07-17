-- 032_branches_foundation.sql  (V3.1 Arc A - STAGING ONLY until approved)
-- Branch registry keyed by the engine's existing TEXT BR_* codes.
-- Grounded on real schema @ main 03ff23a: vts_orders.branch_id TEXT.
-- Structure only - seeding is environment-specific (seed/001_pdn_branches_seed.sql).

-- PREFLIGHT (fail closed on drift)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='vts_orders') THEN
    RAISE EXCEPTION 'PREFLIGHT 032: vts_orders missing - wrong database or 031 not applied';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='vts_orders' AND column_name='branch_id' AND data_type='text') THEN
    RAISE EXCEPTION 'PREFLIGHT 032: vts_orders.branch_id is not TEXT - schema drift, do not proceed';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='is_account_member') THEN
    RAISE EXCEPTION 'PREFLIGHT 032: is_account_member() missing - 017 not applied';
  END IF;
END $$;

-- FORWARD
CREATE TABLE IF NOT EXISTS branches (
  code TEXT PRIMARY KEY CHECK (code ~ '^BR_[A-Z]{2,5}$'),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  opens_at TIME,
  closes_at TIME,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_branches_account ON branches(account_id);

DROP TRIGGER IF EXISTS trg_branches_updated ON branches;
CREATE TRIGGER trg_branches_updated BEFORE UPDATE ON branches
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

ALTER TABLE branches ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS branches_select ON branches;
CREATE POLICY branches_select ON branches FOR SELECT USING (is_account_member(account_id));
DROP POLICY IF EXISTS branches_write ON branches;
CREATE POLICY branches_write ON branches FOR ALL USING (is_account_member(account_id, 'admin')) WITH CHECK (is_account_member(account_id, 'admin'));

-- Staff home branch (NULL = unscoped: owner/admin account-wide).
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS branch_code TEXT REFERENCES branches(code) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_profiles_branch ON profiles(branch_code);

-- Alert branch scoping (NULL = account-wide handoff alert BY DESIGN - N1 carve-out).
ALTER TABLE vts_alerts ADD COLUMN IF NOT EXISTS branch_code TEXT REFERENCES branches(code) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_vts_alerts_branch ON vts_alerts(branch_code);

-- FK for existing TEXT column: NOT VALID now; VALIDATE after seed.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='fk_vts_orders_branch') THEN
    ALTER TABLE vts_orders ADD CONSTRAINT fk_vts_orders_branch FOREIGN KEY (branch_id) REFERENCES branches(code) NOT VALID;
  END IF;
END $$;

-- VERIFY (after seed): branches count = 6; orphan branch_id rows = 0;
--   ALTER TABLE vts_orders VALIDATE CONSTRAINT fk_vts_orders_branch;
-- ROLLBACK:
--   ALTER TABLE vts_orders DROP CONSTRAINT IF EXISTS fk_vts_orders_branch;
--   ALTER TABLE vts_alerts DROP COLUMN IF EXISTS branch_code;
--   ALTER TABLE profiles DROP COLUMN IF EXISTS branch_code;
--   DROP TABLE IF EXISTS branches;
-- (No data loss: vts_orders.branch_id TEXT untouched by rollback.)
