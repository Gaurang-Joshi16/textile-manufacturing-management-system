-- Production + quality RPCs. Direct status updates are blocked by state guards in 0009.
CREATE OR REPLACE FUNCTION public.rpc_assign_operation(p_operation_id uuid,p_machine_id uuid,p_shift_id uuid,p_supervisor_id uuid,p_employee_ids uuid[]) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_op public.production_operations%ROWTYPE; v_machine public.machines%ROWTYPE; v_emp uuid; v_result jsonb; v_skill_required boolean;
BEGIN
 PERFORM private.assert_permission('production.assign');
 SELECT * INTO v_op FROM public.production_operations WHERE id=p_operation_id FOR UPDATE;
 IF NOT FOUND OR v_op.status NOT IN ('PLANNED','READY') THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: OPERATION_NOT_ASSIGNABLE'; END IF;
 SELECT * INTO v_machine FROM public.machines WHERE id=p_machine_id AND is_active FOR UPDATE;
 IF NOT FOUND OR v_machine.status NOT IN ('IDLE','SETUP') OR v_machine.process_id<>v_op.process_id THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: MACHINE_UNAVAILABLE'; END IF;
 IF p_shift_id IS NULL OR p_supervisor_id IS NULL OR COALESCE(array_length(p_employee_ids,1),0)=0 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ASSIGNMENT_INCOMPLETE'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.employees WHERE id=p_supervisor_id AND employment_status='ACTIVE') THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: SUPERVISOR_UNAVAILABLE'; END IF;
 SELECT COALESCE(value::text::boolean,false) INTO v_skill_required FROM public.system_settings WHERE key='skills_enforced';
 FOREACH v_emp IN ARRAY p_employee_ids LOOP
  IF NOT EXISTS(SELECT 1 FROM public.employees e WHERE e.id=v_emp AND e.employment_status='ACTIVE') THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: EMPLOYEE_UNAVAILABLE'; END IF;
  IF v_skill_required AND EXISTS(SELECT 1 FROM public.process_skills ps WHERE ps.process_id=v_op.process_id AND ps.required) AND NOT EXISTS(SELECT 1 FROM public.process_skills ps JOIN public.employee_skills es ON es.skill_id=ps.skill_id WHERE ps.process_id=v_op.process_id AND es.employee_id=v_emp AND (es.certified_until IS NULL OR es.certified_until>=current_date)) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: SKILL_REQUIRED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.shift_roster WHERE employee_id=v_emp AND shift_id=p_shift_id AND work_date=COALESCE(v_op.planned_start::date,current_date)) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: EMPLOYEE_NOT_ROSTERED'; END IF;
 END LOOP;
 UPDATE public.production_operations SET machine_id=p_machine_id,shift_id=p_shift_id,supervisor_id=p_supervisor_id,status=CASE WHEN status='PLANNED' THEN 'READY'::public.op_status ELSE status END WHERE id=p_operation_id;
 DELETE FROM public.operation_assignments WHERE operation_id=p_operation_id;
 FOREACH v_emp IN ARRAY p_employee_ids LOOP INSERT INTO public.operation_assignments(operation_id,employee_id,role_on_operation) VALUES(p_operation_id,v_emp,'OPERATOR'); END LOOP;
 INSERT INTO public.operation_events(operation_id,event_type,reason,created_by) VALUES(p_operation_id,'ASSIGN','Supervisor assignment',auth.uid());
 v_result:=jsonb_build_object('operation_id',p_operation_id,'machine_id',p_machine_id,'employee_count',array_length(p_employee_ids,1),'status','READY','skills_enforced',COALESCE(v_skill_required,false));
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,after_json) VALUES(auth.uid(),'OPERATION_ASSIGNED','production_operations',p_operation_id,v_result);
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_set_operation_state(p_operation_id uuid,p_action text,p_reason text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_op public.production_operations%ROWTYPE; v_next public.op_status; v_order uuid;
BEGIN
 SELECT * INTO v_op FROM public.production_operations WHERE id=p_operation_id FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: OPERATION_NOT_FOUND'; END IF;
 IF p_action='START' THEN
  IF NOT private.has_permission('production.operate') AND NOT private.has_permission('production.assign') THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: PERMISSION_DENIED'; END IF;
  IF private.has_permission('production.operate') AND NOT private.has_permission('production.assign') AND NOT private.assigned_to_operation(p_operation_id) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: OPERATION_NOT_ASSIGNED'; END IF;
  IF v_op.status<>'READY' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: OPERATION_NOT_READY'; END IF;
  IF v_op.previous_operation_id IS NOT NULL AND EXISTS(SELECT 1 FROM public.production_operations WHERE id=v_op.previous_operation_id AND status<>'COMPLETED') THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: INSUFFICIENT_UPSTREAM_OUTPUT'; END IF;
  v_next:='IN_PROGRESS';
 ELSIF p_action='PAUSE' THEN
  IF NOT private.has_permission('production.operate') OR (NOT private.has_permission('production.assign') AND NOT private.assigned_to_operation(p_operation_id)) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: PERMISSION_DENIED'; END IF;
  IF length(trim(COALESCE(p_reason,'')))<3 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: REASON_REQUIRED'; END IF; v_next:='PAUSED';
 ELSIF p_action='RESUME' THEN
  IF NOT private.has_permission('production.operate') AND NOT private.has_permission('production.assign') THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: PERMISSION_DENIED'; END IF;
  IF length(trim(COALESCE(p_reason,'')))<3 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: REASON_REQUIRED'; END IF; v_next:='IN_PROGRESS';
 ELSIF p_action='COMPLETE' THEN
  PERFORM private.assert_permission('production.assign');
  IF v_op.status<>'IN_PROGRESS' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: OPERATION_NOT_IN_PROGRESS'; END IF; v_next:='COMPLETED';
 ELSE RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: INVALID_OPERATION_ACTION'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.allowed_transitions WHERE entity='operation' AND from_state=v_op.status::text AND to_state=v_next::text) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: INVALID_STATE_TRANSITION'; END IF;
 PERFORM set_config('app.allow_operation_state','on',true);
 UPDATE public.production_operations SET status=v_next,actual_start=CASE WHEN p_action='START' THEN COALESCE(actual_start,now()) ELSE actual_start END,actual_end=CASE WHEN p_action='COMPLETE' THEN now() ELSE actual_end END,pause_reason=CASE WHEN p_action='PAUSE' THEN p_reason WHEN p_action='RESUME' THEN NULL ELSE pause_reason END WHERE id=p_operation_id;
 INSERT INTO public.operation_events(operation_id,event_type,reason,created_by) VALUES(p_operation_id,p_action,p_reason,auth.uid());
 SELECT l.order_id INTO v_order FROM public.production_plans p JOIN public.buyer_order_lines l ON l.id=p.order_line_id WHERE p.id=v_op.plan_id;
 IF p_action='START' THEN PERFORM set_config('app.allow_order_state','on',true); UPDATE public.buyer_orders SET status='IN_PRODUCTION' WHERE id=v_order AND status='PLANNED'; END IF;
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,reason,after_json) VALUES(auth.uid(),'OPERATION_'||p_action,'production_operations',p_operation_id,p_reason,jsonb_build_object('status',v_next));
 RETURN jsonb_build_object('operation_id',p_operation_id,'status',v_next);
