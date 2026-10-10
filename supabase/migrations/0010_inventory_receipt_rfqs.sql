-- Correct mixed-receipt availability: accepted RAW stock stays available while quarantined qty remains isolated.
INSERT INTO public.role_permissions(role_id,permission_id)
SELECT r.id,p.id FROM public.roles r CROSS JOIN public.permissions p WHERE r.key='factory_manager' AND p.key IN ('inventory.reserve','purchasing.draft') ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.rpc_post_receipt(p_supplier_id uuid,p_po_id uuid,p_delivery_reference text,p_lines jsonb,p_idempotency_key uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_existing jsonb; v_receipt uuid; v_receipt_no text; v_line jsonb; v_item public.yarn_items%ROWTYPE; v_batch uuid; v_batch_code text; v_received numeric(14,3); v_accepted numeric(14,3); v_damaged numeric(14,3); v_quarantined numeric(14,3); v_unit text; v_cost numeric(16,2); v_raw uuid; v_quar uuid; v_result jsonb; v_demo boolean; v_batch_status public.batch_status; v_total numeric(14,3);
BEGIN
 PERFORM private.assert_permission('inventory.receive');
 IF p_idempotency_key IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: IDEMPOTENCY_KEY_REQUIRED'; END IF;
 SELECT response INTO v_existing FROM public.idempotency_keys WHERE scope='post_receipt' AND key=p_idempotency_key; IF FOUND THEN RETURN v_existing; END IF;
 IF jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)=0 THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: RECEIPT_LINES_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.suppliers WHERE id=p_supplier_id AND is_active) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: SUPPLIER_NOT_FOUND'; END IF;
 SELECT EXISTS(SELECT 1 FROM public.suppliers WHERE id=p_supplier_id AND source='DEMO') INTO v_demo;
 SELECT id INTO v_raw FROM public.stock_locations l JOIN public.warehouses w ON w.id=l.warehouse_id WHERE w.type='RAW' AND l.is_active ORDER BY l.code LIMIT 1;
 SELECT id INTO v_quar FROM public.stock_locations l JOIN public.warehouses w ON w.id=l.warehouse_id WHERE w.type='QUARANTINE' AND l.is_active ORDER BY l.code LIMIT 1;
 IF v_raw IS NULL OR v_quar IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: STOCK_LOCATIONS_NOT_CONFIGURED'; END IF;
 v_receipt_no:=private.next_doc_no('RCP');
 INSERT INTO public.purchase_receipts(receipt_number,supplier_id,po_id,delivery_reference,received_by,is_demo) VALUES(v_receipt_no,p_supplier_id,p_po_id,p_delivery_reference,auth.uid(),v_demo) RETURNING id INTO v_receipt;
 FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
  SELECT * INTO v_item FROM public.yarn_items WHERE id=(v_line->>'yarn_item_id')::uuid AND is_active FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: YARN_ITEM_NOT_FOUND'; END IF;
  v_demo:=v_demo OR v_item.source='DEMO';
  v_received:=(v_line->>'received_qty')::numeric; v_accepted:=(v_line->>'accepted_qty')::numeric; v_damaged:=(v_line->>'damaged_qty')::numeric; v_quarantined:=(v_line->>'quarantined_qty')::numeric; v_unit:=COALESCE(v_line->>'unit',''); v_cost:=(v_line->>'unit_cost')::numeric;
  IF v_received<=0 OR v_accepted<0 OR v_damaged<0 OR v_quarantined<0 OR v_received<>v_accepted+v_damaged+v_quarantined THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: RECEIPT_QTY_MISMATCH'; END IF;
  IF v_unit<>v_item.unit THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: UNIT_CONVERSION_MISSING'; END IF;
  v_total:=v_accepted+v_quarantined;
  v_batch_status:=CASE WHEN v_item.requires_inspection OR (v_accepted=0 AND v_quarantined>0) THEN 'QUARANTINED'::public.batch_status WHEN v_accepted>0 THEN 'AVAILABLE'::public.batch_status ELSE 'DEPLETED'::public.batch_status END;
  INSERT INTO public.yarn_batches(batch_code,yarn_item_id,receipt_id,po_line_id,supplier_lot,received_qty,accepted_qty,damaged_qty,quarantined_qty,unit,unit_cost,currency,colour,status,hold_reason,is_demo)
  VALUES(private.next_doc_no('YB'),v_item.id,v_receipt,NULL,COALESCE(v_line->>'supplier_lot',''),v_received,v_accepted,v_damaged,v_quarantined,v_item.unit,v_cost,COALESCE(v_line->>'currency','INR'),COALESCE(v_line->>'colour',v_item.colour),v_batch_status,CASE WHEN v_item.requires_inspection THEN 'Inspection required' WHEN v_quarantined>0 THEN 'Supplier quarantine' ELSE NULL END,v_demo) RETURNING id,batch_code INTO v_batch,v_batch_code;
  IF v_item.requires_inspection THEN
   IF v_total>0 THEN INSERT INTO public.inventory_movements(movement_no,yarn_batch_id,movement_type,qty,unit,to_location_id,source_type,source_id,created_by,is_demo) VALUES(private.next_doc_no('MOV'),v_batch,'QUARANTINE_IN',v_total,v_item.unit,v_quar,'receipt',v_receipt,auth.uid(),v_demo); END IF;
  ELSE
   IF v_accepted>0 THEN INSERT INTO public.inventory_movements(movement_no,yarn_batch_id,movement_type,qty,unit,to_location_id,source_type,source_id,created_by,is_demo) VALUES(private.next_doc_no('MOV'),v_batch,'RECEIPT',v_accepted,v_item.unit,v_raw,'receipt',v_receipt,auth.uid(),v_demo); END IF;
   IF v_quarantined>0 THEN INSERT INTO public.inventory_movements(movement_no,yarn_batch_id,movement_type,qty,unit,to_location_id,source_type,source_id,created_by,is_demo) VALUES(private.next_doc_no('MOV'),v_batch,'QUARANTINE_IN',v_quarantined,v_item.unit,v_quar,'receipt',v_receipt,auth.uid(),v_demo); END IF;
  END IF;
 END LOOP;
 v_result:=jsonb_build_object('receipt_id',v_receipt,'receipt_number',v_receipt_no,'status','POSTED');
 INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('post_receipt',p_idempotency_key,auth.uid(),v_result);
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,after_json) VALUES(auth.uid(),'RECEIPT_POSTED','purchase_receipts',v_receipt,v_result);
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_generate_rfq_drafts(p_order_id uuid,p_idempotency_key uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_existing jsonb; v_check public.feasibility_checks%ROWTYPE; v_item jsonb; v_yarn public.yarn_items%ROWTYPE; v_supplier uuid; v_event text; v_po uuid; v_line uuid; v_created jsonb:='[]'::jsonb; v_result jsonb;
BEGIN
 PERFORM private.assert_permission('purchasing.draft');
 SELECT response INTO v_existing FROM public.idempotency_keys WHERE scope='generate_rfq_drafts' AND key=p_idempotency_key; IF FOUND THEN RETURN v_existing; END IF;
 SELECT * INTO v_check FROM public.feasibility_checks WHERE order_id=p_order_id ORDER BY created_at DESC LIMIT 1;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: FEASIBILITY_REQUIRED'; END IF;
 FOR v_item IN SELECT value FROM jsonb_array_elements(v_check.details->'materials') WHERE COALESCE((value->>'shortage_qty')::numeric,0)>0 LOOP
  SELECT * INTO v_yarn FROM public.yarn_items WHERE item_code=v_item->>'item_code';
  IF NOT FOUND OR v_yarn.preferred_supplier_id IS NULL THEN CONTINUE; END IF;
  v_supplier:=v_yarn.preferred_supplier_id; v_event:='A02:'||v_yarn.id::text||':'||v_check.id::text;
  SELECT id INTO v_po FROM public.purchase_orders WHERE event_key=v_event;
  IF v_po IS NULL THEN
   INSERT INTO public.purchase_orders(po_number,supplier_id,status,currency,source,is_rfq_draft,event_key,created_by,is_demo) VALUES(private.next_doc_no('RFQ'),v_supplier,'DRAFT','INR','AUTO_SHORTAGE',true,v_event,auth.uid(),v_yarn.source='DEMO') RETURNING id INTO v_po;
   INSERT INTO public.purchase_order_lines(po_id,yarn_item_id,ordered_qty,unit,unit_price) VALUES(v_po,v_yarn.id,(v_item->>'shortage_qty')::numeric,v_yarn.unit,v_yarn.standard_unit_cost) RETURNING id INTO v_line;
   INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,after_json) VALUES(auth.uid(),'RFQ_DRAFT_CREATED','purchase_orders',v_po,jsonb_build_object('event_key',v_event,'quantity',(v_item->>'shortage_qty')::numeric,'unit',v_yarn.unit));
  END IF;
  v_created:=v_created||jsonb_build_array(jsonb_build_object('purchase_order_id',v_po,'event_key',v_event,'item_code',v_yarn.item_code,'quantity',(v_item->>'shortage_qty')::numeric,'unit',v_yarn.unit,'status','DRAFT'));
 END LOOP;
 v_result:=jsonb_build_object('drafts',v_created,'sent_to_supplier',false);
 INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('generate_rfq_drafts',p_idempotency_key,auth.uid(),v_result);
 RETURN v_result;
