-- 033_order_status_expansion.sql  (V3.1 Arc A - STAGING ONLY until approved)
-- Expands vts_orders.status CHECK from live 6-state set to 9-state model.
-- Additive for existing rows. New states written ONLY by Arc C RPCs behind flags.
-- Live set (031): awaiting_payment,pending,preparing,dispatched,delivered,cancelled
-- Added: ready, collected, delivery_failed
-- Compatibility: pre-rider flow pending->preparing->dispatched->delivered (unchanged);
-- rider flow pending->preparing->ready->dispatched->collected->delivered;
-- dispatched/collected->delivery_failed->(reassign)->dispatched.

-- PREFLIGHT
DO $$
DECLARE bad INT;
BEGIN
  SELECT COUNT(*) INTO bad FROM vts_orders
  WHERE status NOT IN ('awaiting_payment','pending','preparing','dispatched','delivered','cancelled','ready','collected','delivery_failed');
  IF bad > 0 THEN
    RAISE EXCEPTION 'PREFLIGHT 033: % rows carry unknown status values', bad;
  END IF;
END $$;

-- FORWARD (031 CHECK was inline/unnamed: find by definition, drop, recreate named)
DO $$
DECLARE c RECORD;
BEGIN
  FOR c IN
    SELECT con.conname FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    WHERE rel.relname = 'vts_orders' AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%status%IN%'
  LOOP
    EXECUTE format('ALTER TABLE vts_orders DROP CONSTRAINT %I', c.conname);
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='vts_orders_status_check_v31') THEN
    ALTER TABLE vts_orders ADD CONSTRAINT vts_orders_status_check_v31
      CHECK (status IN ('awaiting_payment','pending','preparing','ready','dispatched','collected','delivered','delivery_failed','cancelled'));
  END IF;
END $$;

-- VERIFY: pg_get_constraintdef of vts_orders_status_check_v31; test row status='ready' ok, 'bogus' fails.
-- ROLLBACK (precondition: zero rows in the 3 new states):
--   ALTER TABLE vts_orders DROP CONSTRAINT IF EXISTS vts_orders_status_check_v31;
--   ALTER TABLE vts_orders ADD CONSTRAINT vts_orders_status_check_v31
--     CHECK (status IN ('awaiting_payment','pending','preparing','dispatched','delivered','cancelled'));
