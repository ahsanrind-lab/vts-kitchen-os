-- 043_c2_flag_security.sql (STAGING ONLY) applied to staging 2026-07-18.
-- Binding C2 corrections: ops-scope authority flags (service-only set_ops_flag
-- with reason+preflight+audit), PII-redacted ingest receipts (+purge policy),
-- config-driven business-day cutoff, batched reconcile. Canonical SQL below
-- matches the exact statements applied via the platform SQL channel.

ALTER TABLE feature_flags ADD COLUMN IF NOT EXISTS scope TEXT NOT NULL DEFAULT 'tenant' CHECK (scope IN ('tenant','vts_ops'));
INSERT INTO feature_flags (account_id, flag, scope) SELECT DISTINCT account_id, f, 'vts_ops' FROM feature_flags, unnest(ARRAY['FF_C2_INGEST_ENABLED','FF_SHEETS_CUTOVER']) f ON CONFLICT (account_id, flag) DO NOTHING;
UPDATE feature_flags SET scope='vts_ops' WHERE flag IN ('FF_C2_SUPABASE_AUTHORITY','FF_C2_INGEST_ENABLED','FF_SHEETS_CUTOVER');
DROP POLICY IF EXISTS ff_owner_write ON feature_flags;
CREATE POLICY ff_owner_write ON feature_flags FOR ALL USING (is_account_member(account_id,'owner') AND scope='tenant') WITH CHECK (is_account_member(account_id,'owner') AND scope='tenant');
CREATE TABLE IF NOT EXISTS flag_audit (id UUID PRIMARY KEY DEFAULT uuid_generate_v4(), account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, flag TEXT NOT NULL, old_value BOOLEAN, new_value BOOLEAN NOT NULL, reason TEXT NOT NULL, actor TEXT NOT NULL, preflight_ok BOOLEAN NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW());
ALTER TABLE flag_audit ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS flag_audit_select ON flag_audit;
CREATE POLICY flag_audit_select ON flag_audit FOR SELECT USING (is_account_member(account_id,'admin'));
CREATE OR REPLACE FUNCTION public.set_ops_flag(p_account UUID, p_flag TEXT, p_enabled BOOLEAN, p_reason TEXT, p_actor TEXT, p_preflight_ack BOOLEAN) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_old BOOLEAN;
BEGIN
  IF COALESCE(p_reason,'')='' THEN RETURN jsonb_build_object('ok',false,'code','reason_required'); END IF;
  IF NOT COALESCE(p_preflight_ack,false) THEN RETURN jsonb_build_object('ok',false,'code','preflight_ack_required'); END IF;
  SELECT enabled INTO v_old FROM public.feature_flags WHERE account_id=p_account AND flag=p_flag AND scope='vts_ops' FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','not_an_ops_flag'); END IF;
  UPDATE public.feature_flags SET enabled=p_enabled, updated_at=NOW() WHERE account_id=p_account AND flag=p_flag;
  INSERT INTO public.flag_audit (account_id, flag, old_value, new_value, reason, actor, preflight_ok) VALUES (p_account, p_flag, v_old, p_enabled, p_reason, COALESCE(p_actor,'service:unknown'), true);
  RETURN jsonb_build_object('ok',true,'flag',p_flag,'old',v_old,'new',p_enabled,'rollback_ready',true);
