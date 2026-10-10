-- RLS protects rows; function ACLs also need explicit least privilege.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC,anon,authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA private REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC,anon,authenticated;
DO $$ DECLARE r record; BEGIN
 FOR r IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname LIKE 'rpc_%' LOOP
   EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC,anon,authenticated',r.signature);
 END LOOP;
END $$;
GRANT EXECUTE ON FUNCTION public.rpc_session_bootstrap(),public.rpc_admin_decide_user(uuid,text,text[],uuid,uuid,text,uuid),public.rpc_admin_set_user_status(uuid,public.user_status,text,uuid),public.rpc_admin_set_roles(uuid,text[],text,uuid),public.rpc_log_logout() TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_validate_buyer_invite(text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_post_receipt(uuid,uuid,text,jsonb,uuid),public.rpc_reserve_material(uuid,numeric,text,uuid,uuid,uuid),public.rpc_release_reservation(uuid,text),public.rpc_issue_material(uuid,numeric,uuid),public.rpc_request_adjustment(uuid,uuid,numeric,text),public.rpc_decide_adjustment(uuid,text,text),public.rpc_buyer_list_orders(),public.rpc_buyer_order_timeline(uuid) TO authenticated;