END $$;

CREATE OR REPLACE VIEW public.v_yarn_stock AS
WITH ledger AS (
 SELECT b.id AS yarn_batch_id,b.yarn_item_id,m.to_location_id AS location_id,sum(m.qty) AS qty FROM public.yarn_batches b JOIN public.inventory_movements m ON m.yarn_batch_id=b.id WHERE m.to_location_id IS NOT NULL GROUP BY b.id,b.yarn_item_id,m.to_location_id
 UNION ALL SELECT b.id,b.yarn_item_id,m.from_location_id,-sum(m.qty) FROM public.yarn_batches b JOIN public.inventory_movements m ON m.yarn_batch_id=b.id WHERE m.from_location_id IS NOT NULL GROUP BY b.id,b.yarn_item_id,m.from_location_id
), balances AS (SELECT yarn_batch_id,yarn_item_id,location_id,sum(qty) on_hand FROM ledger GROUP BY yarn_batch_id,yarn_item_id,location_id), reserves AS (SELECT yarn_batch_id,location_id,sum(qty-consumed_qty) reserved FROM public.material_reservations WHERE status IN ('ACTIVE','AT_RISK') GROUP BY yarn_batch_id,location_id), expected AS (SELECT pol.yarn_item_id,greatest(0,sum(pol.ordered_qty)-sum(COALESCE(received.qty,0)))::numeric(14,3) qty FROM public.purchase_order_lines pol JOIN public.purchase_orders po ON po.id=pol.po_id LEFT JOIN LATERAL (SELECT sum(yb.received_qty) qty FROM public.yarn_batches yb WHERE yb.po_line_id=pol.id) received ON true WHERE po.status IN ('APPROVED','SENT','PARTIALLY_RECEIVED') GROUP BY pol.yarn_item_id)
SELECT b.yarn_item_id,b.id AS yarn_batch_id,bal.location_id,bal.on_hand,COALESCE(r.reserved,0)::numeric(14,3) reserved,CASE WHEN w.type='QUARANTINE' OR b.status<>'AVAILABLE' THEN bal.on_hand ELSE 0 END::numeric(14,3) quarantined,CASE WHEN w.type='RAW' AND b.status='AVAILABLE' THEN greatest(0,bal.on_hand-COALESCE(r.reserved,0)) ELSE 0 END::numeric(14,3) available,COALESCE(e.qty,0)::numeric(14,3) expected FROM public.yarn_batches b JOIN balances bal ON bal.yarn_batch_id=b.id JOIN public.stock_locations l ON l.id=bal.location_id JOIN public.warehouses w ON w.id=l.warehouse_id LEFT JOIN reserves r ON r.yarn_batch_id=b.id AND r.location_id=bal.location_id LEFT JOIN expected e ON e.yarn_item_id=b.yarn_item_id;

GRANT EXECUTE ON FUNCTION public.rpc_generate_rfq_drafts(uuid,uuid) TO authenticated;
