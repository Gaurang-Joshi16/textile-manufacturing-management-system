-- Secure default PostgreSQL function privileges and deny API access to internal helpers.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA private REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.rpc_session_bootstrap() TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_decide_user(uuid,text,text[],uuid,uuid,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_set_user_status(uuid,public.user_status,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_set_roles(uuid,text[],text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_log_logout() TO authenticated;
-- Invite validation is intentionally available before authentication and returns only a valid invite's buyer scope.
GRANT EXECUTE ON FUNCTION public.rpc_validate_buyer_invite(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION private.is_active_user(),private.has_permission(text),private.has_any_permission(text[]),private.current_buyer_id(),private.current_employee_id() TO authenticated,service_role;
