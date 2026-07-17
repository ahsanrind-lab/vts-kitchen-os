-- 041_transactional_rpcs.sql (V3.1 Arc C - STAGING ONLY until approved)
-- Every RPC: SECURITY DEFINER, search_path='', row locks, prior-state
-- validation, account/branch/rider consistency, atomic outbox emit, idempotent
-- duplicate-retry, typed jsonb result. app.vts_rpc opens the 037/039 gate.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='outbox_events') THEN
    RAISE EXCEPTION 'PREFLIGHT 041: 040 not applied';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION private.staff_can_operate(p_account UUID, p_branch TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT public.is_account_member(p_account, 'agent') AND private.can_view_branch(p_account, p_branch) $$;
REVOKE ALL ON FUNCTION private.staff_can_operate(UUID,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.staff_can_operate(UUID,TEXT) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION private.staff_transition(p_order_id UUID, p_target TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE o RECORD;
BEGIN
  PERFORM set_config('app.vts_rpc','1',true);
  SELECT * INTO o FROM public.vts_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','not_found'); END IF;
  IF NOT private.staff_can_operate(o.account_id, o.branch_id) THEN
    RETURN jsonb_build_object('ok',false,'code','forbidden');
  END IF;
  IF o.status = p_target THEN RETURN jsonb_build_object('ok',true,'duplicate',true,'status',o.status); END IF;
  UPDATE public.vts_orders SET status = p_target WHERE id = p_order_id;
  PERFORM private.outbox_emit(o.account_id, o.branch_id, 'customer_status_changed',
    'ord:'||o.id||':'||p_target, jsonb_build_object('order_ref',o.order_ref,'to',p_target));
  RETURN jsonb_build_object('ok',true,'status',p_target);
END; $$;
REVOKE ALL ON FUNCTION private.staff_transition(UUID,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.staff_transition(UUID,TEXT) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.mark_order_pending(p_order_id UUID) RETURNS JSONB
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT private.staff_transition(p_order_id,'pending') $$;
CREATE OR REPLACE FUNCTION public.mark_order_preparing(p_order_id UUID) RETURNS JSONB
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT private.staff_transition(p_order_id,'preparing') $$;
CREATE OR REPLACE FUNCTION public.mark_order_ready(p_order_id UUID) RETURNS JSONB
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT private.staff_transition(p_order_id,'ready') $$;

CREATE OR REPLACE FUNCTION public.cancel_order(p_order_id UUID, p_reason TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE o RECORD;
BEGIN
  PERFORM set_config('app.vts_rpc','1',true);
  SELECT * INTO o FROM public.vts_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','not_found'); END IF;
  IF NOT private.staff_can_operate(o.account_id, o.branch_id) THEN RETURN jsonb_build_object('ok',false,'code','forbidden'); END IF;
  IF o.status = 'cancelled' THEN RETURN jsonb_build_object('ok',true,'duplicate',true); END IF;
  IF o.status NOT IN ('awaiting_payment','pending','preparing','ready') THEN
    RETURN jsonb_build_object('ok',false,'code','not_cancellable','status',o.status);
  END IF;
  IF COALESCE(p_reason,'') = '' THEN RETURN jsonb_build_object('ok',false,'code','reason_required'); END IF;
  UPDATE public.vts_orders SET status='cancelled', notes = COALESCE(notes,'')||' [cancelled: '||p_reason||']' WHERE id=p_order_id;
  PERFORM private.outbox_emit(o.account_id, o.branch_id, 'customer_status_changed', 'ord:'||o.id||':cancelled',
    jsonb_build_object('order_ref',o.order_ref,'to','cancelled','reason',p_reason));
  RETURN jsonb_build_object('ok',true,'status','cancelled');
END; $$;

CREATE OR REPLACE FUNCTION public.assign_delivery(p_order_id UUID, p_rider_id UUID) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE o RECORD; r RECORD; d RECORD; v_id UUID;
BEGIN
  PERFORM set_config('app.vts_rpc','1',true);
  SELECT * INTO o FROM public.vts_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','not_found'); END IF;
  IF NOT private.staff_can_operate(o.account_id, o.branch_id) THEN RETURN jsonb_build_object('ok',false,'code','forbidden'); END IF;
  SELECT * INTO r FROM public.riders WHERE id = p_rider_id FOR UPDATE;
  IF NOT FOUND OR NOT r.is_active THEN RETURN jsonb_build_object('ok',false,'code','rider_not_found'); END IF;
  IF r.account_id <> o.account_id OR r.branch_code IS DISTINCT FROM o.branch_id THEN
    RETURN jsonb_build_object('ok',false,'code','branch_mismatch');
  END IF;
  SELECT * INTO d FROM public.deliveries WHERE order_id = p_order_id AND status IN ('assigned','collected') LIMIT 1;
  IF FOUND THEN
    IF d.rider_id = p_rider_id THEN RETURN jsonb_build_object('ok',true,'duplicate',true,'delivery_id',d.id); END IF;
    RETURN jsonb_build_object('ok',false,'code','already_assigned','delivery_id',d.id);
  END IF;
  IF o.status NOT IN ('ready','delivery_failed') THEN
    RETURN jsonb_build_object('ok',false,'code','order_not_ready','status',o.status);
  END IF;
  INSERT INTO public.deliveries (account_id, order_id, rider_id, branch_code, amount_to_collect, assigned_by)
  VALUES (o.account_id, o.id, p_rider_id, o.branch_id, CASE WHEN COALESCE(o.payment_method,'COD') ILIKE '%cod%' THEN o.total ELSE 0 END, auth.uid())
  RETURNING id INTO v_id;
  UPDATE public.vts_orders SET status='dispatched' WHERE id = o.id;
  PERFORM private.outbox_emit(o.account_id, o.branch_id, 'delivery_assigned', 'dlv:'||v_id||':assigned',
    jsonb_build_object('order_ref',o.order_ref,'delivery_id',v_id,'rider_id',p_rider_id));
  RETURN jsonb_build_object('ok',true,'delivery_id',v_id);
END; $$;

CREATE OR REPLACE FUNCTION private.rider_delivery_action(p_delivery_id UUID, p_action TEXT, p_reason TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE d RECORD; o RECORD; v_rider UUID;
BEGIN
  PERFORM set_config('app.vts_rpc','1',true);
  v_rider := private.current_rider_id();
  IF v_rider IS NULL THEN RETURN jsonb_build_object('ok',false,'code','not_a_rider'); END IF;
  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','not_found'); END IF;
  IF d.rider_id <> v_rider THEN RETURN jsonb_build_object('ok',false,'code','not_assigned_to_you'); END IF;
  SELECT * INTO o FROM public.vts_orders WHERE id = d.order_id FOR UPDATE;
  IF p_action = 'collect' THEN
    IF d.status = 'collected' THEN RETURN jsonb_build_object('ok',true,'duplicate',true); END IF;
    IF d.status <> 'assigned' THEN RETURN jsonb_build_object('ok',false,'code','bad_state','status',d.status); END IF;
    UPDATE public.deliveries SET status='collected', collected_at=NOW() WHERE id=p_delivery_id;
    UPDATE public.vts_orders SET status='collected' WHERE id=o.id AND o.status='dispatched';
    PERFORM private.outbox_emit(d.account_id, d.branch_code, 'delivery_collected', 'dlv:'||d.id||':collected',
      jsonb_build_object('order_ref',o.order_ref,'delivery_id',d.id));
  ELSIF p_action = 'complete' THEN
    IF d.status = 'delivered' THEN RETURN jsonb_build_object('ok',true,'duplicate',true); END IF;
    IF d.status <> 'collected' THEN RETURN jsonb_build_object('ok',false,'code','bad_state','status',d.status); END IF;
    UPDATE public.deliveries SET status='delivered', delivered_at=NOW() WHERE id=p_delivery_id;
    UPDATE public.vts_orders SET status='delivered' WHERE id=o.id;
    PERFORM private.outbox_emit(d.account_id, d.branch_code, 'delivery_completed', 'dlv:'||d.id||':delivered',
      jsonb_build_object('order_ref',o.order_ref,'delivery_id',d.id));
  ELSIF p_action = 'fail' THEN
    IF d.status = 'failed' THEN RETURN jsonb_build_object('ok',true,'duplicate',true); END IF;
    IF d.status NOT IN ('assigned','collected') THEN RETURN jsonb_build_object('ok',false,'code','bad_state','status',d.status); END IF;
    IF COALESCE(p_reason,'') = '' THEN RETURN jsonb_build_object('ok',false,'code','reason_required'); END IF;
    UPDATE public.deliveries SET status='failed', failed_at=NOW(), failure_reason=p_reason WHERE id=p_delivery_id;
    UPDATE public.vts_orders SET status='delivery_failed' WHERE id=o.id;
    PERFORM private.outbox_emit(d.account_id, d.branch_code, 'delivery_failed', 'dlv:'||d.id||':failed',
      jsonb_build_object('order_ref',o.order_ref,'delivery_id',d.id,'reason',p_reason));
  ELSE
    RETURN jsonb_build_object('ok',false,'code','bad_action');
  END IF;
  RETURN jsonb_build_object('ok',true,'action',p_action);
END; $$;
REVOKE ALL ON FUNCTION private.rider_delivery_action(UUID,TEXT,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.rider_delivery_action(UUID,TEXT,TEXT) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.collect_delivery(p_delivery_id UUID) RETURNS JSONB
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT private.rider_delivery_action(p_delivery_id,'collect') $$;
CREATE OR REPLACE FUNCTION public.complete_delivery(p_delivery_id UUID) RETURNS JSONB
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT private.rider_delivery_action(p_delivery_id,'complete') $$;
CREATE OR REPLACE FUNCTION public.fail_delivery(p_delivery_id UUID, p_reason TEXT) RETURNS JSONB
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$ SELECT private.rider_delivery_action(p_delivery_id,'fail',p_reason) $$;

CREATE OR REPLACE FUNCTION public.reassign_delivery(p_delivery_id UUID, p_new_rider_id UUID) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE d RECORD; res JSONB;
BEGIN
  PERFORM set_config('app.vts_rpc','1',true);
  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','not_found'); END IF;
  IF NOT private.staff_can_operate(d.account_id, d.branch_code) THEN RETURN jsonb_build_object('ok',false,'code','forbidden'); END IF;
  IF d.status = 'reassigned' THEN RETURN jsonb_build_object('ok',true,'duplicate',true); END IF;
  IF d.status <> 'failed' THEN RETURN jsonb_build_object('ok',false,'code','bad_state','status',d.status); END IF;
  UPDATE public.deliveries SET status='reassigned' WHERE id = p_delivery_id;
  PERFORM private.outbox_emit(d.account_id, d.branch_code, 'delivery_reassigned', 'dlv:'||d.id||':reassigned',
    jsonb_build_object('delivery_id',d.id,'new_rider',p_new_rider_id));
  res := public.assign_delivery(d.order_id, p_new_rider_id);
  RETURN jsonb_build_object('ok', (res->>'ok')::boolean, 'code', COALESCE(res->>'code','reassigned'), 'new', res);
END; $$;

CREATE OR REPLACE FUNCTION public.admin_correct_order(p_order_id UUID, p_set JSONB, p_reason TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE o RECORD; k TEXT;
BEGIN
  IF COALESCE(p_reason,'') = '' THEN RETURN jsonb_build_object('ok',false,'code','reason_required'); END IF;
  SELECT * INTO o FROM public.vts_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','not_found'); END IF;
  IF NOT public.is_account_member(o.account_id, 'admin') THEN RETURN jsonb_build_object('ok',false,'code','forbidden'); END IF;
  FOR k IN SELECT jsonb_object_keys(p_set) LOOP
    IF k NOT IN ('status','notes','customer_name','address','area','payment_status') THEN
      RETURN jsonb_build_object('ok',false,'code','field_not_correctable','field',k);
    END IF;
  END LOOP;
  PERFORM set_config('app.vts_admin','1',true);
  UPDATE public.vts_orders SET
    status = COALESCE(p_set->>'status', status),
    notes = COALESCE(p_set->>'notes', notes),
    customer_name = COALESCE(p_set->>'customer_name', customer_name),
    address = COALESCE(p_set->>'address', address),
    area = COALESCE(p_set->>'area', area),
    payment_status = COALESCE(p_set->>'payment_status', payment_status)
  WHERE id = p_order_id;
  PERFORM private.outbox_emit(o.account_id, o.branch_id, 'admin_correction',
    'adm:'||o.id||':'||md5(p_set::text||p_reason),
    jsonb_build_object('order_ref',o.order_ref,'changes',p_set,'reason',p_reason,'by',auth.uid()));
  RETURN jsonb_build_object('ok',true);
END; $$;

DO $$
DECLARE f TEXT;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'mark_order_pending(uuid)','mark_order_preparing(uuid)','mark_order_ready(uuid)',
    'cancel_order(uuid,text)','assign_delivery(uuid,uuid)','collect_delivery(uuid)',
    'complete_delivery(uuid)','fail_delivery(uuid,text)','reassign_delivery(uuid,uuid)',
    'admin_correct_order(uuid,jsonb,text)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC', f);
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated, service_role', f);
  END LOOP;
END $$;

-- VERIFY: Arc C test battery. ROLLBACK: DROP ten public RPCs +
-- private.staff_transition/rider_delivery_action/staff_can_operate.

