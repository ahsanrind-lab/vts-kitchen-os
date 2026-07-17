-- 042_c2_order_ingestion.sql (V3.1 C2 - STAGING ONLY until approved)
-- Durable idempotent order ingestion + explicit ack + replay + reconciliation +
-- feature flags (authority + rollback switches). Sheets NOT touched; dual-write
-- compatibility = n8n keeps writing Sheets; this adds the durable Supabase path.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='outbox_events') THEN
    RAISE EXCEPTION 'PREFLIGHT 042: 040 not applied';
  END IF;
END $$;

ALTER TABLE outbox_events DROP CONSTRAINT IF EXISTS outbox_events_event_type_check;
ALTER TABLE outbox_events ADD CONSTRAINT outbox_events_event_type_check CHECK (event_type IN
  ('delivery_assigned','delivery_collected','delivery_completed','delivery_failed',
   'delivery_reassigned','customer_status_changed','admin_correction','campaign_queued',
   'order_ingested','reconciliation_drift'));
ALTER TABLE vts_alerts DROP CONSTRAINT IF EXISTS vts_alerts_type_check;
ALTER TABLE vts_alerts ADD CONSTRAINT vts_alerts_type_check CHECK (type IN ('handoff','new_order','reconciliation'));

CREATE TABLE IF NOT EXISTS feature_flags (
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  flag TEXT NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT FALSE,
  updated_by UUID,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (account_id, flag)
);
ALTER TABLE feature_flags ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ff_select ON feature_flags;
CREATE POLICY ff_select ON feature_flags FOR SELECT USING (is_account_member(account_id));
DROP POLICY IF EXISTS ff_owner_write ON feature_flags;
CREATE POLICY ff_owner_write ON feature_flags FOR ALL
  USING (is_account_member(account_id,'owner')) WITH CHECK (is_account_member(account_id,'owner'));

