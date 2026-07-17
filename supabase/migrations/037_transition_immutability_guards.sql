-- 037_transition_immutability_guards.sql (V3.1 Arc B - STAGING ONLY until approved)
-- DB-level guards on vts_orders + deliveries: transition matrix, immutable
-- money/identity fields, RPC-context gate (app.vts_rpc='1' set only inside Arc C
-- SECURITY DEFINER RPCs) OR service_role (n8n ingest until C2 cutover) OR
-- app.vts_admin='1' (audited admin_correct_order only).

-- PREFLIGHT
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='vts_orders_status_check_v31') THEN
    RAISE EXCEPTION 'PREFLIGHT 037: 033 not applied';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='deliveries') THEN
    RAISE EXCEPTION 'PREFLIGHT 037: 035 not applied';
  END IF;
END $$;

-- FORWARD
CREATE OR REPLACE FUNCTION private.enforce_order_guards()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_rpc BOOLEAN := current_setting('app.vts_rpc', true) = '1';
  v_admin BOOLEAN := current_setting('app.vts_admin', true) = '1';
  v_service BOOLEAN := current_user = 'service_role';
  v_ok BOOLEAN;
BEGIN
  IF v_admin THEN RETURN NEW; END IF;
  IF NEW.order_ref IS DISTINCT FROM OLD.order_ref
     OR NEW.account_id IS DISTINCT FROM OLD.account_id
     OR NEW.phone IS DISTINCT FROM OLD.phone
     OR NEW.items::text IS DISTINCT FROM OLD.items::text
     OR NEW.subtotal IS DISTINCT FROM OLD.subtotal
     OR NEW.delivery_fee IS DISTINCT FROM OLD.delivery_fee
     OR NEW.total IS DISTINCT FROM OLD.total
     OR NEW.branch_id IS DISTINCT FROM OLD.branch_id THEN
    RAISE EXCEPTION 'VTS_GUARD: immutable field change rejected (admin correction path required)';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT (v_rpc OR v_service) THEN
      RAISE EXCEPTION 'VTS_GUARD: direct status change rejected (RPC-only)';
    END IF;
    v_ok := (OLD.status, NEW.status) IN (
      ('awaiting_payment','pending'), ('awaiting_payment','cancelled'),
      ('pending','preparing'), ('pending','cancelled'),
      ('preparing','ready'), ('preparing','cancelled'),
      ('preparing','dispatched'),
      ('ready','dispatched'), ('ready','cancelled'),
      ('dispatched','collected'), ('dispatched','delivered'),
      ('dispatched','delivery_failed'),
      ('collected','delivered'), ('collected','delivery_failed'),
      ('delivery_failed','dispatched')
    );
    IF NOT v_ok THEN
      RAISE EXCEPTION 'VTS_GUARD: illegal transition % -> %', OLD.status, NEW.status;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_vts_orders_guards ON vts_orders;
CREATE TRIGGER trg_vts_orders_guards BEFORE UPDATE ON vts_orders
  FOR EACH ROW EXECUTE FUNCTION private.enforce_order_guards();

CREATE OR REPLACE FUNCTION private.enforce_delivery_guards()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_rpc BOOLEAN := current_setting('app.vts_rpc', true) = '1';
  v_admin BOOLEAN := current_setting('app.vts_admin', true) = '1';
BEGIN
  IF v_admin THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT v_rpc THEN
      RAISE EXCEPTION 'VTS_GUARD: delivery status change rejected (RPC-only)';
    END IF;
    IF NOT ((OLD.status, NEW.status) IN (
      ('assigned','collected'), ('assigned','failed'),
      ('collected','delivered'), ('collected','failed'),
      ('failed','reassigned')
    )) THEN
      RAISE EXCEPTION 'VTS_GUARD: illegal delivery transition % -> %', OLD.status, NEW.status;
    END IF;
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.order_id IS DISTINCT FROM OLD.order_id
     OR NEW.rider_id IS DISTINCT FROM OLD.rider_id
     OR NEW.account_id IS DISTINCT FROM OLD.account_id
     OR NEW.amount_to_collect IS DISTINCT FROM OLD.amount_to_collect) THEN
    RAISE EXCEPTION 'VTS_GUARD: immutable delivery field change rejected';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_deliveries_guards ON deliveries;
CREATE TRIGGER trg_deliveries_guards BEFORE UPDATE ON deliveries
  FOR EACH ROW EXECUTE FUNCTION private.enforce_delivery_guards();

-- VERIFY: T-TRN/T-IMM matrix tests. ROLLBACK:
--   DROP TRIGGER IF EXISTS trg_vts_orders_guards ON vts_orders;
--   DROP TRIGGER IF EXISTS trg_deliveries_guards ON deliveries;
--   DROP FUNCTION IF EXISTS private.enforce_order_guards();
--   DROP FUNCTION IF EXISTS private.enforce_delivery_guards();