END; $fn$;
REVOKE ALL ON FUNCTION public.set_ops_flag(UUID,TEXT,BOOLEAN,TEXT,TEXT,BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_ops_flag(UUID,TEXT,BOOLEAN,TEXT,TEXT,BOOLEAN) FROM authenticated, anon;
GRANT EXECUTE ON FUNCTION public.set_ops_flag(UUID,TEXT,BOOLEAN,TEXT,TEXT,BOOLEAN) TO service_role;
CREATE TABLE IF NOT EXISTS ops_config (account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, key TEXT NOT NULL, value JSONB NOT NULL, updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), PRIMARY KEY (account_id, key));
ALTER TABLE ops_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ops_config_select ON ops_config;
CREATE POLICY ops_config_select ON ops_config FOR SELECT USING (is_account_member(account_id));
INSERT INTO ops_config (account_id, key, value) SELECT DISTINCT account_id, 'business_day_cutoff_hours', '5'::jsonb FROM feature_flags ON CONFLICT DO NOTHING;
CREATE OR REPLACE FUNCTION private.business_date(p_account UUID, p_at TIMESTAMPTZ) RETURNS DATE LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $fn$ SELECT ((p_at AT TIME ZONE 'Asia/Karachi') - make_interval(hours => COALESCE((SELECT (value)::int FROM public.ops_config WHERE account_id=p_account AND key='business_day_cutoff_hours'), 5)))::date $fn$;
REVOKE ALL ON FUNCTION private.business_date(UUID,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.business_date(UUID,TIMESTAMPTZ) TO authenticated, service_role;
CREATE OR REPLACE FUNCTION private.redact_ingest_receipt() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$ BEGIN IF NEW.status IN ('applied','duplicate') THEN NEW.payload := jsonb_build_object('redacted',true,'order_ref',NEW.external_key); END IF; RETURN NEW; END; $fn$;
DROP TRIGGER IF EXISTS trg_ingest_redact ON order_ingest_log;
CREATE TRIGGER trg_ingest_redact BEFORE INSERT OR UPDATE ON order_ingest_log FOR EACH ROW EXECUTE FUNCTION private.redact_ingest_receipt();
CREATE OR REPLACE FUNCTION public.purge_ingest_receipts() RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $fn$ WITH a AS (DELETE FROM public.order_ingest_log WHERE status IN ('applied','duplicate') AND received_at < NOW() - INTERVAL '30 days' RETURNING 1), b AS (DELETE FROM public.order_ingest_log WHERE status = 'dead' AND received_at < NOW() - INTERVAL '90 days' RETURNING 1) SELECT jsonb_build_object('purged_success',(SELECT count(*) FROM a),'purged_dead',(SELECT count(*) FROM b)); $fn$;
REVOKE ALL ON FUNCTION public.purge_ingest_receipts() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_ingest_receipts() FROM authenticated, anon;
GRANT EXECUTE ON FUNCTION public.purge_ingest_receipts() TO service_role;
DROP FUNCTION IF EXISTS public.reconcile_orders(UUID,DATE,JSONB);
CREATE OR REPLACE FUNCTION public.reconcile_orders(p_account UUID, p_business_date DATE, p_sheets JSONB, p_options JSONB DEFAULT '{}'::jsonb) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_drift JSONB := '[]'::jsonb; v_sb JSONB; v_run UUID; v_scount INT; v_bcount INT; s RECORD; v_skip_missing BOOLEAN := COALESCE((p_options->>'skip_missing_checks')::boolean,false);
BEGIN
  SELECT COALESCE(jsonb_object_agg(order_ref, jsonb_build_object('total',total,'status',status,'branch',branch_id)),'{}'::jsonb) INTO v_sb FROM public.vts_orders WHERE account_id=p_account AND private.business_date(p_account, created_at) = p_business_date;
  v_scount := jsonb_array_length(p_sheets); v_bcount := (SELECT count(*) FROM jsonb_object_keys(v_sb));
  FOR s IN SELECT * FROM jsonb_to_recordset(p_sheets) AS x(order_ref TEXT, total INT, status TEXT, branch_id TEXT) LOOP
    IF v_sb ? s.order_ref THEN
      IF (v_sb->s.order_ref->>'total')::int IS DISTINCT FROM s.total THEN v_drift := v_drift || jsonb_build_object('order_ref',s.order_ref,'kind','total','sheets',s.total,'supabase',(v_sb->s.order_ref->>'total')::int); END IF;
      IF (v_sb->s.order_ref->>'status') IS DISTINCT FROM s.status THEN v_drift := v_drift || jsonb_build_object('order_ref',s.order_ref,'kind','status','sheets',s.status,'supabase',v_sb->s.order_ref->>'status'); END IF;
      IF (v_sb->s.order_ref->>'branch') IS DISTINCT FROM s.branch_id THEN v_drift := v_drift || jsonb_build_object('order_ref',s.order_ref,'kind','branch','sheets',s.branch_id,'supabase',v_sb->s.order_ref->>'branch'); END IF;
      v_sb := v_sb - s.order_ref;
    ELSIF NOT v_skip_missing THEN v_drift := v_drift || jsonb_build_object('order_ref',s.order_ref,'kind','missing_in_supabase'); END IF;
  END LOOP;
  IF NOT v_skip_missing THEN v_drift := v_drift || COALESCE((SELECT jsonb_agg(jsonb_build_object('order_ref',k,'kind','missing_in_sheets')) FROM jsonb_object_keys(v_sb) k),'[]'::jsonb); END IF;
  INSERT INTO public.recon_runs (account_id, business_date, sheets_count, supabase_count, drift, status) VALUES (p_account, p_business_date, v_scount, v_bcount, v_drift, CASE WHEN jsonb_array_length(v_drift)=0 THEN 'ok' ELSE 'drift' END) RETURNING id INTO v_run;
  IF jsonb_array_length(v_drift) > 0 THEN
    INSERT INTO public.vts_alerts (account_id, type, title, body) VALUES (p_account,'reconciliation','Reconciliation drift '||p_business_date, jsonb_array_length(v_drift)||' drift item(s)');
    PERFORM private.outbox_emit(p_account, NULL, 'reconciliation_drift', 'recon:'||p_business_date||':'||v_run, jsonb_build_object('run_id',v_run,'items',jsonb_array_length(v_drift)));
  END IF;
  RETURN jsonb_build_object('ok',true,'run_id',v_run,'drift_count',jsonb_array_length(v_drift),'batch_mode',v_skip_missing);
END; $fn$;
REVOKE ALL ON FUNCTION public.reconcile_orders(UUID,DATE,JSONB,JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reconcile_orders(UUID,DATE,JSONB,JSONB) FROM authenticated, anon;
GRANT EXECUTE ON FUNCTION public.reconcile_orders(UUID,DATE,JSONB,JSONB) TO service_role;
-- ROLLBACK: restore 042 definitions (unscoped ff_owner_write; 3-arg reconcile; drop flag_audit/ops_config/set_ops_flag/purge/redact trigger).