CREATE TABLE IF NOT EXISTS order_ingest_log (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  source TEXT NOT NULL DEFAULT 'n8n_tap' CHECK (source IN ('n8n_tap','replay','manual')),
  external_key TEXT NOT NULL,
  payload JSONB NOT NULL,
  status TEXT NOT NULL DEFAULT 'received' CHECK (status IN ('received','applied','duplicate','failed','dead')),
  attempts INT NOT NULL DEFAULT 1,
  last_error TEXT,
  order_id UUID REFERENCES vts_orders(id),
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  applied_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_ingest_status ON order_ingest_log(status, received_at);
CREATE INDEX IF NOT EXISTS idx_ingest_key ON order_ingest_log(external_key);
ALTER TABLE order_ingest_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ingest_admin_select ON order_ingest_log;
CREATE POLICY ingest_admin_select ON order_ingest_log FOR SELECT USING (is_account_member(account_id,'admin'));

CREATE OR REPLACE FUNCTION public.ingest_order(p_account UUID, p_payload JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_ref TEXT; v_log UUID; v_order UUID; v_missing TEXT[]:='{}'; k TEXT;
BEGIN
  v_ref := p_payload->>'order_ref';
  IF COALESCE(v_ref,'')='' THEN
    INSERT INTO public.order_ingest_log (account_id, external_key, payload, status, last_error)
    VALUES (p_account, '(missing)', p_payload, 'failed', 'order_ref missing') RETURNING id INTO v_log;
    RETURN jsonb_build_object('ok',false,'ack','rejected','ingest_id',v_log,'error','order_ref missing');
  END IF;
  SELECT id INTO v_order FROM public.vts_orders WHERE order_ref = v_ref;
  IF FOUND THEN
    INSERT INTO public.order_ingest_log (account_id, external_key, payload, status, order_id, applied_at)
    VALUES (p_account, v_ref, p_payload, 'duplicate', v_order, NOW()) RETURNING id INTO v_log;
    RETURN jsonb_build_object('ok',true,'ack','duplicate','ingest_id',v_log,'order_id',v_order);
  END IF;
  FOREACH k IN ARRAY ARRAY['phone','total','branch_id'] LOOP
    IF p_payload->>k IS NULL THEN v_missing := v_missing || k; END IF;
  END LOOP;
  IF array_length(v_missing,1) > 0 THEN
    INSERT INTO public.order_ingest_log (account_id, external_key, payload, status, last_error)
    VALUES (p_account, v_ref, p_payload, 'failed', 'missing: '||array_to_string(v_missing,',')) RETURNING id INTO v_log;
    RETURN jsonb_build_object('ok',false,'ack','rejected','ingest_id',v_log,'error','missing: '||array_to_string(v_missing,','));
  END IF;
  INSERT INTO public.vts_orders (account_id, order_ref, phone, customer_name, branch_id, branch_name, area, address,
    items, deal_label, subtotal, delivery_fee, total, payment_method, payment_mode, payment_status, status, notes)
  VALUES (p_account, v_ref, p_payload->>'phone', p_payload->>'customer_name', p_payload->>'branch_id', p_payload->>'branch_name',
    p_payload->>'area', p_payload->>'address', COALESCE(p_payload->'items','[]'::jsonb), p_payload->>'deal_label',
    COALESCE((p_payload->>'subtotal')::int,0), COALESCE((p_payload->>'delivery_fee')::int,0), (p_payload->>'total')::int,
    p_payload->>'payment_method', p_payload->>'payment_mode', p_payload->>'payment_status',
    COALESCE(p_payload->>'status','pending'), p_payload->>'notes')
  RETURNING id INTO v_order;
  INSERT INTO public.order_ingest_log (account_id, external_key, payload, status, order_id, applied_at)
  VALUES (p_account, v_ref, p_payload, 'applied', v_order, NOW()) RETURNING id INTO v_log;
  PERFORM private.outbox_emit(p_account, p_payload->>'branch_id', 'order_ingested', 'ing:'||v_ref,
    jsonb_build_object('order_ref',v_ref,'total',(p_payload->>'total')::int));
  RETURN jsonb_build_object('ok',true,'ack','applied','ingest_id',v_log,'order_id',v_order);
END; $$;
REVOKE ALL ON FUNCTION public.ingest_order(UUID,JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ingest_order(UUID,JSONB) FROM authenticated, anon;
GRANT EXECUTE ON FUNCTION public.ingest_order(UUID,JSONB) TO service_role;

CREATE OR REPLACE FUNCTION public.replay_failed_ingests(p_limit INT DEFAULT 20)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE rec RECORD; res JSONB; n_ok INT:=0; n_fail INT:=0;
BEGIN
  FOR rec IN SELECT * FROM public.order_ingest_log WHERE status='failed' AND attempts < 5
             ORDER BY received_at LIMIT p_limit FOR UPDATE SKIP LOCKED LOOP
    res := public.ingest_order(rec.account_id, rec.payload);
    IF (res->>'ok')::boolean THEN
      UPDATE public.order_ingest_log SET status='applied', attempts=attempts+1, applied_at=NOW(),
        order_id=(res->>'order_id')::uuid, last_error=NULL WHERE id=rec.id;
      n_ok := n_ok+1;
    ELSE
      UPDATE public.order_ingest_log SET attempts=attempts+1,
        status = CASE WHEN attempts+1 >= 5 THEN 'dead' ELSE 'failed' END,
        last_error = res->>'error' WHERE id=rec.id;
      n_fail := n_fail+1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('replayed_ok',n_ok,'still_failing',n_fail);
END; $$;
REVOKE ALL ON FUNCTION public.replay_failed_ingests(INT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.replay_failed_ingests(INT) FROM authenticated, anon;
GRANT EXECUTE ON FUNCTION public.replay_failed_ingests(INT) TO service_role;

CREATE TABLE IF NOT EXISTS recon_runs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  business_date DATE NOT NULL,
  sheets_count INT NOT NULL,
  supabase_count INT NOT NULL,
  drift JSONB NOT NULL DEFAULT '[]'::jsonb,
  status TEXT NOT NULL CHECK (status IN ('ok','drift')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE recon_runs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS recon_select ON recon_runs;
CREATE POLICY recon_select ON recon_runs FOR SELECT USING (is_account_member(account_id,'admin'));

CREATE OR REPLACE FUNCTION public.reconcile_orders(p_account UUID, p_business_date DATE, p_sheets JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_drift JSONB := '[]'::jsonb; v_sb JSONB; v_run UUID; v_scount INT; v_bcount INT; s RECORD;
BEGIN
  SELECT COALESCE(jsonb_object_agg(order_ref, jsonb_build_object('total',total,'status',status,'branch',branch_id)),'{}'::jsonb)
  INTO v_sb FROM public.vts_orders
  WHERE account_id=p_account
    AND ((created_at AT TIME ZONE 'Asia/Karachi') - INTERVAL '5 hours')::date = p_business_date;
  v_scount := jsonb_array_length(p_sheets);
  v_bcount := (SELECT count(*) FROM jsonb_object_keys(v_sb));
  FOR s IN SELECT * FROM jsonb_to_recordset(p_sheets) AS x(order_ref TEXT, total INT, status TEXT, branch_id TEXT) LOOP
    IF v_sb ? s.order_ref THEN
      IF (v_sb->s.order_ref->>'total')::int IS DISTINCT FROM s.total THEN
        v_drift := v_drift || jsonb_build_object('order_ref',s.order_ref,'kind','total','sheets',s.total,'supabase',(v_sb->s.order_ref->>'total')::int); END IF;
      IF (v_sb->s.order_ref->>'status') IS DISTINCT FROM s.status THEN
        v_drift := v_drift || jsonb_build_object('order_ref',s.order_ref,'kind','status','sheets',s.status,'supabase',v_sb->s.order_ref->>'status'); END IF;
      IF (v_sb->s.order_ref->>'branch') IS DISTINCT FROM s.branch_id THEN
        v_drift := v_drift || jsonb_build_object('order_ref',s.order_ref,'kind','branch','sheets',s.branch_id,'supabase',v_sb->s.order_ref->>'branch'); END IF;
      v_sb := v_sb - s.order_ref;
    ELSE
      v_drift := v_drift || jsonb_build_object('order_ref',s.order_ref,'kind','missing_in_supabase');
    END IF;
  END LOOP;
  v_drift := v_drift || COALESCE((SELECT jsonb_agg(jsonb_build_object('order_ref',k,'kind','missing_in_sheets'))
    FROM jsonb_object_keys(v_sb) k),'[]'::jsonb);
  INSERT INTO public.recon_runs (account_id, business_date, sheets_count, supabase_count, drift, status)
  VALUES (p_account, p_business_date, v_scount, v_bcount, v_drift,
    CASE WHEN jsonb_array_length(v_drift)=0 THEN 'ok' ELSE 'drift' END)
  RETURNING id INTO v_run;
  IF jsonb_array_length(v_drift) > 0 THEN
    INSERT INTO public.vts_alerts (account_id, type, title, body)
    VALUES (p_account,'reconciliation','Reconciliation drift '||p_business_date,
            jsonb_array_length(v_drift)||' drift item(s)');
    PERFORM private.outbox_emit(p_account, NULL, 'reconciliation_drift', 'recon:'||p_business_date||':'||v_run,
      jsonb_build_object('run_id',v_run,'items',jsonb_array_length(v_drift)));
  END IF;
  RETURN jsonb_build_object('ok',true,'run_id',v_run,'drift_count',jsonb_array_length(v_drift));
END; $$;
REVOKE ALL ON FUNCTION public.reconcile_orders(UUID,DATE,JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reconcile_orders(UUID,DATE,JSONB) FROM authenticated, anon;
GRANT EXECUTE ON FUNCTION public.reconcile_orders(UUID,DATE,JSONB) TO service_role;

-- Flags seeded per tenant (default OFF) in seed scripts. ROLLBACK: DROP
-- reconcile_orders/replay_failed_ingests/ingest_order; DROP recon_runs,
-- order_ingest_log, feature_flags; restore prior CHECK constraints (031/040).
