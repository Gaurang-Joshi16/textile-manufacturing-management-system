CREATE OR REPLACE FUNCTION public.rpc_create_shipment(p_order_id uuid,p_requested_qty numeric,p_idempotency_key uuid,p_carrier text DEFAULT '',p_vehicle_no text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_existing jsonb; v_order public.buyer_orders%ROWTYPE; v_ship uuid; v_no text; v_result jsonb;
BEGIN
 PERFORM private.assert_permission('dispatch.create');
 IF p_idempotency_key IS NULL OR p_requested_qty<=0 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: SHIPMENT_REQUEST_INVALID'; END IF;
 SELECT response INTO v_existing FROM public.idempotency_keys WHERE scope='create_shipment' AND key=p_idempotency_key; IF FOUND THEN RETURN v_existing; END IF;
 SELECT * INTO v_order FROM public.buyer_orders WHERE id=p_order_id FOR UPDATE; IF NOT FOUND OR v_order.status NOT IN ('IN_PRODUCTION','READY_FOR_DISPATCH','PARTIALLY_DISPATCHED') THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ORDER_NOT_DISPATCHABLE'; END IF;
 IF p_requested_qty>COALESCE((SELECT sum(ordered_qty)*(1+v_order.over_delivery_pct/100.0) FROM public.buyer_order_lines WHERE order_id=p_order_id),0) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: SHIPMENT_QTY_EXCEEDS_ORDER'; END IF;
 v_no:=private.next_doc_no('SHP');
 INSERT INTO public.shipments(shipment_number,order_id,status,planned_at,requested_qty,carrier,vehicle_no,created_by,idempotency_key) VALUES(v_no,p_order_id,'DRAFT',now(),p_requested_qty,COALESCE(p_carrier,''),COALESCE(p_vehicle_no,''),auth.uid(),p_idempotency_key) RETURNING id INTO v_ship;
 v_result:=jsonb_build_object('shipment_id',v_ship,'shipment_number',v_no,'status','DRAFT');
 INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('create_shipment',p_idempotency_key,auth.uid(),v_result);
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,after_json) VALUES(auth.uid(),'SHIPMENT_DRAFT_CREATED','shipments',v_ship,v_result);
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_allocate_rolls(p_shipment_id uuid,p_roll_ids uuid[],p_idempotency_key uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_existing jsonb; v_ship public.shipments%ROWTYPE; v_roll public.fabric_rolls%ROWTYPE; v_roll_id uuid; v_order public.buyer_orders%ROWTYPE; v_alloc numeric:=0; v_ordered numeric; v_prior numeric; v_result jsonb; v_count integer:=0;
BEGIN
 PERFORM private.assert_permission('dispatch.allocate');
 IF COALESCE(array_length(p_roll_ids,1),0)=0 OR p_idempotency_key IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ROLLS_REQUIRED'; END IF;
 SELECT response INTO v_existing FROM public.idempotency_keys WHERE scope='allocate_rolls' AND key=p_idempotency_key; IF FOUND THEN RETURN v_existing; END IF;
 SELECT * INTO v_ship FROM public.shipments WHERE id=p_shipment_id FOR UPDATE; IF NOT FOUND OR v_ship.status<>'DRAFT' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: SHIPMENT_NOT_DRAFT'; END IF;
 SELECT * INTO v_order FROM public.buyer_orders WHERE id=v_ship.order_id FOR UPDATE;
 SELECT COALESCE(sum(ordered_qty)*(1+v_order.over_delivery_pct/100.0),0) INTO v_ordered FROM public.buyer_order_lines WHERE order_id=v_ship.order_id;
 SELECT COALESCE(sum(sr.allocated_qty),0) INTO v_prior FROM public.shipment_rolls sr JOIN public.shipments s ON s.id=sr.shipment_id WHERE s.order_id=v_ship.order_id AND sr.status IN ('ALLOCATED','SCANNED','DISPATCHED');
 FOREACH v_roll_id IN ARRAY p_roll_ids LOOP
  SELECT * INTO v_roll FROM public.fabric_rolls WHERE id=v_roll_id FOR UPDATE;
  IF NOT FOUND OR v_roll.status<>'ACCEPTED' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ROLL_NOT_ELIGIBLE'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.buyer_order_lines WHERE id=v_roll.order_line_id AND order_id=v_ship.order_id) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ROLL_ORDER_MISMATCH'; END IF;
  IF EXISTS(SELECT 1 FROM public.shipment_rolls WHERE roll_id=v_roll.id AND status IN ('ALLOCATED','SCANNED','DISPATCHED')) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ROLL_ALREADY_ALLOCATED'; END IF;
  v_alloc:=v_alloc+v_roll.qty; v_count:=v_count+1;
 END LOOP;
 IF v_alloc>v_ship.requested_qty OR v_alloc+v_prior>v_ordered THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: SHIPMENT_QTY_EXCEEDS_ORDER'; END IF;
 FOREACH v_roll_id IN ARRAY p_roll_ids LOOP
  SELECT * INTO v_roll FROM public.fabric_rolls WHERE id=v_roll_id FOR UPDATE;
  PERFORM set_config('app.allow_roll_state','on',true);
  UPDATE public.fabric_rolls SET status='RESERVED',prior_status='ACCEPTED',version=version+1 WHERE id=v_roll.id;
  INSERT INTO public.roll_status_history(roll_id,from_status,to_status,reason,actor,is_demo) VALUES(v_roll.id,'ACCEPTED','RESERVED','Allocated to shipment '||v_ship.shipment_number,auth.uid(),v_roll.is_demo);
  INSERT INTO public.shipment_rolls(shipment_id,roll_id,order_line_id,allocated_qty,status,is_demo) VALUES(p_shipment_id,v_roll.id,v_roll.order_line_id,v_roll.qty,'ALLOCATED',v_roll.is_demo);
 END LOOP;
 PERFORM set_config('app.allow_shipment_state','on',true);
 UPDATE public.shipments SET status='ALLOCATED',manifest_expected_count=v_count,manifest_scanned_count=0 WHERE id=p_shipment_id;
 v_result:=jsonb_build_object('shipment_id',p_shipment_id,'status','ALLOCATED','roll_count',v_count,'allocated_qty',v_alloc,'unit',v_roll.unit);
 INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('allocate_rolls',p_idempotency_key,auth.uid(),v_result);
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,after_json) VALUES(auth.uid(),'ROLLS_ALLOCATED','shipments',p_shipment_id,v_result);
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_scan_manifest(p_shipment_id uuid,p_roll_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_ship public.shipments%ROWTYPE; v_roll public.fabric_rolls%ROWTYPE; v_sr uuid; v_result text; v_scanned integer;
BEGIN
 PERFORM private.assert_permission('dispatch.create');
 SELECT * INTO v_ship FROM public.shipments WHERE id=p_shipment_id FOR UPDATE; IF NOT FOUND OR v_ship.status<>'ALLOCATED' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: SHIPMENT_NOT_OPEN'; END IF;
 SELECT * INTO v_roll FROM public.fabric_rolls WHERE roll_code=p_roll_code FOR UPDATE;
 IF FOUND THEN SELECT id INTO v_sr FROM public.shipment_rolls WHERE shipment_id=p_shipment_id AND roll_id=v_roll.id AND status IN ('ALLOCATED','SCANNED'); END IF;
 IF v_sr IS NULL THEN
  v_result:='MISMATCH';
  INSERT INTO public.shipment_scan_events(shipment_id,roll_code,result,scanned_by,is_demo) VALUES(p_shipment_id,p_roll_code,v_result,auth.uid(),v_ship.is_demo);
  UPDATE public.shipments SET needs_attention=true WHERE id=p_shipment_id;
  RETURN jsonb_build_object('result',v_result,'message','Roll is not part of this shipment');
 END IF;
 IF EXISTS(SELECT 1 FROM public.shipment_rolls WHERE id=v_sr AND status='SCANNED') THEN
  INSERT INTO public.shipment_scan_events(shipment_id,roll_code,result,scanned_by,is_demo) VALUES(p_shipment_id,p_roll_code,'DUPLICATE',auth.uid(),v_ship.is_demo);
  RETURN jsonb_build_object('result','DUPLICATE','roll_code',p_roll_code);
 END IF;
 UPDATE public.shipment_rolls SET status='SCANNED',scanned_at=now() WHERE id=v_sr;
 INSERT INTO public.shipment_scan_events(shipment_id,roll_code,result,scanned_by,is_demo) VALUES(p_shipment_id,p_roll_code,'MATCH',auth.uid(),v_ship.is_demo);
 SELECT count(*) INTO v_scanned FROM public.shipment_rolls WHERE shipment_id=p_shipment_id AND status='SCANNED';
 UPDATE public.shipments SET manifest_scanned_count=v_scanned,needs_attention=(v_scanned<>manifest_expected_count) WHERE id=p_shipment_id;
 RETURN jsonb_build_object('result','MATCH','roll_code',p_roll_code,'scanned_count',v_scanned,'expected_count',v_ship.manifest_expected_count);
END $$;

CREATE OR REPLACE FUNCTION public.rpc_confirm_shipment(p_shipment_id uuid,p_ack_mismatch boolean,p_mismatch_reason text,p_idempotency_key uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_existing jsonb; v_ship public.shipments%ROWTYPE; v_order public.buyer_orders%ROWTYPE; v_roll record; v_fg uuid; v_invoice uuid; v_invoice_no text; v_total numeric; v_shipped numeric; v_ordered numeric; v_next public.order_status; v_result jsonb; v_buyer_user uuid;
BEGIN
 PERFORM private.assert_permission('dispatch.confirm');
 IF p_idempotency_key IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: IDEMPOTENCY_KEY_REQUIRED'; END IF;
 SELECT response INTO v_existing FROM public.idempotency_keys WHERE scope='confirm_shipment' AND key=p_idempotency_key; IF FOUND THEN RETURN v_existing; END IF;
 SELECT * INTO v_ship FROM public.shipments WHERE id=p_shipment_id FOR UPDATE; IF NOT FOUND OR v_ship.status<>'ALLOCATED' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: SHIPMENT_NOT_ALLOCATED'; END IF;
 IF v_ship.manifest_scanned_count<>v_ship.manifest_expected_count THEN
  IF NOT COALESCE(p_ack_mismatch,false) OR length(trim(COALESCE(p_mismatch_reason,'')))<10 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: MANIFEST_MISMATCH_ACK_REQUIRED'; END IF;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.shipment_rolls WHERE shipment_id=p_shipment_id AND status IN ('ALLOCATED','SCANNED')) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: SHIPMENT_EMPTY'; END IF;
 IF EXISTS(SELECT 1 FROM public.shipment_rolls sr JOIN public.fabric_rolls r ON r.id=sr.roll_id WHERE sr.shipment_id=p_shipment_id AND (r.status<>'RESERVED' OR r.hold_reason IS NOT NULL)) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: ROLL_NOT_ELIGIBLE'; END IF;
 SELECT id INTO v_fg FROM public.stock_locations l JOIN public.warehouses w ON w.id=l.warehouse_id WHERE w.type='FINISHED' AND l.is_active ORDER BY l.code LIMIT 1;
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
 IF v_order.status='IN_PRODUCTION' THEN
  PERFORM set_config('app.allow_order_state','on',true); UPDATE public.buyer_orders SET status='READY_FOR_DISPATCH' WHERE id=v_order.id; v_order.status:='READY_FOR_DISPATCH';
 END IF;
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

GRANT EXECUTE ON FUNCTION public.rpc_create_shipment(uuid,numeric,uuid,text,text),public.rpc_allocate_rolls(uuid,uuid[],uuid),public.rpc_scan_manifest(uuid,text),public.rpc_confirm_shipment(uuid,boolean,text,uuid) TO authenticated;
