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
 UPDATE public.fabric_rolls SET status=v_next,first_pass_result=CASE WHEN v_round=1 THEN p_result='PASS' ELSE first_pass_result END,hold_reason=CASE WHEN p_result='QUARANTINE' THEN COALESCE(NULLIF(p_notes,''),'Quality hold') WHEN p_result='REWORK' THEN 'Rework required' ELSE NULL END,version=version+1 WHERE id=p_roll_id;
 INSERT INTO public.roll_status_history(roll_id,from_status,to_status,reason,actor,is_demo) VALUES(p_roll_id,v_roll.status,v_next,COALESCE(p_notes,p_result::text),auth.uid(),v_roll.is_demo);
 IF p_result='PASS' THEN
  SELECT l.id INTO v_fg FROM public.stock_locations l JOIN public.warehouses w ON w.id=l.warehouse_id WHERE w.type='FINISHED' AND l.is_active ORDER BY l.code LIMIT 1;
  IF v_fg IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: STOCK_LOCATIONS_NOT_CONFIGURED'; END IF;
  v_oldloc:=v_roll.location_id;
  INSERT INTO public.inventory_movements(movement_no,item_kind,roll_id,movement_type,qty,unit,from_location_id,to_location_id,source_type,source_id,created_by,is_demo) VALUES(private.next_doc_no('MOV'),'FABRIC_ROLL',p_roll_id,'TRANSFER',v_roll.qty,v_roll.unit,v_oldloc,v_fg,'quality_inspection',v_insp,auth.uid(),v_roll.is_demo);
  UPDATE public.fabric_rolls SET location_id=v_fg WHERE id=p_roll_id;
 ELSIF p_result='REWORK' THEN
  INSERT INTO public.rework_orders(rework_no,roll_id,source_inspection_id,status,notes,is_demo) VALUES(private.next_doc_no('RWK'),p_roll_id,v_insp,'OPEN',COALESCE(p_notes,'Rework required'),v_roll.is_demo) RETURNING id INTO v_rework;
  INSERT INTO public.tasks(task_no,title,description,assignee_role,entity_type,entity_id,created_by,is_demo) VALUES(private.next_doc_no('TSK'),'Rework roll '||(SELECT roll_code FROM public.fabric_rolls WHERE id=p_roll_id),'Complete rework, then submit a linked reinspection.','quality_inspector','rework_orders',v_rework,auth.uid(),v_roll.is_demo);
 END IF;
 v_result:=jsonb_build_object('inspection_id',v_insp,'inspection_no',v_no,'roll_id',p_roll_id,'result',p_result,'roll_status',v_next,'rework_id',v_rework);
 INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('inspect_roll',p_idempotency_key,auth.uid(),v_result);
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,after_json) VALUES(auth.uid(),'ROLL_INSPECTED','quality_inspections',v_insp,v_result);
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_confirm_shipment(p_shipment_id uuid,p_ack_mismatch boolean,p_mismatch_reason text,p_idempotency_key uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_existing jsonb; v_ship public.shipments%ROWTYPE; v_order public.buyer_orders%ROWTYPE; v_roll record; v_fg uuid; v_invoice uuid; v_invoice_no text; v_total numeric; v_shipped numeric; v_ordered numeric; v_next public.order_status; v_result jsonb; v_buyer_user uuid;
BEGIN
 PERFORM private.assert_permission('dispatch.confirm');
 IF p_idempotency_key IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: IDEMPOTENCY_KEY_REQUIRED'; END IF;
 SELECT response INTO v_existing FROM public.idempotency_keys WHERE scope='confirm_shipment' AND key=p_idempotency_key; IF FOUND THEN RETURN v_existing; END IF;
 SELECT * INTO v_ship FROM public.shipments WHERE id=p_shipment_id FOR UPDATE; IF NOT FOUND OR v_ship.status<>'ALLOCATED' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: SHIPMENT_NOT_ALLOCATED'; END IF;
 IF v_ship.manifest_scanned_count<>v_ship.manifest_expected_count AND (NOT COALESCE(p_ack_mismatch,false) OR length(trim(COALESCE(p_mismatch_reason,'')))<10) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: MANIFEST_MISMATCH_ACK_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.shipment_rolls WHERE shipment_id=p_shipment_id AND status IN ('ALLOCATED','SCANNED')) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: SHIPMENT_EMPTY'; END IF;
 IF EXISTS(SELECT 1 FROM public.shipment_rolls sr JOIN public.fabric_rolls r ON r.id=sr.roll_id WHERE sr.shipment_id=p_shipment_id AND (r.status<>'RESERVED' OR r.hold_reason IS NOT NULL)) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ROLL_NOT_ELIGIBLE'; END IF;
 SELECT l.id INTO v_fg FROM public.stock_locations l JOIN public.warehouses w ON w.id=l.warehouse_id WHERE w.type='FINISHED' AND l.is_active ORDER BY l.code LIMIT 1;
 IF v_fg IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: STOCK_LOCATIONS_NOT_CONFIGURED'; END IF;
 FOR v_roll IN SELECT sr.id sr_id,sr.roll_id,sr.allocated_qty,sr.is_demo,r.roll_code,r.qty,r.unit,r.location_id,r.order_line_id,r.is_demo roll_demo FROM public.shipment_rolls sr JOIN public.fabric_rolls r ON r.id=sr.roll_id WHERE sr.shipment_id=p_shipment_id AND sr.status IN ('ALLOCATED','SCANNED') FOR UPDATE OF r LOOP
  IF v_roll.location_id IS DISTINCT FROM v_fg THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ROLL_LOCATION_INVALID'; END IF;
  PERFORM set_config('app.allow_roll_state','on',true);
  UPDATE public.fabric_rolls SET status='DISPATCHED',version=version+1 WHERE id=v_roll.roll_id;
  INSERT INTO public.roll_status_history(roll_id,from_status,to_status,reason,actor,is_demo) VALUES(v_roll.roll_id,'RESERVED','DISPATCHED','Shipment '||v_ship.shipment_number||' confirmed',auth.uid(),v_roll.roll_demo);
  INSERT INTO public.inventory_movements(movement_no,item_kind,roll_id,movement_type,qty,unit,from_location_id,source_type,source_id,created_by,is_demo) VALUES(private.next_doc_no('MOV'),'FABRIC_ROLL',v_roll.roll_id,'DISPATCH',v_roll.qty,v_roll.unit,v_fg,'shipment',p_shipment_id,auth.uid(),v_roll.roll_demo);
  UPDATE public.shipment_rolls SET status='DISPATCHED' WHERE id=v_roll.sr_id;
 END LOOP;
 UPDATE public.shipments SET status='CONFIRMED',dispatched_at=now(),confirmed_by=auth.uid(),buyer_visible=true,scan_mismatch_ack=(manifest_scanned_count<>manifest_expected_count),scan_mismatch_reason=CASE WHEN manifest_scanned_count<>manifest_expected_count THEN p_mismatch_reason ELSE NULL END,needs_attention=false WHERE id=p_shipment_id;
 SELECT * INTO v_order FROM public.buyer_orders WHERE id=v_ship.order_id FOR UPDATE;
 SELECT COALESCE(sum(sr.allocated_qty),0) INTO v_shipped FROM public.shipment_rolls sr JOIN public.shipments s ON s.id=sr.shipment_id WHERE s.order_id=v_ship.order_id AND sr.status='DISPATCHED';
 SELECT COALESCE(sum(ordered_qty),0)*(1+v_order.over_delivery_pct/100.0) INTO v_ordered FROM public.buyer_order_lines WHERE order_id=v_ship.order_id;
 IF v_order.status='IN_PRODUCTION' THEN PERFORM set_config('app.allow_order_state','on',true); UPDATE public.buyer_orders SET status='READY_FOR_DISPATCH' WHERE id=v_order.id; v_order.status:='READY_FOR_DISPATCH'; END IF;
 IF v_order.status NOT IN ('READY_FOR_DISPATCH','PARTIALLY_DISPATCHED') THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ORDER_NOT_READY_FOR_DISPATCH'; END IF;
 v_next:=CASE WHEN v_shipped>=v_ordered THEN 'DISPATCHED'::public.order_status ELSE 'PARTIALLY_DISPATCHED'::public.order_status END;
 IF v_order.status<>v_next THEN PERFORM set_config('app.allow_order_state','on',true); UPDATE public.buyer_orders SET status=v_next WHERE id=v_order.id; END IF;
 SELECT COALESCE(sum(sr.allocated_qty*bol.unit_rate),0) INTO v_total FROM public.shipment_rolls sr JOIN public.buyer_order_lines bol ON bol.id=sr.order_line_id WHERE sr.shipment_id=p_shipment_id;
 v_invoice_no:=private.next_doc_no('INV');
 INSERT INTO public.invoices(invoice_number,shipment_id,order_id,invoice_date,due_date,currency,subtotal,tax_rate,tax_amount,total,status) SELECT v_invoice_no,p_shipment_id,v_order.id,current_date,current_date+COALESCE(b.credit_days,30),v_order.currency,v_total,0,0,v_total,'DRAFT' FROM public.buyers b WHERE b.id=v_order.buyer_id RETURNING id INTO v_invoice;
 SELECT p.id INTO v_buyer_user FROM public.profiles p WHERE p.buyer_id=v_order.buyer_id AND p.status='ACTIVE' LIMIT 1;
 IF v_buyer_user IS NOT NULL THEN INSERT INTO public.notifications(user_id,type,severity,title,body,entity_type,entity_id,action_url,dedupe_key,is_demo) VALUES(v_buyer_user,'SHIPMENT_DISPATCHED','INFO','Shipment dispatched','Your shipment '||v_ship.shipment_number||' has been dispatched.','shipments',p_shipment_id,'/portal/timeline','shipment-dispatched:'||p_shipment_id,v_ship.is_demo) ON CONFLICT DO NOTHING; END IF;
 v_result:=jsonb_build_object('shipment_id',p_shipment_id,'shipment_number',v_ship.shipment_number,'status','CONFIRMED','order_status',v_next,'dispatched_qty',(SELECT sum(allocated_qty) FROM public.shipment_rolls WHERE shipment_id=p_shipment_id),'invoice_id',v_invoice,'invoice_status','DRAFT');
 INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('confirm_shipment',p_idempotency_key,auth.uid(),v_result);
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,reason,after_json) VALUES(auth.uid(),'SHIPMENT_CONFIRMED','shipments',p_shipment_id,p_mismatch_reason,v_result);
 RETURN v_result;
END $$;
