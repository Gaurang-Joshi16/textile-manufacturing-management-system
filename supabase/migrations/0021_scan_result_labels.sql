CREATE OR REPLACE FUNCTION public.rpc_scan_manifest(p_shipment_id uuid,p_roll_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_ship public.shipments%ROWTYPE; v_roll public.fabric_rolls%ROWTYPE; v_sr uuid; v_result text; v_scanned integer;
BEGIN
 PERFORM private.assert_permission('dispatch.create');
 SELECT * INTO v_ship FROM public.shipments WHERE id=p_shipment_id FOR UPDATE; IF NOT FOUND OR v_ship.status<>'ALLOCATED' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: SHIPMENT_NOT_OPEN'; END IF;
 SELECT * INTO v_roll FROM public.fabric_rolls WHERE roll_code=p_roll_code FOR UPDATE;
 IF FOUND THEN SELECT id INTO v_sr FROM public.shipment_rolls WHERE shipment_id=p_shipment_id AND roll_id=v_roll.id AND status IN ('ALLOCATED','SCANNED'); END IF;
 IF v_sr IS NULL THEN
  v_result:='NOT_ON_MANIFEST';
  INSERT INTO public.shipment_scan_events(shipment_id,roll_code,result,scanned_by,is_demo) VALUES(p_shipment_id,p_roll_code,v_result,auth.uid(),v_ship.is_demo);
  UPDATE public.shipments SET needs_attention=true WHERE id=p_shipment_id;
  RETURN jsonb_build_object('result',v_result,'message','Roll is not part of this shipment');
 END IF;
 IF EXISTS(SELECT 1 FROM public.shipment_rolls WHERE id=v_sr AND status='SCANNED') THEN
  INSERT INTO public.shipment_scan_events(shipment_id,roll_code,result,scanned_by,is_demo) VALUES(p_shipment_id,p_roll_code,'DUPLICATE',auth.uid(),v_ship.is_demo);
  RETURN jsonb_build_object('result','DUPLICATE','roll_code',p_roll_code);
 END IF;
 UPDATE public.shipment_rolls SET status='SCANNED',scanned_at=now() WHERE id=v_sr;
 INSERT INTO public.shipment_scan_events(shipment_id,roll_code,result,scanned_by,is_demo) VALUES(p_shipment_id,p_roll_code,'MATCHED',auth.uid(),v_ship.is_demo);
 SELECT count(*) INTO v_scanned FROM public.shipment_rolls WHERE shipment_id=p_shipment_id AND status='SCANNED';
 UPDATE public.shipments SET manifest_scanned_count=v_scanned,needs_attention=(v_scanned<>manifest_expected_count) WHERE id=p_shipment_id;
 RETURN jsonb_build_object('result','MATCHED','roll_code',p_roll_code,'scanned_count',v_scanned,'expected_count',v_ship.manifest_expected_count);
END $$;
