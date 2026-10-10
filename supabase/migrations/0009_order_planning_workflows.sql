-- Orders/planning: all critical state changes are permission-checked, atomic, idempotent and audited.
CREATE TABLE IF NOT EXISTS public.allowed_transitions(entity text NOT NULL,from_state text NOT NULL,to_state text NOT NULL,PRIMARY KEY(entity,from_state,to_state));
ALTER TABLE public.allowed_transitions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.allowed_transitions FROM anon,authenticated;
INSERT INTO public.allowed_transitions(entity,from_state,to_state) VALUES
('order','DRAFT','CONFIRMED'),('order','DRAFT','CANCELLED'),('order','CONFIRMED','PLANNED'),('order','CONFIRMED','CANCELLED'),('order','PLANNED','IN_PRODUCTION'),('order','PLANNED','CANCELLED'),('order','IN_PRODUCTION','READY_FOR_DISPATCH'),('order','IN_PRODUCTION','PARTIALLY_DISPATCHED'),('order','READY_FOR_DISPATCH','PARTIALLY_DISPATCHED'),('order','READY_FOR_DISPATCH','DISPATCHED'),('order','PARTIALLY_DISPATCHED','DISPATCHED'),('order','DISPATCHED','CLOSED'),
('operation','PLANNED','READY'),('operation','READY','IN_PROGRESS'),('operation','IN_PROGRESS','PAUSED'),('operation','PAUSED','IN_PROGRESS'),('operation','IN_PROGRESS','COMPLETED'),('operation','PLANNED','CANCELLED'),('operation','READY','CANCELLED'),('operation','PAUSED','CANCELLED'),('operation','IN_PROGRESS','CANCELLED'),
('roll','IN_PRODUCTION','AWAITING_INSPECTION'),('roll','IN_PRODUCTION','REWORK_REQUIRED'),('roll','IN_PRODUCTION','REJECTED'),('roll','IN_PRODUCTION','QUARANTINED'),('roll','AWAITING_INSPECTION','ACCEPTED'),('roll','AWAITING_INSPECTION','REWORK_REQUIRED'),('roll','AWAITING_INSPECTION','REJECTED'),('roll','AWAITING_INSPECTION','QUARANTINED'),('roll','REWORK_REQUIRED','REWORK_IN_PROGRESS'),('roll','REWORK_IN_PROGRESS','REINSPECTION_REQUIRED'),('roll','REINSPECTION_REQUIRED','ACCEPTED'),('roll','REINSPECTION_REQUIRED','REWORK_REQUIRED'),('roll','REINSPECTION_REQUIRED','REJECTED'),('roll','REINSPECTION_REQUIRED','QUARANTINED'),('roll','ACCEPTED','RESERVED'),('roll','ACCEPTED','REWORK_REQUIRED'),('roll','ACCEPTED','QUARANTINED'),('roll','RESERVED','ACCEPTED'),('roll','RESERVED','DISPATCHED'),('roll','RESERVED','QUARANTINED'),('roll','QUARANTINED','REINSPECTION_REQUIRED'),('roll','DISPATCHED','REINSPECTION_REQUIRED'),
('shipment','DRAFT','ALLOCATED'),('shipment','DRAFT','CANCELLED'),('shipment','ALLOCATED','CONFIRMED'),('shipment','ALLOCATED','CANCELLED'),('shipment','CONFIRMED','REVERSED'),
('machine','IDLE','RUNNING'),('machine','IDLE','SETUP'),('machine','IDLE','PLANNED_MAINTENANCE'),('machine','IDLE','BREAKDOWN'),('machine','IDLE','OFFLINE'),('machine','RUNNING','IDLE'),('machine','RUNNING','BREAKDOWN'),('machine','RUNNING','SETUP'),('machine','SETUP','RUNNING'),('machine','SETUP','IDLE'),('machine','SETUP','BREAKDOWN'),('machine','PLANNED_MAINTENANCE','IDLE'),('machine','PLANNED_MAINTENANCE','BREAKDOWN'),('machine','BREAKDOWN','IDLE'),('machine','BREAKDOWN','PLANNED_MAINTENANCE'),('machine','OFFLINE','IDLE') ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.enforce_controlled_transition() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_entity text; v_from text; v_to text; v_flag text;
BEGIN
 v_entity:=TG_ARGV[0]; v_from:=to_jsonb(OLD)->>TG_ARGV[1]; v_to:=to_jsonb(NEW)->>TG_ARGV[1];
 IF v_from IS NOT DISTINCT FROM v_to THEN RETURN NEW; END IF;
 v_flag:=current_setting('app.allow_'||v_entity||'_state',true);
 IF v_flag IS DISTINCT FROM 'on' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: STATE_CHANGE_RPC_ONLY'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.allowed_transitions WHERE entity=v_entity AND from_state=v_from AND to_state=v_to) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: INVALID_STATE_TRANSITION'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS order_state_guard ON public.buyer_orders;
