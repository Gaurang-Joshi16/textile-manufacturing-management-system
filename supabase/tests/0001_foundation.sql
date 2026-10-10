-- Run as database owner after 0001_foundation.sql and 0002_security_hardening.sql.
DO $$
DECLARE v_missing text[]; v_bad integer;
BEGIN
 SELECT array_agg(c.relname) INTO v_missing
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relkind='r' AND c.relname IN
 ('schema_migrations','departments','employees','buyers','profiles','roles','permissions','user_roles','role_permissions','buyer_invites','login_attempts','system_settings','document_sequences','idempotency_keys','audit_logs')
 AND NOT c.relrowsecurity;
 IF v_missing IS NOT NULL THEN RAISE EXCEPTION 'RLS disabled on tables: %',v_missing; END IF;
 SELECT count(*) INTO v_bad FROM (VALUES
 ('system_admin',12),('factory_manager',34),('production_supervisor',22),('machine_operator',8),('storekeeper',15),('quality_inspector',14),('dispatch_officer',9),('hr_payroll_officer',9),('finance_officer',12),('buyer',1)
 ) expected(role_key,min_permissions) LEFT JOIN public.roles r ON r.key=expected.role_key LEFT JOIN public.role_permissions rp ON rp.role_id=r.id GROUP BY expected.role_key,expected.min_permissions HAVING count(rp.permission_id)<expected.min_permissions;
 IF v_bad>0 THEN RAISE EXCEPTION 'Role permission mapping incomplete for % role(s)',v_bad; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.roles WHERE key='system_admin') THEN RAISE EXCEPTION 'System administrator role missing'; END IF;
 IF EXISTS(SELECT 1 FROM public.role_permissions rp JOIN public.roles r ON r.id=rp.role_id JOIN public.permissions p ON p.id=rp.permission_id WHERE r.key='system_admin' AND p.key IN ('orders.create','orders.confirm','inventory.issue','quality.release','dispatch.confirm','payroll.approve','finance.cost_entry')) THEN RAISE EXCEPTION 'System admin has a forbidden business permission'; END IF;
 IF has_table_privilege('anon','public.profiles','SELECT') THEN RAISE EXCEPTION 'anon can select profiles'; END IF;
 IF has_table_privilege('authenticated','public.profiles','UPDATE') THEN RAISE EXCEPTION 'authenticated can update profile status directly'; END IF;
 IF has_table_privilege('authenticated','public.user_roles','INSERT') THEN RAISE EXCEPTION 'authenticated can insert roles directly'; END IF;
 IF has_function_privilege('anon','public.rpc_admin_set_user_status(uuid,public.user_status,text,uuid)','EXECUTE') THEN RAISE EXCEPTION 'anon can execute admin status RPC'; END IF;
 IF NOT has_function_privilege('anon','public.rpc_validate_buyer_invite(text)','EXECUTE') THEN RAISE EXCEPTION 'anon cannot validate buyer invites before sign-up'; END IF;
END $$;
