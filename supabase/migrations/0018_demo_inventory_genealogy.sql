CREATE OR REPLACE FUNCTION public.mark_reservation_demo() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.production_plans WHERE id=NEW.plan_id AND is_demo) OR EXISTS(SELECT 1 FROM public.buyer_order_lines l JOIN public.buyer_orders o ON o.id=l.order_id WHERE l.id=NEW.order_line_id AND o.is_demo);
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS material_reservations_demo_marker ON public.material_reservations;
CREATE TRIGGER material_reservations_demo_marker BEFORE INSERT OR UPDATE ON public.material_reservations FOR EACH ROW EXECUTE FUNCTION public.mark_reservation_demo();

CREATE OR REPLACE FUNCTION public.mark_inventory_movement_demo() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF NEW.item_kind='YARN_BATCH' AND NEW.yarn_batch_id IS NOT NULL THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.yarn_batches WHERE id=NEW.yarn_batch_id AND is_demo); END IF;
 IF NEW.item_kind='FABRIC_ROLL' AND NEW.roll_id IS NOT NULL THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.fabric_rolls WHERE id=NEW.roll_id AND is_demo); END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS inventory_movements_demo_marker ON public.inventory_movements;
CREATE TRIGGER inventory_movements_demo_marker BEFORE INSERT ON public.inventory_movements FOR EACH ROW EXECUTE FUNCTION public.mark_inventory_movement_demo();