CREATE TRIGGER order_state_guard BEFORE UPDATE OF status ON public.buyer_orders FOR EACH ROW EXECUTE FUNCTION public.enforce_controlled_transition('order','status');
DROP TRIGGER IF EXISTS operation_state_guard ON public.production_operations;
CREATE TRIGGER operation_state_guard BEFORE UPDATE OF status ON public.production_operations FOR EACH ROW EXECUTE FUNCTION public.enforce_controlled_transition('operation','status');
DROP TRIGGER IF EXISTS roll_state_guard ON public.fabric_rolls;
CREATE TRIGGER roll_state_guard BEFORE UPDATE OF status ON public.fabric_rolls FOR EACH ROW EXECUTE FUNCTION public.enforce_controlled_transition('roll','status');
DROP TRIGGER IF EXISTS shipment_state_guard ON public.shipments;
CREATE TRIGGER shipment_state_guard BEFORE UPDATE OF status ON public.shipments FOR EACH ROW EXECUTE FUNCTION public.enforce_controlled_transition('shipment','status');
DROP TRIGGER IF EXISTS machine_state_guard ON public.machines;
CREATE TRIGGER machine_state_guard BEFORE UPDATE OF status ON public.machines FOR EACH ROW EXECUTE FUNCTION public.enforce_controlled_transition('machine','status');