END $$;

CREATE OR REPLACE FUNCTION public.rpc_record_output(p_operation_id uuid,p_shift_instance_id uuid,p_good_qty numeric,p_waste_qty numeric,p_reject_qty numeric,p_unit text,p_idempotency_key uuid,p_waste_reason text DEFAULT NULL,p_reject_reason text DEFAULT NULL,p_notes text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_existing jsonb; v_op public.production_operations%ROWTYPE; v_inst public.shift_instances%ROWTYPE; v_plan public.production_plans%ROWTYPE; v_line public.buyer_order_lines%ROWTYPE; v_output uuid; v_product public.products%ROWTYPE; v_wip uuid; v_remaining numeric; v_roll_qty numeric; v_roll uuid; v_roll_code text; v_result jsonb; v_rolls jsonb:='[]'::jsonb; v_total numeric; r record;
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
 INSERT INTO public.production_outputs(operation_id,shift_instance_id,work_date,good_qty,waste_qty,reject_qty,unit,waste_reason,reject_reason,notes,recorded_by,idempotency_key,is_demo) VALUES(p_operation_id,p_shift_instance_id,v_inst.work_date,p_good_qty,p_waste_qty,p_reject_qty,p_unit,p_waste_reason,p_reject_reason,COALESCE(p_notes,''),auth.uid(),p_idempotency_key,v_plan.is_demo) RETURNING id INTO v_output;
 SELECT id INTO v_wip FROM public.stock_locations l JOIN public.warehouses w ON w.id=l.warehouse_id WHERE w.type='WIP' AND l.is_active ORDER BY l.code LIMIT 1;
 IF p_good_qty>0 AND v_wip IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: STOCK_LOCATIONS_NOT_CONFIGURED'; END IF;
 IF p_good_qty>0 THEN
  v_remaining:=p_good_qty;
  WHILE v_remaining>0 LOOP
   v_roll_qty:=least(v_remaining,v_product.standard_roll_length);
   v_roll_code:=private.next_doc_no('ROLL');
   INSERT INTO public.fabric_rolls(roll_code,qr_token,order_line_id,plan_id,created_by_operation_id,output_id,qty,unit,status,current_stage,location_id,created_by,is_demo) VALUES(v_roll_code,gen_random_uuid()::text,v_line.id,v_plan.id,p_operation_id,v_output,v_roll_qty,v_op.unit,'AWAITING_INSPECTION',v_op.stage,v_wip,auth.uid(),v_plan.is_demo) RETURNING id INTO v_roll;
   INSERT INTO public.roll_status_history(roll_id,from_status,to_status,reason,actor,is_demo) VALUES(v_roll,NULL,'AWAITING_INSPECTION','Production output requires inspection',auth.uid(),v_plan.is_demo);
   INSERT INTO public.inventory_movements(movement_no,item_kind,roll_id,movement_type,qty,unit,to_location_id,source_type,source_id,created_by,is_demo) VALUES(private.next_doc_no('MOV'),'FABRIC_ROLL',v_roll,'PRODUCTION_OUTPUT',v_roll_qty,v_op.unit,v_wip,'production_output',v_output,auth.uid(),v_plan.is_demo);
   SELECT COALESCE(sum(qty-consumed_qty),0) INTO v_total FROM public.material_reservations WHERE plan_id=v_plan.id AND status IN ('ACTIVE','AT_RISK','CONSUMED');
   IF v_total>0 THEN FOR r IN SELECT yarn_batch_id,qty-consumed_qty remaining FROM public.material_reservations WHERE plan_id=v_plan.id AND status IN ('ACTIVE','AT_RISK','CONSUMED') LOOP INSERT INTO public.roll_material_sources(roll_id,yarn_batch_id,qty_fraction) VALUES(v_roll,r.yarn_batch_id,round(r.remaining/v_total,6)); END LOOP; END IF;
   v_rolls:=v_rolls||jsonb_build_array(jsonb_build_object('roll_id',v_roll,'roll_code',v_roll_code,'qr_token', (SELECT qr_token FROM public.fabric_rolls WHERE id=v_roll),'qty',v_roll_qty,'unit',v_op.unit));
   v_remaining:=v_remaining-v_roll_qty;
  END LOOP;
 END IF;
 IF v_op.status='READY' THEN PERFORM set_config('app.allow_operation_state','on',true); UPDATE public.production_operations SET status='IN_PROGRESS',actual_start=COALESCE(actual_start,now()) WHERE id=p_operation_id; INSERT INTO public.operation_events(operation_id,event_type,created_by) VALUES(p_operation_id,'START',auth.uid()); END IF;
 INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('record_output',p_idempotency_key,auth.uid(),jsonb_build_object('output_id',v_output));
 v_result:=jsonb_build_object('output_id',v_output,'good_qty',p_good_qty,'waste_qty',p_waste_qty,'reject_qty',p_reject_qty,'rolls',v_rolls,'status','RECORDED');
 UPDATE public.idempotency_keys SET response=v_result WHERE scope='record_output' AND key=p_idempotency_key;
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,after_json) VALUES(auth.uid(),'OUTPUT_RECORDED','production_outputs',v_output,v_result);
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_inspect_roll(p_roll_id uuid,p_result public.inspection_result,p_notes text,p_measurements jsonb,p_defects jsonb,p_idempotency_key uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_existing jsonb; v_roll public.fabric_rolls%ROWTYPE; v_insp uuid; v_no text; v_plan uuid; v_stage text; v_round integer; v_prior uuid; v_next public.roll_status; v_check jsonb; v_def jsonb; v_cat uuid; v_fail boolean:=false; v_result jsonb; v_fg uuid; v_oldloc uuid; v_rework uuid;
BEGIN
 PERFORM private.assert_permission('quality.inspect');
 IF p_idempotency_key IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: IDEMPOTENCY_KEY_REQUIRED'; END IF;
 SELECT response INTO v_existing FROM public.idempotency_keys WHERE scope='inspect_roll' AND key=p_idempotency_key; IF FOUND THEN RETURN v_existing; END IF;
 SELECT * INTO v_roll FROM public.fabric_rolls WHERE id=p_roll_id FOR UPDATE;
 IF NOT FOUND OR v_roll.status NOT IN ('AWAITING_INSPECTION','REINSPECTION_REQUIRED') THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ROLL_NOT_INSPECTABLE'; END IF;
 IF jsonb_typeof(COALESCE(p_measurements,'[]'::jsonb))<>'array' OR jsonb_typeof(COALESCE(p_defects,'[]'::jsonb))<>'array' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: INSPECTION_PAYLOAD_INVALID'; END IF;
 SELECT ip.id INTO v_plan FROM public.fabric_rolls r JOIN public.buyer_order_lines l ON l.id=r.order_line_id JOIN public.inspection_plans ip ON ip.product_id=l.product_id AND ip.is_active WHERE r.id=p_roll_id ORDER BY ip.version DESC LIMIT 1;
 IF v_plan IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: INSPECTION_PLAN_MISSING'; END IF;
 SELECT id INTO v_prior FROM public.quality_inspections WHERE roll_id=p_roll_id ORDER BY inspected_at DESC LIMIT 1;
 SELECT count(*)+1 INTO v_round FROM public.quality_inspections WHERE roll_id=p_roll_id;
 v_stage:=CASE WHEN v_roll.status='REINSPECTION_REQUIRED' THEN 'REINSPECTION' ELSE 'FINAL' END;
 v_no:=private.next_doc_no('QC');
 INSERT INTO public.quality_inspections(inspection_no,roll_id,operation_id,plan_id,inspector_id,inspection_stage,round,is_reinspection,prior_inspection_id,sample_size,result,notes,is_demo) VALUES(v_no,p_roll_id,v_roll.created_by_operation_id,v_plan,auth.uid(),v_stage,v_round,v_stage='REINSPECTION',v_prior,v_roll.qty,p_result,COALESCE(p_notes,''),v_roll.is_demo) RETURNING id INTO v_insp;
 FOR v_check IN SELECT value FROM jsonb_array_elements(COALESCE(p_measurements,'[]'::jsonb)) LOOP
  IF COALESCE((v_check->>'pass')::boolean,false)=false THEN v_fail:=true; END IF;
  INSERT INTO public.quality_inspection_measurements(inspection_id,check_id,measured_value,expected_min,expected_max,unit,pass,is_demo) VALUES(v_insp,NULLIF(v_check->>'check_id','')::uuid,NULLIF(v_check->>'measured_value','')::numeric,NULLIF(v_check->>'expected_min','')::numeric,NULLIF(v_check->>'expected_max','')::numeric,COALESCE(v_check->>'unit',''),COALESCE((v_check->>'pass')::boolean,false),v_roll.is_demo);
 END LOOP;
 IF p_result='PASS' AND v_fail THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: MEASUREMENT_FAILED'; END IF;
 FOR v_def IN SELECT value FROM jsonb_array_elements(COALESCE(p_defects,'[]'::jsonb)) LOOP
  SELECT id INTO v_cat FROM public.defect_categories WHERE code=v_def->>'category_code' AND is_active;
  IF v_cat IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: DEFECT_CATEGORY_NOT_FOUND'; END IF;
  INSERT INTO public.quality_defects(inspection_id,defect_category_id,severity,quantity_or_extent,unit,pos_x,pos_y,notes,is_demo) VALUES(v_insp,v_cat,COALESCE(v_def->>'severity','LOW')::public.severity,NULLIF(v_def->>'quantity_or_extent','')::numeric,COALESCE(v_def->>'unit',v_roll.unit),NULLIF(v_def->>'pos_x','')::numeric,NULLIF(v_def->>'pos_y','')::numeric,COALESCE(v_def->>'notes',''),v_roll.is_demo);
 END LOOP;
 v_next:=CASE p_result WHEN 'PASS' THEN 'ACCEPTED'::public.roll_status WHEN 'REWORK' THEN 'REWORK_REQUIRED'::public.roll_status WHEN 'REJECT' THEN 'REJECTED'::public.roll_status ELSE 'QUARANTINED'::public.roll_status END;
 PERFORM set_config('app.allow_roll_state','on',true);
 UPDATE public.fabric_rolls SET status=v_next,first_pass_result=CASE WHEN v_round=1 THEN p_result='PASS' ELSE first_pass_result END,hold_reason=CASE WHEN p_result='QUARANTINE' THEN COALESCE(NULLIF(p_notes,''),'Quality hold') ELSE NULL END,version=version+1 WHERE id=p_roll_id;
 INSERT INTO public.roll_status_history(roll_id,from_status,to_status,reason,actor,is_demo) VALUES(p_roll_id,v_roll.status,v_next,COALESCE(p_notes,p_result::text),auth.uid(),v_roll.is_demo);
 IF p_result='PASS' THEN
  SELECT id INTO v_fg FROM public.stock_locations l JOIN public.warehouses w ON w.id=l.warehouse_id WHERE w.type='FINISHED' AND l.is_active ORDER BY l.code LIMIT 1;
  IF v_fg IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: STOCK_LOCATIONS_NOT_CONFIGURED'; END IF;
  v_oldloc:=v_roll.location_id;
  INSERT INTO public.inventory_movements(movement_no,item_kind,roll_id,movement_type,qty,unit,from_location_id,to_location_id,source_type,source_id,created_by,is_demo) VALUES(private.next_doc_no('MOV'),'FABRIC_ROLL',p_roll_id,'TRANSFER',v_roll.qty,v_roll.unit,v_oldloc,v_fg,'quality_inspection',v_insp,auth.uid(),v_roll.is_demo);
  UPDATE public.fabric_rolls SET location_id=v_fg WHERE id=p_roll_id;
 ELSIF p_result='REWORK' THEN
  INSERT INTO public.rework_orders(rework_no,roll_id,source_inspection_id,status,notes,is_demo) VALUES(private.next_doc_no('RWK'),p_roll_id,v_insp,'OPEN',COALESCE(p_notes,'Rework required'),v_roll.is_demo) RETURNING id INTO v_rework;
  INSERT INTO public.tasks(task_no,title,description,assignee_role,entity_type,entity_id,created_by,is_demo) VALUES(private.next_doc_no('TSK'),'Rework roll '|| (SELECT roll_code FROM public.fabric_rolls WHERE id=p_roll_id),'Complete rework, then submit a linked reinspection.','quality_inspector','rework_orders',v_rework,auth.uid(),v_roll.is_demo);
 END IF;
 v_result:=jsonb_build_object('inspection_id',v_insp,'inspection_no',v_no,'roll_id',p_roll_id,'result',p_result,'roll_status',v_next,'rework_id',v_rework);
 INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('inspect_roll',p_idempotency_key,auth.uid(),v_result);
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,after_json) VALUES(auth.uid(),'ROLL_INSPECTED','quality_inspections',v_insp,v_result);
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_complete_rework(p_rework_id uuid,p_notes text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_rw public.rework_orders%ROWTYPE; v_roll public.fabric_rolls%ROWTYPE;
BEGIN
 PERFORM private.assert_permission('quality.release');
 SELECT * INTO v_rw FROM public.rework_orders WHERE id=p_rework_id FOR UPDATE; IF NOT FOUND OR v_rw.status NOT IN ('OPEN','IN_PROGRESS') THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: REWORK_NOT_OPEN'; END IF;
 SELECT * INTO v_roll FROM public.fabric_rolls WHERE id=v_rw.roll_id FOR UPDATE; IF v_roll.status NOT IN ('REWORK_REQUIRED','REWORK_IN_PROGRESS') THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ROLL_NOT_IN_REWORK'; END IF;
 PERFORM set_config('app.allow_roll_state','on',true);
 UPDATE public.fabric_rolls SET status='REINSPECTION_REQUIRED',version=version+1 WHERE id=v_roll.id;
 UPDATE public.rework_orders SET status='COMPLETED',completed_at=now(),notes=concat_ws(E'\n',notes,p_notes) WHERE id=p_rework_id;
 INSERT INTO public.roll_status_history(roll_id,from_status,to_status,reason,actor,is_demo) VALUES(v_roll.id,v_roll.status,'REINSPECTION_REQUIRED',COALESCE(p_notes,'Rework complete; QC reinspection required'),auth.uid(),v_roll.is_demo);
 RETURN jsonb_build_object('rework_id',p_rework_id,'roll_id',v_roll.id,'status','COMPLETED','next_action','REINSPECTION_REQUIRED');
END $$;

CREATE OR REPLACE FUNCTION public.rpc_set_machine_status(p_machine_id uuid,p_new_status text,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_machine public.machines%ROWTYPE; v_downtime uuid;
BEGIN
 IF p_new_status='BREAKDOWN' AND private.has_permission('machines.downtime') THEN NULL; ELSE PERFORM private.assert_permission('machines.status'); END IF;
 IF length(trim(COALESCE(p_reason,'')))<3 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: REASON_REQUIRED'; END IF;
 SELECT * INTO v_machine FROM public.machines WHERE id=p_machine_id FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: MACHINE_NOT_FOUND'; END IF;
 IF p_new_status='OFFLINE' AND NOT private.has_permission('settings.manage') AND NOT private.has_permission('master.manage') THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: PERMISSION_DENIED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.allowed_transitions WHERE entity='machine' AND from_state=v_machine.status AND to_state=p_new_status) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: INVALID_STATE_TRANSITION'; END IF;
 PERFORM set_config('app.allow_machine_state','on',true);
 UPDATE public.machines SET status=p_new_status WHERE id=p_machine_id;
 INSERT INTO public.machine_status_log(machine_id,from_status,to_status,changed_by,reason,is_demo) VALUES(p_machine_id,v_machine.status,p_new_status,auth.uid(),p_reason,v_machine.source='DEMO');
 IF p_new_status='BREAKDOWN' THEN
  INSERT INTO public.downtime_events(downtime_no,machine_id,reason_id,severity,reported_by,notes,is_demo) VALUES(private.next_doc_no('DT'),p_machine_id,(SELECT id FROM public.downtime_reasons WHERE code='MECH'), 'HIGH',auth.uid(),p_reason,v_machine.source='DEMO') RETURNING id INTO v_downtime;
  UPDATE public.production_operations SET at_risk=true,waiting_reason='Machine '||v_machine.machine_code||' is in Breakdown' WHERE machine_id=p_machine_id AND status IN ('PLANNED','READY','PAUSED');
  INSERT INTO public.exceptions(exception_no,type,severity,dedupe_key,title,reason,entity_type,entity_id,owner_role,suggested_action,is_demo) VALUES(private.next_doc_no('EXC'),'MACHINE_BREAKDOWN','HIGH','MACHINE_BREAKDOWN:'||p_machine_id::text,'Machine breakdown: '||v_machine.machine_code,p_reason,'machines',p_machine_id,'production_supervisor','{"action":"reschedule"}',v_machine.source='DEMO') ON CONFLICT DO NOTHING;
  INSERT INTO public.tasks(task_no,title,description,assignee_role,entity_type,entity_id,created_by,is_demo) VALUES(private.next_doc_no('TSK'),'Respond to breakdown: '||v_machine.machine_code,p_reason,'production_supervisor','downtime_events',v_downtime,auth.uid(),v_machine.source='DEMO');
 END IF;
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,reason,after_json) VALUES(auth.uid(),'MACHINE_STATUS_CHANGED','machines',p_machine_id,p_reason,jsonb_build_object('from',v_machine.status,'to',p_new_status));
 RETURN jsonb_build_object('machine_id',p_machine_id,'status',p_new_status,'downtime_event_id',v_downtime);
