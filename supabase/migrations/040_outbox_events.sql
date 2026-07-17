-- 040_outbox_events.sql (V3.1 Arc C - STAGING ONLY until approved)
-- Transactional outbox. No client writes; worker access via service_role-only
-- claim/complete functions (lease semantics, retries, dead-letter). Minimal
-- payloads (no secrets). Operational channel separate from marketing.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='deliveries') THEN
    RAISE EXCEPTION 'PREFLIGHT 040: 035 not applied';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS outbox_events (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  branch_code TEXT REFERENCES branches(code),
  event_type TEXT NOT NULL CHECK (event_type IN
    ('delivery_assigned','delivery_collected','delivery_completed','delivery_failed',
     'delivery_reassigned','customer_status_changed','admin_correction','campaign_queued')),
  channel TEXT NOT NULL DEFAULT 'operational' CHECK (channel IN ('operational','marketing')),
  idempotency_key TEXT NOT NULL UNIQUE,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','processing','delivered','failed','dead')),
  attempts INT NOT NULL DEFAULT 0,
  max_attempts INT NOT NULL DEFAULT 8,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  claimed_by TEXT,
  lease_until TIMESTAMPTZ,
  last_error TEXT,
  delivered_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_outbox_due ON outbox_events(status, next_attempt_at);
CREATE INDEX IF NOT EXISTS idx_outbox_account ON outbox_events(account_id, created_at DESC);
DROP TRIGGER IF EXISTS trg_outbox_updated ON outbox_events;
CREATE TRIGGER trg_outbox_updated BEFORE UPDATE ON outbox_events
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

ALTER TABLE outbox_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS outbox_admin_select ON outbox_events;
CREATE POLICY outbox_admin_select ON outbox_events FOR SELECT
  USING (is_account_member(account_id, 'admin'));

CREATE OR REPLACE FUNCTION private.outbox_emit(
  p_account UUID, p_branch TEXT, p_type TEXT, p_key TEXT, p_payload JSONB
) RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$
  INSERT INTO public.outbox_events (account_id, branch_code, event_type, idempotency_key, payload)
  VALUES (p_account, p_branch, p_type, p_key, COALESCE(p_payload,'{}'::jsonb))
  ON CONFLICT (idempotency_key) DO NOTHING;
$$;
REVOKE ALL ON FUNCTION private.outbox_emit(UUID,TEXT,TEXT,TEXT,JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.outbox_emit(UUID,TEXT,TEXT,TEXT,JSONB) TO service_role;

CREATE OR REPLACE FUNCTION public.outbox_claim_batch(p_worker TEXT, p_batch INT DEFAULT 10)
RETURNS SETOF public.outbox_events LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$
  UPDATE public.outbox_events o
  SET status='processing', claimed_by=p_worker, attempts=o.attempts+1,
      lease_until = NOW() + INTERVAL '2 minutes'
  WHERE o.id IN (
    SELECT id FROM public.outbox_events
    WHERE (status='pending' AND next_attempt_at <= NOW())
       OR (status='processing' AND lease_until < NOW())
    ORDER BY next_attempt_at
    LIMIT p_batch
    FOR UPDATE SKIP LOCKED
  )
  RETURNING o.*;
$$;
REVOKE ALL ON FUNCTION public.outbox_claim_batch(TEXT,INT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.outbox_claim_batch(TEXT,INT) FROM authenticated, anon;
GRANT EXECUTE ON FUNCTION public.outbox_claim_batch(TEXT,INT) TO service_role;

CREATE OR REPLACE FUNCTION public.outbox_complete(p_id UUID, p_ok BOOLEAN, p_error TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v RECORD;
BEGIN
  SELECT * INTO v FROM public.outbox_events WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;
  IF p_ok THEN
    UPDATE public.outbox_events SET status='delivered', delivered_at=NOW(), last_error=NULL, lease_until=NULL WHERE id=p_id;
  ELSIF v.attempts >= v.max_attempts THEN
    UPDATE public.outbox_events SET status='dead', last_error=p_error, lease_until=NULL WHERE id=p_id;
  ELSE
    UPDATE public.outbox_events SET status='pending', last_error=p_error, lease_until=NULL,
      next_attempt_at = NOW() + make_interval(secs => 30 * v.attempts * v.attempts) WHERE id=p_id;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.outbox_complete(UUID,BOOLEAN,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.outbox_complete(UUID,BOOLEAN,TEXT) FROM authenticated, anon;
GRANT EXECUTE ON FUNCTION public.outbox_complete(UUID,BOOLEAN,TEXT) TO service_role;

-- VERIFY: grants + duplicate collapse + lease/dead-letter in Arc C tests.
-- ROLLBACK: DROP FUNCTION outbox_claim_batch/outbox_complete/private.outbox_emit; DROP TABLE outbox_events;