CREATE OR REPLACE FUNCTION public.rpc_create_order(p_payload jsonb,p_idempotency_key uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_existing jsonb; v_buyer uuid; v_order uuid; v_no text; v_line jsonb; v_product uuid; v_result jsonb; v_lines jsonb:='[]'::jsonb; v_id uuid; v_count integer:=0;
BEGIN
 PERFORM private.assert_permission('orders.create');
 IF p_idempotency_key IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: IDEMPOTENCY_KEY_REQUIRED'; END IF;
 SELECT response INTO v_existing FROM public.idempotency_keys WHERE scope='create_order' AND key=p_idempotency_key; IF FOUND THEN RETURN v_existing; END IF;
 v_buyer:=(p_payload->>'buyer_id')::uuid;
 IF NOT EXISTS(SELECT 1 FROM public.buyers WHERE id=v_buyer AND is_active) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: BUYER_NOT_FOUND'; END IF;
 IF jsonb_typeof(p_payload->'lines')<>'array' OR jsonb_array_length(p_payload->'lines')=0 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ORDER_LINES_REQUIRED'; END IF;
 v_no:=COALESCE(NULLIF(p_payload->>'order_number',''),private.next_doc_no('ORD'));
 INSERT INTO public.buyer_orders(order_number,buyer_id,requested_date,promised_date,status,priority,currency,notes_internal,notes_buyer,over_delivery_pct,created_by)
 VALUES(v_no,v_buyer,COALESCE((p_payload->>'requested_date')::date,current_date),(p_payload->>'promised_date')::date,'DRAFT',COALESCE((p_payload->>'priority')::public.order_priority,'NORMAL'),COALESCE(NULLIF(p_payload->>'currency',''),'INR'),COALESCE(p_payload->>'notes_internal',''),COALESCE(p_payload->>'notes_buyer',''),COALESCE((SELECT value::text::numeric FROM public.system_settings WHERE key='over_delivery_pct'),0),auth.uid()) RETURNING id INTO v_order;
 FOR v_line IN SELECT value FROM jsonb_array_elements(p_payload->'lines') LOOP
  v_product:=(v_line->>'product_id')::uuid;
  IF NOT EXISTS(SELECT 1 FROM public.products WHERE id=v_product AND is_active) OR COALESCE((v_line->>'ordered_qty')::numeric,0)<=0 OR COALESCE(v_line->>'unit','')='' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ORDER_LINE_INVALID'; END IF;
  v_count:=v_count+1;
  INSERT INTO public.buyer_order_lines(order_id,line_no,product_id,colour,ordered_qty,unit,unit_rate,spec_overrides) VALUES(v_order,v_count,v_product,COALESCE(v_line->>'colour',''),(v_line->>'ordered_qty')::numeric,v_line->>'unit',COALESCE((v_line->>'unit_rate')::numeric,0),COALESCE(v_line->'spec_overrides','{}'::jsonb)) RETURNING id INTO v_id;
  v_lines:=v_lines||jsonb_build_array(jsonb_build_object('id',v_id,'line_no',v_count));
 END LOOP;
 v_result:=jsonb_build_object('order_id',v_order,'order_number',v_no,'status','DRAFT','lines',v_lines);
 INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('create_order',p_idempotency_key,auth.uid(),v_result);
 INSERT INTO public.audit_logs(actor_user_id,actor_role,action,entity_type,entity_id,after_json) VALUES(auth.uid(),'factory_manager','ORDER_CREATED','buyer_orders',v_order,jsonb_build_object('order_number',v_no,'line_count',v_count));
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_run_feasibility(p_order_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_order public.buyer_orders%ROWTYPE; v_result text:='READY'; v_details jsonb:='{}'::jsonb; v_materials jsonb:='[]'::jsonb; v_short boolean:=false; v_blocked boolean:=false; r record; v_available numeric; v_required numeric; v_shortage numeric; v_has_bom boolean; v_has_qc boolean; v_has_route boolean; v_id uuid;
BEGIN
 PERFORM private.assert_permission('orders.read');
 SELECT * INTO v_order FROM public.buyer_orders WHERE id=p_order_id AND NOT private.has_permission('buyer.portal');
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: NOT_FOUND'; END IF;
 FOR r IN SELECT l.id line_id,l.ordered_qty,l.product_id,p.product_code,p.description,b.yarn_item_id,y.item_code,y.name,y.unit,b.qty_per_output_unit,b.wastage_pct FROM public.buyer_order_lines l JOIN public.products p ON p.id=l.product_id LEFT JOIN public.product_bom b ON b.product_id=p.id LEFT JOIN public.yarn_items y ON y.id=b.yarn_item_id WHERE l.order_id=p_order_id LOOP
  IF r.yarn_item_id IS NULL THEN v_blocked:=true; v_materials:=v_materials||jsonb_build_array(jsonb_build_object('product',r.product_code,'status','BLOCKED','reason','Product BOM is missing')); CONTINUE; END IF;
  v_required:=round(r.ordered_qty*r.qty_per_output_unit*(1+r.wastage_pct/100.0),3);
  SELECT COALESCE(sum(available),0) INTO v_available FROM public.v_yarn_stock WHERE yarn_item_id=r.yarn_item_id;
  v_shortage:=greatest(0,v_required-v_available); v_short:=v_short OR v_shortage>0;
  v_materials:=v_materials||jsonb_build_array(jsonb_build_object('line_id',r.line_id,'item_code',r.item_code,'item_name',r.name,'required_qty',v_required,'available_qty',v_available,'shortage_qty',v_shortage,'unit',r.unit));
 END LOOP;
 SELECT EXISTS(SELECT 1 FROM public.buyer_order_lines l JOIN public.product_routes pr ON pr.product_id=l.product_id WHERE l.order_id=p_order_id AND pr.is_applicable) INTO v_has_route;
 SELECT EXISTS(SELECT 1 FROM public.buyer_order_lines l JOIN public.inspection_plans ip ON ip.product_id=l.product_id AND ip.is_active WHERE l.order_id=p_order_id) INTO v_has_qc;
 IF NOT v_has_route OR NOT v_has_qc THEN v_blocked:=true; END IF;
 IF v_blocked THEN v_result:='BLOCKED'; ELSIF v_short THEN v_result:='READY_WITH_RISKS'; END IF;
 v_details:=jsonb_build_object('materials',v_materials,'route_exists',v_has_route,'quality_plan_exists',v_has_qc,'estimated_completion_label','Estimated; not guaranteed','yield_basis_pct',100,'calculation','ordered_qty × BOM qty/unit × (1 + wastage_pct/100)');
 INSERT INTO public.feasibility_checks(order_id,result,details,created_by) VALUES(p_order_id,v_result,v_details,auth.uid()) RETURNING id INTO v_id;
 UPDATE public.buyer_orders SET feasibility_status=v_result WHERE id=p_order_id;
 INSERT INTO public.audit_logs(actor_user_id,actor_role,action,entity_type,entity_id,after_json) VALUES(auth.uid(),'factory_manager','FEASIBILITY_CHECKED','buyer_orders',p_order_id,jsonb_build_object('result',v_result,'feasibility_check_id',v_id));
 RETURN jsonb_build_object('feasibility_check_id',v_id,'result',v_result,'details',v_details);
END $$;

CREATE OR REPLACE FUNCTION public.rpc_confirm_order(p_order_id uuid,p_idempotency_key uuid,p_override_reason text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_existing jsonb; v_order public.buyer_orders%ROWTYPE; v_feas public.feasibility_checks%ROWTYPE; v_result jsonb;
BEGIN
 PERFORM private.assert_permission('orders.confirm');
 SELECT response INTO v_existing FROM public.idempotency_keys WHERE scope='confirm_order' AND key=p_idempotency_key; IF FOUND THEN RETURN v_existing; END IF;
 SELECT * INTO v_order FROM public.buyer_orders WHERE id=p_order_id FOR UPDATE; IF NOT FOUND OR v_order.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ORDER_NOT_DRAFT'; END IF;
 SELECT * INTO v_feas FROM public.feasibility_checks WHERE order_id=p_order_id ORDER BY created_at DESC LIMIT 1;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: FEASIBILITY_REQUIRED'; END IF;
 IF v_feas.result='BLOCKED' THEN
  PERFORM private.assert_permission('orders.override_feasibility');
  IF length(trim(COALESCE(p_override_reason,'')))<10 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: OVERRIDE_REASON_REQUIRED'; END IF;
 END IF;
 PERFORM set_config('app.allow_order_state','on',true);
 UPDATE public.buyer_orders SET status='CONFIRMED',confirmed_by=auth.uid(),confirmed_at=now() WHERE id=p_order_id;
 v_result:=jsonb_build_object('order_id',p_order_id,'status','CONFIRMED','feasibility',v_feas.result);
 INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('confirm_order',p_idempotency_key,auth.uid(),v_result);
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,reason,after_json) VALUES(auth.uid(),'ORDER_CONFIRMED','buyer_orders',p_order_id,p_override_reason,v_result);
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_create_plan(p_order_line_id uuid,p_planned_qty numeric,p_idempotency_key uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_existing jsonb; v_line public.buyer_order_lines%ROWTYPE; v_order public.buyer_orders%ROWTYPE; v_plan uuid; v_no text; r record; v_op uuid; v_prev uuid; v_count integer:=0; v_result jsonb;
BEGIN
 PERFORM private.assert_permission('plans.create');
 SELECT response INTO v_existing FROM public.idempotency_keys WHERE scope='create_plan' AND key=p_idempotency_key; IF FOUND THEN RETURN v_existing; END IF;
 SELECT * INTO v_line FROM public.buyer_order_lines WHERE id=p_order_line_id; IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ORDER_LINE_NOT_FOUND'; END IF;
 SELECT * INTO v_order FROM public.buyer_orders WHERE id=v_line.order_id FOR UPDATE; IF v_order.status NOT IN ('CONFIRMED','PLANNED') THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ORDER_NOT_CONFIRMED'; END IF;
 IF p_planned_qty<=0 OR p_planned_qty>v_line.ordered_qty*(1+v_order.over_delivery_pct/100.0) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: PLAN_QTY_INVALID'; END IF;
 v_no:=private.next_doc_no('PLAN');
 INSERT INTO public.production_plans(plan_no,order_line_id,planned_qty,expected_yield_pct,status,created_by) VALUES(v_no,p_order_line_id,p_planned_qty,100,'DRAFT',auth.uid()) RETURNING id INTO v_plan;
 FOR r IN SELECT pr.*,pd.code,pd.name,pd.id AS proc_id FROM public.product_routes pr JOIN public.process_definitions pd ON pd.id=pr.process_id WHERE pr.product_id=v_line.product_id ORDER BY pr.sequence LOOP
  v_count:=v_count+1;
  INSERT INTO public.production_operations(operation_no,plan_id,process_id,stage,sequence,status,is_not_applicable,planned_start,planned_end,target_qty,unit,previous_operation_id,waiting_reason,created_by)
  VALUES(private.next_doc_no('OP'),v_plan,r.proc_id,r.name,r.sequence,CASE WHEN r.is_applicable THEN 'PLANNED'::public.op_status ELSE 'COMPLETED'::public.op_status END,NOT r.is_applicable,now()+make_interval(hours=>r.sequence*2),now()+make_interval(hours=>r.sequence*2+4),p_planned_qty,v_line.unit,v_prev,CASE WHEN r.is_applicable THEN NULL ELSE 'Not applicable in product route' END,auth.uid()) RETURNING id INTO v_op;
  IF r.is_applicable THEN v_prev:=v_op; END IF;
 END LOOP;
 IF v_count=0 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: PLAN_ROUTE_INVALID'; END IF;
 v_result:=jsonb_build_object('plan_id',v_plan,'plan_no',v_no,'status','DRAFT','operations_created',v_count);
 INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('create_plan',p_idempotency_key,auth.uid(),v_result);
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,after_json) VALUES(auth.uid(),'PLAN_CREATED','production_plans',v_plan,v_result);
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_release_plan(p_plan_id uuid,p_idempotency_key uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_existing jsonb; v_plan public.production_plans%ROWTYPE; v_line public.buyer_order_lines%ROWTYPE; v_item record; v_req numeric; v_avail numeric; v_short jsonb:='[]'::jsonb; v_reserved jsonb:='[]'::jsonb; v_result jsonb; v_first uuid;
BEGIN
 PERFORM private.assert_permission('plans.release');
 SELECT response INTO v_existing FROM public.idempotency_keys WHERE scope='release_plan' AND key=p_idempotency_key; IF FOUND THEN RETURN v_existing; END IF;
 SELECT * INTO v_plan FROM public.production_plans WHERE id=p_plan_id FOR UPDATE; IF NOT FOUND OR v_plan.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: PLAN_NOT_DRAFT'; END IF;
 SELECT * INTO v_line FROM public.buyer_order_lines WHERE id=v_plan.order_line_id;
 FOR v_item IN SELECT b.yarn_item_id,b.qty_per_output_unit,b.wastage_pct,y.unit,y.item_code FROM public.product_bom b JOIN public.yarn_items y ON y.id=b.yarn_item_id WHERE b.product_id=v_line.product_id LOOP
  v_req:=round(v_plan.planned_qty*v_item.qty_per_output_unit*(1+v_item.wastage_pct/100.0),3);
  SELECT COALESCE(sum(available),0) INTO v_avail FROM public.v_yarn_stock WHERE yarn_item_id=v_item.yarn_item_id;
  INSERT INTO public.plan_material_requirements(plan_id,yarn_item_id,required_qty,available_snapshot,shortage_qty) VALUES(p_plan_id,v_item.yarn_item_id,v_req,v_avail,greatest(0,v_req-v_avail)) ON CONFLICT(plan_id,yarn_item_id) DO UPDATE SET required_qty=EXCLUDED.required_qty,available_snapshot=EXCLUDED.available_snapshot,shortage_qty=EXCLUDED.shortage_qty;
  IF v_avail<v_req THEN v_short:=v_short||jsonb_build_array(jsonb_build_object('item_code',v_item.item_code,'required',v_req,'available',v_avail,'shortage',v_req-v_avail,'unit',v_item.unit)); END IF;
 END LOOP;
 IF jsonb_array_length(v_short)>0 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: PLAN_MATERIAL_SHORTAGE',DETAIL=v_short::text; END IF;
 FOR v_item IN SELECT b.yarn_item_id,b.qty_per_output_unit,b.wastage_pct,y.unit FROM public.product_bom b JOIN public.yarn_items y ON y.id=b.yarn_item_id WHERE b.product_id=v_line.product_id LOOP
  v_req:=round(v_plan.planned_qty*v_item.qty_per_output_unit*(1+v_item.wastage_pct/100.0),3);
  v_reserved:=v_reserved||jsonb_build_array(public.rpc_reserve_material(v_item.yarn_item_id,v_req,v_item.unit,p_plan_id,v_line.id,NULL));
 END LOOP;
 PERFORM set_config('app.allow_order_state','on',true);
 UPDATE public.buyer_orders SET status='PLANNED' WHERE id=(SELECT order_id FROM public.buyer_order_lines WHERE id=v_line.id) AND status='CONFIRMED';
 UPDATE public.production_plans SET status='RELEASED',released_by=auth.uid(),released_at=now(),estimated_completion=now()+interval '7 days',completion_factors=jsonb_build_object('material_status','reserved','route_operations',(SELECT count(*) FROM public.production_operations WHERE plan_id=p_plan_id AND NOT is_not_applicable),'estimate_label','Estimated; not guaranteed') WHERE id=p_plan_id;
 SELECT id INTO v_first FROM public.production_operations WHERE plan_id=p_plan_id AND NOT is_not_applicable ORDER BY sequence LIMIT 1;
 IF v_first IS NOT NULL THEN UPDATE public.production_operations SET status='READY' WHERE id=v_first; END IF;
 v_result:=jsonb_build_object('plan_id',p_plan_id,'status','RELEASED','reservations',v_reserved);
 INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('release_plan',p_idempotency_key,auth.uid(),v_result);
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,after_json) VALUES(auth.uid(),'PLAN_RELEASED','production_plans',p_plan_id,v_result);
 RETURN v_result;
END $$;

GRANT SELECT ON public.allowed_transitions TO authenticated;
REVOKE EXECUTE ON FUNCTION public.enforce_controlled_transition() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_create_order(jsonb,uuid),public.rpc_run_feasibility(uuid),public.rpc_confirm_order(uuid,uuid,text),public.rpc_create_plan(uuid,numeric,uuid),public.rpc_release_plan(uuid,uuid) TO authenticated;