END $$;

CREATE OR REPLACE FUNCTION public.rpc_close_downtime(p_downtime_id uuid,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_dt public.downtime_events%ROWTYPE;
BEGIN
 PERFORM private.assert_permission('machines.status');
 SELECT * INTO v_dt FROM public.downtime_events WHERE id=p_downtime_id FOR UPDATE; IF NOT FOUND OR v_dt.status<>'OPEN' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: DOWNTIME_NOT_OPEN'; END IF;
 UPDATE public.downtime_events SET ended_at=now(),status='CLOSED',duration_minutes=extract(epoch FROM (now()-started_at))/60 WHERE id=p_downtime_id;
 PERFORM set_config('app.allow_machine_state','on',true);
 UPDATE public.machines SET status='IDLE' WHERE id=v_dt.machine_id AND status='BREAKDOWN';
 INSERT INTO public.machine_status_log(machine_id,from_status,to_status,changed_by,reason,is_demo) SELECT id,'BREAKDOWN','IDLE',auth.uid(),p_reason,source='DEMO' FROM public.machines WHERE id=v_dt.machine_id AND status='IDLE';
 RETURN jsonb_build_object('downtime_event_id',p_downtime_id,'status','CLOSED');
END $$;

CREATE OR REPLACE FUNCTION public.guard_quality_append_only() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$ BEGIN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: APPEND_ONLY'; END $$;
DROP TRIGGER IF EXISTS quality_inspections_append_only ON public.quality_inspections;
CREATE TRIGGER quality_inspections_append_only BEFORE UPDATE OR DELETE ON public.quality_inspections FOR EACH ROW EXECUTE FUNCTION public.guard_quality_append_only();
DROP TRIGGER IF EXISTS quality_defects_append_only ON public.quality_defects;
CREATE TRIGGER quality_defects_append_only BEFORE UPDATE OR DELETE ON public.quality_defects FOR EACH ROW EXECUTE FUNCTION public.guard_quality_append_only();
DROP TRIGGER IF EXISTS operation_events_append_only ON public.operation_events;
CREATE TRIGGER operation_events_append_only BEFORE UPDATE OR DELETE ON public.operation_events FOR EACH ROW EXECUTE FUNCTION public.guard_quality_append_only();

GRANT EXECUTE ON FUNCTION public.rpc_assign_operation(uuid,uuid,uuid,uuid,uuid[]),public.rpc_set_operation_state(uuid,text,text),public.rpc_record_output(uuid,uuid,numeric,numeric,numeric,text,uuid,text,text,text),public.rpc_inspect_roll(uuid,public.inspection_result,text,jsonb,jsonb,uuid),public.rpc_complete_rework(uuid,text),public.rpc_set_machine_status(uuid,text,text),public.rpc_close_downtime(uuid,text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_quality_append_only() FROM PUBLIC,anon,authenticated;
