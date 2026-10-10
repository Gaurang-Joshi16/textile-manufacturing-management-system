-- Pending accounts need a status-only bootstrap screen. Disabled/rejected accounts are denied.
CREATE OR REPLACE FUNCTION public.rpc_session_bootstrap() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p public.profiles%ROWTYPE; v_roles jsonb; v_perms jsonb; v_settings jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: AUTH_REQUIRED'; END IF;
  SELECT * INTO p FROM public.profiles WHERE id=auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: PROFILE_NOT_FOUND'; END IF;
  IF p.status IN ('DISABLED','REJECTED') THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: USER_NOT_ACTIVE'; END IF;
  SELECT COALESCE(jsonb_agg(r.key ORDER BY r.key),'[]'::jsonb) INTO v_roles FROM public.user_roles ur JOIN public.roles r ON r.id=ur.role_id WHERE ur.user_id=auth.uid() AND p.status='ACTIVE';
  SELECT COALESCE(jsonb_agg(DISTINCT pm.key ORDER BY pm.key),'[]'::jsonb) INTO v_perms FROM public.user_roles ur JOIN public.role_permissions rp ON rp.role_id=ur.role_id JOIN public.permissions pm ON pm.id=rp.permission_id WHERE ur.user_id=auth.uid() AND p.status='ACTIVE';
  SELECT COALESCE(jsonb_object_agg(key,value),'{}'::jsonb) INTO v_settings FROM public.system_settings;
  RETURN jsonb_build_object('profile',jsonb_build_object('id',p.id,'email',p.email,'full_name',p.full_name,'phone',p.phone,'status',p.status,'employee_id',p.employee_id,'buyer_id',p.buyer_id,'mfa_required',p.mfa_required,'last_login_at',p.last_login_at),'roles',v_roles,'permissions',v_perms,'settings',v_settings);
END $$;
REVOKE EXECUTE ON FUNCTION public.rpc_session_bootstrap() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rpc_session_bootstrap() TO authenticated;