CREATE OR REPLACE FUNCTION public.rpc_record_output(p_operation_id uuid,p_shift_instance_id uuid,p_good_qty numeric,p_waste_qty numeric,p_reject_qty numeric,p_unit text,p_idempotency_key uuid,p_waste_reason text DEFAULT NULL,p_reject_reason text DEFAULT NULL,p_notes text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_existing jsonb; v_op public.production_operations%ROWTYPE; v_inst public.shift_instances%ROWTYPE; v_plan public.production_plans%ROWTYPE; v_line public.buyer_order_lines%ROWTYPE; v_output uuid; v_product public.products%ROWTYPE; v_wip uuid; v_remaining numeric; v_roll_qty numeric; v_roll uuid; v_roll_code text; v_result jsonb; v_rolls jsonb:='[]'::jsonb; v_total numeric; v_creates_rolls boolean; r record;
BEGIN
 PERFORM private.assert_permission('production.record_output');
 IF p_idempotency_key IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: IDEMPOTENCY_KEY_REQUIRED'; END IF;
 SELECT response INTO v_existing FROM public.idempotency_keys WHERE scope='record_output' AND key=p_idempotency_key; IF FOUND THEN RETURN v_existing; END IF;
 IF COALESCE(p_good_qty,0)<0 OR COALESCE(p_waste_qty,0)<0 OR COALESCE(p_reject_qty,0)<0 OR COALESCE(p_good_qty,0)+COALESCE(p_waste_qty,0)+COALESCE(p_reject_qty,0)<=0 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: OUTPUT_QTY_INVALID'; END IF;
 SELECT * INTO v_op FROM public.production_operations WHERE id=p_operation_id FOR UPDATE; IF NOT FOUND OR v_op.status NOT IN ('READY','IN_PROGRESS') OR v_op.is_not_applicable THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: OPERATION_NOT_READY'; END IF;
 IF private.has_permission('production.operate') AND NOT private.has_permission('production.assign') AND NOT private.assigned_to_operation(p_operation_id) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: OPERATION_NOT_ASSIGNED'; END IF;
 IF p_unit<>v_op.unit THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: UNIT_REQUIRED'; END IF;
 SELECT * INTO v_inst FROM public.shift_instances WHERE id=p_shift_instance_id FOR UPDATE; IF NOT FOUND OR v_inst.status<>'OPEN' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: SHIFT_CLOSED'; END IF;
 SELECT * INTO v_plan FROM public.production_plans WHERE id=v_op.plan_id; SELECT * INTO v_line FROM public.buyer_order_lines WHERE id=v_plan.order_line_id; SELECT * INTO v_product FROM public.products WHERE id=v_line.product_id;
 SELECT creates_rolls INTO v_creates_rolls FROM public.process_definitions WHERE id=v_op.process_id;
 INSERT INTO public.production_outputs(operation_id,shift_instance_id,work_date,good_qty,waste_qty,reject_qty,unit,waste_reason,reject_reason,notes,recorded_by,idempotency_key,is_demo) VALUES(p_operation_id,p_shift_instance_id,v_inst.work_date,p_good_qty,p_waste_qty,p_reject_qty,p_unit,p_waste_reason,p_reject_reason,COALESCE(p_notes,''),auth.uid(),p_idempotency_key,v_plan.is_demo) RETURNING id INTO v_output;
 IF v_creates_rolls AND p_good_qty>0 THEN
  SELECT l.id INTO v_wip FROM public.stock_locations l JOIN public.warehouses w ON w.id=l.warehouse_id WHERE w.type='WIP' AND l.is_active ORDER BY l.code LIMIT 1;
  IF v_wip IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: STOCK_LOCATIONS_NOT_CONFIGURED'; END IF;
  v_remaining:=p_good_qty;
  WHILE v_remaining>0 LOOP
   v_roll_qty:=least(v_remaining,v_product.standard_roll_length); v_roll_code:=private.next_doc_no('ROLL');
   INSERT INTO public.fabric_rolls(roll_code,qr_token,order_line_id,plan_id,created_by_operation_id,output_id,qty,unit,status,current_stage,location_id,created_by,is_demo) VALUES(v_roll_code,gen_random_uuid()::text,v_line.id,v_plan.id,p_operation_id,v_output,v_roll_qty,v_op.unit,'AWAITING_INSPECTION',v_op.stage,v_wip,auth.uid(),v_plan.is_demo) RETURNING id INTO v_roll;
   INSERT INTO public.roll_status_history(roll_id,from_status,to_status,reason,actor,is_demo) VALUES(v_roll,NULL,'AWAITING_INSPECTION','Production output requires inspection',auth.uid(),v_plan.is_demo);
   INSERT INTO public.inventory_movements(movement_no,item_kind,roll_id,movement_type,qty,unit,to_location_id,source_type,source_id,created_by,is_demo) VALUES(private.next_doc_no('MOV'),'FABRIC_ROLL',v_roll,'PRODUCTION_OUTPUT',v_roll_qty,v_op.unit,v_wip,'production_output',v_output,auth.uid(),v_plan.is_demo);
   SELECT COALESCE(sum(qty),0) INTO v_total FROM public.material_reservations WHERE plan_id=v_plan.id AND status IN ('ACTIVE','AT_RISK','CONSUMED');
   IF v_total>0 THEN FOR r IN SELECT yarn_batch_id,qty remaining FROM public.material_reservations WHERE plan_id=v_plan.id AND status IN ('ACTIVE','AT_RISK','CONSUMED') LOOP INSERT INTO public.roll_material_sources(roll_id,yarn_batch_id,qty_fraction) VALUES(v_roll,r.yarn_batch_id,round(r.remaining/v_total,6)); END LOOP; END IF;
   v_rolls:=v_rolls||jsonb_build_array(jsonb_build_object('roll_id',v_roll,'roll_code',v_roll_code,'qr_token',(SELECT qr_token FROM public.fabric_rolls WHERE id=v_roll),'qty',v_roll_qty,'unit',v_op.unit));
   v_remaining:=v_remaining-v_roll_qty;
  END LOOP;
 END IF;
 IF v_op.status='READY' THEN PERFORM set_config('app.allow_operation_state','on',true); UPDATE public.production_operations SET status='IN_PROGRESS',actual_start=COALESCE(actual_start,now()) WHERE id=p_operation_id; INSERT INTO public.operation_events(operation_id,event_type,created_by) VALUES(p_operation_id,'START',auth.uid()); END IF;
 v_result:=jsonb_build_object('output_id',v_output,'good_qty',p_good_qty,'waste_qty',p_waste_qty,'reject_qty',p_reject_qty,'rolls',v_rolls,'status','RECORDED');
 INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('record_output',p_idempotency_key,auth.uid(),v_result);
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,after_json) VALUES(auth.uid(),'OUTPUT_RECORDED','production_outputs',v_output,v_result);
 RETURN v_result;
END $$;
REVOKE EXECUTE ON FUNCTION public.mark_reservation_demo(),public.mark_inventory_movement_demo() FROM PUBLIC,anon,authenticated;
