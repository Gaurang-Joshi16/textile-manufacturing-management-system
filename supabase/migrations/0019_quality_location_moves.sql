CREATE OR REPLACE FUNCTION public.rpc_inspect_roll(p_roll_id uuid,p_result public.inspection_result,p_notes text,p_measurements jsonb,p_defects jsonb,p_idempotency_key uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_existing jsonb; v_roll public.fabric_rolls%ROWTYPE; v_insp uuid; v_no text; v_plan uuid; v_stage text; v_round integer; v_prior uuid; v_next public.roll_status; v_check jsonb; v_def jsonb; v_cat uuid; v_fail boolean:=false; v_result jsonb; v_target uuid; v_oldloc uuid; v_rework uuid; v_wh text;
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
 UPDATE public.fabric_rolls SET status=v_next,first_pass_result=CASE WHEN v_round=1 THEN p_result='PASS' ELSE first_pass_result END,hold_reason=CASE WHEN p_result='QUARANTINE' THEN COALESCE(NULLIF(p_notes,''),'Quality hold') WHEN p_result='REWORK' THEN 'Rework required' ELSE NULL END,version=version+1 WHERE id=p_roll_id;
 INSERT INTO public.roll_status_history(roll_id,from_status,to_status,reason,actor,is_demo) VALUES(p_roll_id,v_roll.status,v_next,COALESCE(p_notes,p_result::text),auth.uid(),v_roll.is_demo);
 IF p_result='PASS' THEN v_wh:='FINISHED'; ELSIF p_result='REWORK' THEN v_wh:='REWORK'; ELSIF p_result='QUARANTINE' THEN v_wh:='QUARANTINE'; ELSE v_wh:=NULL; END IF;
 IF v_wh IS NOT NULL THEN
  SELECT l.id INTO v_target FROM public.stock_locations l JOIN public.warehouses w ON w.id=l.warehouse_id WHERE w.type=v_wh AND l.is_active ORDER BY l.code LIMIT 1;
  IF v_target IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: STOCK_LOCATIONS_NOT_CONFIGURED'; END IF;
  v_oldloc:=v_roll.location_id;
  IF v_oldloc IS DISTINCT FROM v_target THEN
   INSERT INTO public.inventory_movements(movement_no,item_kind,roll_id,movement_type,qty,unit,from_location_id,to_location_id,source_type,source_id,created_by,is_demo) VALUES(private.next_doc_no('MOV'),'FABRIC_ROLL',p_roll_id,'TRANSFER',v_roll.qty,v_roll.unit,v_oldloc,v_target,'quality_inspection',v_insp,auth.uid(),v_roll.is_demo);
   UPDATE public.fabric_rolls SET location_id=v_target WHERE id=p_roll_id;
  END IF;
 END IF;
 IF p_result='REWORK' THEN
  INSERT INTO public.rework_orders(rework_no,roll_id,source_inspection_id,status,notes,is_demo) VALUES(private.next_doc_no('RWK'),p_roll_id,v_insp,'OPEN',COALESCE(p_notes,'Rework required'),v_roll.is_demo) RETURNING id INTO v_rework;
  INSERT INTO public.tasks(task_no,title,description,assignee_role,entity_type,entity_id,created_by,is_demo) VALUES(private.next_doc_no('TSK'),'Rework roll '||(SELECT roll_code FROM public.fabric_rolls WHERE id=p_roll_id),'Complete rework, then submit a linked reinspection.','quality_inspector','rework_orders',v_rework,auth.uid(),v_roll.is_demo);
 END IF;
 v_result:=jsonb_build_object('inspection_id',v_insp,'inspection_no',v_no,'roll_id',p_roll_id,'result',p_result,'roll_status',v_next,'rework_id',v_rework,'location_id',v_target);
 INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('inspect_roll',p_idempotency_key,auth.uid(),v_result);
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,after_json) VALUES(auth.uid(),'ROLL_INSPECTED','quality_inspections',v_insp,v_result);
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_complete_rework(p_rework_id uuid,p_notes text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_rw public.rework_orders%ROWTYPE; v_roll public.fabric_rolls%ROWTYPE; v_wip uuid;
BEGIN
 PERFORM private.assert_permission('quality.release');
 SELECT * INTO v_rw FROM public.rework_orders WHERE id=p_rework_id FOR UPDATE; IF NOT FOUND OR v_rw.status NOT IN ('OPEN','IN_PROGRESS') THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: REWORK_NOT_OPEN'; END IF;
 SELECT * INTO v_roll FROM public.fabric_rolls WHERE id=v_rw.roll_id FOR UPDATE; IF v_roll.status NOT IN ('REWORK_REQUIRED','REWORK_IN_PROGRESS') THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ROLL_NOT_IN_REWORK'; END IF;
 SELECT l.id INTO v_wip FROM public.stock_locations l JOIN public.warehouses w ON w.id=l.warehouse_id WHERE w.type='WIP' AND l.is_active ORDER BY l.code LIMIT 1;
 IF v_wip IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: STOCK_LOCATIONS_NOT_CONFIGURED'; END IF;
 IF v_roll.location_id IS DISTINCT FROM v_wip THEN
  INSERT INTO public.inventory_movements(movement_no,item_kind,roll_id,movement_type,qty,unit,from_location_id,to_location_id,source_type,source_id,created_by,is_demo) VALUES(private.next_doc_no('MOV'),'FABRIC_ROLL',v_roll.id,'TRANSFER',v_roll.qty,v_roll.unit,v_roll.location_id,v_wip,'rework',p_rework_id,auth.uid(),v_roll.is_demo);
  UPDATE public.fabric_rolls SET location_id=v_wip WHERE id=v_roll.id;
 END IF;
 PERFORM set_config('app.allow_roll_state','on',true);
 UPDATE public.fabric_rolls SET status='REINSPECTION_REQUIRED',version=version+1,hold_reason=NULL WHERE id=v_roll.id;
 UPDATE public.rework_orders SET status='COMPLETED',completed_at=now(),notes=concat_ws(E'\n',notes,p_notes) WHERE id=p_rework_id;
 INSERT INTO public.roll_status_history(roll_id,from_status,to_status,reason,actor,is_demo) VALUES(v_roll.id,v_roll.status,'REINSPECTION_REQUIRED',COALESCE(p_notes,'Rework complete; QC reinspection required'),auth.uid(),v_roll.is_demo);
 RETURN jsonb_build_object('rework_id',p_rework_id,'roll_id',v_roll.id,'status','COMPLETED','next_action','REINSPECTION_REQUIRED');
END $$;
