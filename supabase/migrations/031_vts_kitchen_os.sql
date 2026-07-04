-- ============================================================
-- VTS Kitchen OS — migration 031  (VERIFIED against live schema)
-- is_account_member(target_account_id uuid, min_role account_role_enum DEFAULT 'viewer')
-- roles: owner > admin > agent > viewer
-- messages.sender_type ('customer','agent','bot') ALREADY exists (001) — untouched.
-- ============================================================

-- 1. Conversation-level bot control (Smart Handoff mirror)
ALTER TABLE conversations
  ADD COLUMN IF NOT EXISTS vts_bot_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS vts_handoff_at TIMESTAMPTZ;

-- 2. Alerts (browser ringing: handoffs + new orders)
CREATE TABLE IF NOT EXISTS vts_alerts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (type IN ('handoff', 'new_order')),
  conversation_id UUID REFERENCES conversations(id) ON DELETE CASCADE,
  order_ref TEXT,
  phone TEXT,
  title TEXT NOT NULL,
  body TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'acknowledged')),
  acked_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  acked_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_vts_alerts_pending ON vts_alerts (account_id, status) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_vts_alerts_created ON vts_alerts (created_at DESC);

ALTER TABLE vts_alerts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vts_alerts_select ON vts_alerts;
CREATE POLICY vts_alerts_select ON vts_alerts
  FOR SELECT USING (is_account_member(account_id));           -- any member (viewer+)
DROP POLICY IF EXISTS vts_alerts_ack ON vts_alerts;
CREATE POLICY vts_alerts_ack ON vts_alerts
  FOR UPDATE USING (is_account_member(account_id, 'agent'))   -- agent+ can acknowledge
  WITH CHECK (is_account_member(account_id, 'agent'));

-- 3. Orders (sales dashboard + ops kanban)
CREATE TABLE IF NOT EXISTS vts_orders (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  order_ref TEXT NOT NULL UNIQUE,
  phone TEXT NOT NULL,
  customer_name TEXT,
  branch_id TEXT,
  branch_name TEXT,
  area TEXT,
  address TEXT,
  items JSONB NOT NULL DEFAULT '[]'::jsonb,
  deal_label TEXT,
  subtotal INTEGER NOT NULL DEFAULT 0,
  delivery_fee INTEGER NOT NULL DEFAULT 0,
  total INTEGER NOT NULL DEFAULT 0,
  payment_method TEXT,
  payment_mode TEXT,
  payment_status TEXT,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('awaiting_payment','pending','preparing','dispatched','delivered','cancelled')),
  notes TEXT,
  contact_id UUID REFERENCES contacts(id) ON DELETE SET NULL,
  conversation_id UUID REFERENCES conversations(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_vts_orders_created ON vts_orders (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_vts_orders_status ON vts_orders (account_id, status);
CREATE INDEX IF NOT EXISTS idx_vts_orders_phone ON vts_orders (phone);

DROP TRIGGER IF EXISTS trg_vts_orders_updated ON vts_orders;
CREATE TRIGGER trg_vts_orders_updated BEFORE UPDATE ON vts_orders
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

ALTER TABLE vts_orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vts_orders_select ON vts_orders;
CREATE POLICY vts_orders_select ON vts_orders
  FOR SELECT USING (is_account_member(account_id));
DROP POLICY IF EXISTS vts_orders_update ON vts_orders;
CREATE POLICY vts_orders_update ON vts_orders
  FOR UPDATE USING (is_account_member(account_id, 'agent'))
  WITH CHECK (is_account_member(account_id, 'agent'));
-- inserts only via service-role (n8n ingest) — no INSERT policy on purpose

-- 4. Daily sales view (Asia/Karachi; business day rolls at 5am)
CREATE OR REPLACE VIEW vts_daily_sales
WITH (security_invoker = true) AS
SELECT
  account_id,
  ((created_at AT TIME ZONE 'Asia/Karachi') - INTERVAL '5 hours')::date AS business_date,
  COUNT(*)                                              AS orders,
  COUNT(*) FILTER (WHERE status <> 'cancelled')         AS orders_valid,
  SUM(total) FILTER (WHERE status <> 'cancelled')       AS gross_sales_rs,
  SUM(delivery_fee) FILTER (WHERE status <> 'cancelled') AS delivery_fees_rs,
  AVG(total) FILTER (WHERE status <> 'cancelled')       AS avg_order_value_rs
FROM vts_orders
GROUP BY account_id, business_date;

-- 5. Realtime (guarded so the migration is safely re-runnable)
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE vts_alerts;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE vts_orders;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
