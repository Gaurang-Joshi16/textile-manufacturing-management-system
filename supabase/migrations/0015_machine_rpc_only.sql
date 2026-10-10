CREATE OR REPLACE FUNCTION public.enforce_controlled_transition() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_entity text; v_from text; v_to text;
BEGIN
 v_entity:=TG_ARGV[0]; v_from:=to_jsonb(OLD)->>TG_ARGV[1]; v_to:=to_jsonb(NEW)->>TG_ARGV[1];
 IF v_from IS NOT DISTINCT FROM v_to THEN RETURN NEW; END IF;
 IF v_entity='machine' AND current_setting('app.allow_machine_state',true) IS DISTINCT FROM 'on' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: STATE_CHANGE_RPC_ONLY'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.allowed_transitions WHERE entity=v_entity AND from_state=v_from AND to_state=v_to) THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='CODE: INVALID_STATE_TRANSITION'; END IF;
 RETURN NEW;
END $$;
