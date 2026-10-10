CREATE OR REPLACE FUNCTION public.rpc_complete_rework(p_rework_id uuid,p_notes text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_rw public.rework_orders%ROWTYPE; v_roll public.fabric_rolls%ROWTYPE; v_wip uuid; v_from public.roll_status;
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
 v_from:=v_roll.status;
 IF v_roll.status='REWORK_REQUIRED' THEN
  PERFORM set_config('app.allow_roll_state','on',true);
  UPDATE public.fabric_rolls SET status='REWORK_IN_PROGRESS',version=version+1 WHERE id=v_roll.id;
  INSERT INTO public.roll_status_history(roll_id,from_status,to_status,reason,actor,is_demo) VALUES(v_roll.id,'REWORK_REQUIRED','REWORK_IN_PROGRESS','Rework performed: '||COALESCE(p_notes,''),auth.uid(),v_roll.is_demo);
 END IF;
 PERFORM set_config('app.allow_roll_state','on',true);
 UPDATE public.fabric_rolls SET status='REINSPECTION_REQUIRED',version=version+1,hold_reason=NULL WHERE id=v_roll.id;
 UPDATE public.rework_orders SET status='COMPLETED',completed_at=now(),notes=concat_ws(E'\n',notes,p_notes) WHERE id=p_rework_id;
 INSERT INTO public.roll_status_history(roll_id,from_status,to_status,reason,actor,is_demo) VALUES(v_roll.id,'REWORK_IN_PROGRESS','REINSPECTION_REQUIRED',COALESCE(p_notes,'Rework complete; QC reinspection required'),auth.uid(),v_roll.is_demo);
 RETURN jsonb_build_object('rework_id',p_rework_id,'roll_id',v_roll.id,'status','COMPLETED','next_action','REINSPECTION_REQUIRED');
END $$;
