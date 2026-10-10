DO $$
DECLARE v_missing text[]; v_bad text[]; v_count integer;
BEGIN
 SELECT array_agg(c.relname ORDER BY c.relname) INTO v_missing FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND NOT c.relrowsecurity;
 IF v_missing IS NOT NULL THEN RAISE EXCEPTION 'RLS disabled on public tables: %',v_missing; END IF;
 IF NOT has_table_privilege('anon','public.buyer_orders','SELECT')=false THEN RAISE EXCEPTION 'anon can read buyer_orders'; END IF;
 IF NOT has_table_privilege('anon','public.buyer_order_lines','SELECT')=false THEN RAISE EXCEPTION 'anon can read order lines'; END IF;
 IF EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='buyer_order_lines' AND roles @> ARRAY['authenticated']::name[] AND coalesce(qual,'') ILIKE '%current_buyer_id%') THEN RAISE EXCEPTION 'Buyer direct SELECT policy exists on priced order lines'; END IF;
 IF has_function_privilege('anon','public.rpc_buyer_list_orders()','EXECUTE') THEN RAISE EXCEPTION 'anon can execute authenticated buyer RPC'; END IF;
 IF NOT has_function_privilege('authenticated','public.rpc_buyer_list_orders()','EXECUTE') THEN RAISE EXCEPTION 'authenticated buyer RPC is not executable'; END IF;
 IF has_table_privilege('anon','public.v_yarn_stock','SELECT') THEN RAISE EXCEPTION 'anon can read stock view'; END IF;
 IF NOT has_table_privilege('authenticated','public.v_yarn_stock','SELECT') THEN RAISE EXCEPTION 'authenticated inventory view is not granted'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='public.v_yarn_stock'::regclass AND coalesce(array_to_string(reloptions,','),'') ILIKE '%security_invoker=true%') THEN RAISE EXCEPTION 'stock view does not enforce caller RLS'; END IF;
 SELECT count(*) INTO v_count FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r';
 SELECT array_agg(expected.name) INTO v_missing FROM (VALUES ('buyer_orders'),('buyer_order_lines'),('production_plans'),('production_operations'),('production_outputs'),('fabric_rolls'),('quality_inspections'),('shipments'),('attendance_records'),('payroll_periods'),('exceptions'),('tasks'),('automation_rules'),('integration_events')) expected(name) WHERE to_regclass('public.'||expected.name) IS NULL;
 IF v_missing IS NOT NULL THEN RAISE EXCEPTION 'Required tables missing: %',v_missing; END IF;
 IF v_count<100 THEN RAISE EXCEPTION 'Unexpectedly low schema table count: %',v_count; END IF;
 SELECT array_agg(p.proname) INTO v_bad FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND (p.proname LIKE 'rpc_%' OR p.proname IN ('rpc_buyer_list_orders','rpc_buyer_order_timeline')) AND (NOT p.prosecdef OR NOT EXISTS(SELECT 1 FROM unnest(p.proconfig) cfg WHERE cfg LIKE 'search_path=%'));
 IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'RPCs missing SECURITY DEFINER/search_path: %',v_bad; END IF;
END $$;
