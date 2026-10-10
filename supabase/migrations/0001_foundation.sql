-- Phase 1: identity, permission model, platform settings, audit and protected RPCs.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$ BEGIN CREATE TYPE public.user_status AS ENUM ('PENDING_APPROVAL','ACTIVE','DISABLED','REJECTED'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE public.approval_status AS ENUM ('PENDING','APPROVED','REJECTED','CHANGES_REQUESTED','CANCELLED'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version text PRIMARY KEY,
  name text NOT NULL,
  checksum text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.departments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), code text NOT NULL UNIQUE, name text NOT NULL,
  is_active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.employees (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), employee_code text NOT NULL UNIQUE, full_name text NOT NULL,
  department_id uuid REFERENCES public.departments(id), designation text NOT NULL DEFAULT '',
  employment_status text NOT NULL DEFAULT 'ACTIVE' CHECK (employment_status IN ('ACTIVE','ON_LEAVE','SUSPENDED','LEFT')),
  default_shift_id uuid, phone text, joined_on date, badge_qr_token text UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.buyers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), buyer_code text NOT NULL UNIQUE, name text NOT NULL,
  contact_name text, email text, phone text, address text, currency text NOT NULL DEFAULT 'INR', credit_days integer NOT NULL DEFAULT 0 CHECK (credit_days >= 0),
  is_active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE, email text NOT NULL,
  full_name text NOT NULL DEFAULT '', phone text, status public.user_status NOT NULL DEFAULT 'PENDING_APPROVAL',
  employee_id uuid REFERENCES public.employees(id), buyer_id uuid REFERENCES public.buyers(id), requested_role text,
  mfa_required boolean NOT NULL DEFAULT false, last_login_at timestamptz, approved_by uuid REFERENCES public.profiles(id), approved_at timestamptz,
  rejection_reason text, notification_prefs jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (buyer_id IS NULL OR employee_id IS NULL)
);
CREATE TABLE IF NOT EXISTS public.roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), key text NOT NULL UNIQUE, name text NOT NULL, description text NOT NULL DEFAULT '', is_system boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.permissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), key text NOT NULL UNIQUE, module text NOT NULL, description text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.user_roles (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE, role_id uuid NOT NULL REFERENCES public.roles(id),
  assigned_by uuid REFERENCES public.profiles(id), assigned_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(user_id, role_id)
);
CREATE TABLE IF NOT EXISTS public.role_permissions (
  role_id uuid NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE, permission_id uuid NOT NULL REFERENCES public.permissions(id) ON DELETE CASCADE,
  PRIMARY KEY(role_id, permission_id)
);
CREATE TABLE IF NOT EXISTS public.buyer_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), code text NOT NULL UNIQUE, buyer_id uuid NOT NULL REFERENCES public.buyers(id),
  expires_at timestamptz NOT NULL, used_by uuid REFERENCES public.profiles(id), used_at timestamptz, created_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.login_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), email text NOT NULL, ip text, success boolean NOT NULL, reason text, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS login_attempts_lockout_idx ON public.login_attempts(lower(email), ip, created_at DESC) WHERE success = false;
CREATE TABLE IF NOT EXISTS public.system_settings (
  key text PRIMARY KEY, value jsonb NOT NULL, description text NOT NULL DEFAULT '', updated_by uuid REFERENCES public.profiles(id), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.document_sequences (
  prefix text NOT NULL, year integer NOT NULL, last_value bigint NOT NULL DEFAULT 0 CHECK (last_value >= 0), PRIMARY KEY(prefix,year)
);
CREATE TABLE IF NOT EXISTS public.idempotency_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), scope text NOT NULL, key uuid NOT NULL, user_id uuid REFERENCES public.profiles(id),
  response jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(scope,key)
);
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), actor_user_id uuid REFERENCES public.profiles(id), actor_role text, action text NOT NULL,
  entity_type text NOT NULL, entity_id uuid, before_json jsonb, after_json jsonb, reason text, request_id text, ip inet,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS audit_logs_created_idx ON public.audit_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS audit_logs_entity_idx ON public.audit_logs(entity_type,entity_id,created_at DESC);
CREATE INDEX IF NOT EXISTS audit_logs_actor_idx ON public.audit_logs(actor_user_id,created_at DESC);

CREATE OR REPLACE FUNCTION public.set_updated_at() RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$ BEGIN NEW.updated_at := now(); RETURN NEW; END $$;
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['departments','employees','buyers','profiles','roles','system_settings'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS set_updated_at ON public.%I', t);
    EXECUTE format('CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()', t);
  END LOOP;
END $$;
CREATE OR REPLACE FUNCTION public.prevent_update_delete() RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: APPEND_ONLY'; END $$;
DROP TRIGGER IF EXISTS audit_logs_append_only ON public.audit_logs;
CREATE TRIGGER audit_logs_append_only BEFORE UPDATE OR DELETE ON public.audit_logs FOR EACH ROW EXECUTE FUNCTION public.prevent_update_delete();
DROP TRIGGER IF EXISTS login_attempts_append_only ON public.login_attempts;
CREATE TRIGGER login_attempts_append_only BEFORE UPDATE OR DELETE ON public.login_attempts FOR EACH ROW EXECUTE FUNCTION public.prevent_update_delete();

CREATE OR REPLACE FUNCTION private.is_active_user() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.status = 'ACTIVE')
$$;
CREATE OR REPLACE FUNCTION private.has_permission(p_permission text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT private.is_active_user() AND EXISTS (
    SELECT 1 FROM public.user_roles ur JOIN public.role_permissions rp ON rp.role_id=ur.role_id
    JOIN public.permissions pm ON pm.id=rp.permission_id
    WHERE ur.user_id=auth.uid() AND pm.key=p_permission
  )
$$;
CREATE OR REPLACE FUNCTION private.has_any_permission(p_permissions text[]) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT private.is_active_user() AND EXISTS (
    SELECT 1 FROM public.user_roles ur JOIN public.role_permissions rp ON rp.role_id=ur.role_id
    JOIN public.permissions pm ON pm.id=rp.permission_id
    WHERE ur.user_id=auth.uid() AND pm.key=ANY(p_permissions)
  )
$$;
CREATE OR REPLACE FUNCTION private.current_buyer_id() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT buyer_id FROM public.profiles WHERE id=auth.uid() AND status='ACTIVE'
$$;
CREATE OR REPLACE FUNCTION private.current_employee_id() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT employee_id FROM public.profiles WHERE id=auth.uid() AND status='ACTIVE'
$$;
CREATE OR REPLACE FUNCTION private.assert_permission(p_permission text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: AUTH_REQUIRED'; END IF;
  IF NOT private.is_active_user() THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: USER_NOT_ACTIVE'; END IF;
  IF NOT private.has_permission(p_permission) THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: PERMISSION_DENIED'; END IF;
END $$;
CREATE OR REPLACE FUNCTION private.next_doc_no(p_prefix text) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_year integer; v_number bigint; v_tz text;
BEGIN
  SELECT COALESCE(value #>> '{}','Asia/Kolkata') INTO v_tz FROM public.system_settings WHERE key='app_timezone';
  v_tz := COALESCE(v_tz,'Asia/Kolkata'); v_year := extract(year FROM (now() AT TIME ZONE v_tz))::integer;
  INSERT INTO public.document_sequences(prefix,year,last_value) VALUES(p_prefix,v_year,1)
  ON CONFLICT(prefix,year) DO UPDATE SET last_value=public.document_sequences.last_value+1
  RETURNING last_value INTO v_number;
  RETURN p_prefix || '-' || v_year::text || '-' || lpad(v_number::text,4,'0');
END $$;

INSERT INTO public.system_settings(key,value,description) VALUES
('app_timezone','"Asia/Kolkata"','Application timezone'),('currency','"INR"','Default currency'),('date_format','"DD-MMM-YYYY"','Date display format'),('week_start','"Monday"','Week start day'),
('over_delivery_pct','0','Allowed order over-delivery percentage'),('idle_timeout_privileged_min','30','Privileged-role idle timeout'),('idle_timeout_shop_floor_min','480','Shop-floor idle timeout'),
('downtime_alert_min','30','Downtime alert threshold'),('inspection_alert_hours','4','Awaiting inspection alert'),('rework_rate_alert_pct','8','Rework alert threshold'),('cost_variance_alert_pct','10','Cost variance alert threshold'),('receipt_variance_pct','2','Receipt variance threshold'),('exception_escalation_min','60','Exception escalation threshold'),
('standard_roll_length_m','50','Standard roll length'),('skills_enforced','false','Whether missing worker skills block assignment'),('reconciliation_tolerance_pct','1.0','Operation reconciliation tolerance'),('pause_alert_hours','4','Paused operation alert'),('reversal_requires_reinspection','true','Require reinspection after dispatch reversal'),('rolls.split_merge','false','Roll splitting/merging feature flag'),
('sod.stock_adjustment','true','Requester must differ from stock adjustment approver'),('sod.quality_override','true','Quality override separation of duties'),('sod.plan_override','true','Plan override separation of duties'),('sod.dispatch_reversal','true','Dispatch reversal separation of duties'),('sod.payroll_approval','true','Payroll calculator differs from approver'),('sod.expense_approval','true','Expense submitter differs from approver'),('sod.cost_entry_above_threshold','true','Threshold cost entry approval'),('sod.role_change','true','Role change separation of duties')
ON CONFLICT(key) DO NOTHING;

INSERT INTO public.roles(key,name,description) VALUES
('system_admin','System administrator','Identity, configuration, audit, and integration administration; no automatic business-write access'),
('factory_manager','Factory manager','Factory-wide operations, order and exception oversight'),('production_supervisor','Production supervisor','Shift and production execution'),('machine_operator','Machine operator','Assigned machine and operation work only'),('storekeeper','Storekeeper','Raw-material stores and inventory operations'),('quality_inspector','Quality inspector','Inspection, quarantine, release, and quality incidents'),('dispatch_officer','Dispatch officer','Shipment allocation, manifest, and confirmation'),('hr_payroll_officer','HR and payroll officer','Attendance and example payroll workflows'),('finance_officer','Finance officer','Costing, finance and approvals'),('buyer','Buyer','External buyer portal only')
ON CONFLICT(key) DO NOTHING;
INSERT INTO public.permissions(key,module,description) VALUES
('users.manage','users','Manage accounts'),('users.approve','users','Approve or reject onboarding'),('roles.manage','roles','Manage role assignments and permissions'),('settings.manage','settings','Manage system settings'),('audit.read','audit','Read audit trail'),('integrations.manage','integrations','Manage integrations and retries'),('automations.manage','automations','Manage automation rules'),
('master.read','master','Read master data'),('master.manage','master','Manage master data'),('orders.read','orders','Read orders'),('orders.create','orders','Create orders'),('orders.update','orders','Update orders'),('orders.confirm','orders','Confirm orders'),('orders.approve','orders','Approve orders'),('orders.cancel','orders','Cancel orders'),('orders.override_feasibility','orders','Override feasibility'),
('plans.create','plans','Create plans'),('plans.release','plans','Release plans'),('plans.override','plans','Override plan constraints'),('inventory.read','inventory','Read inventory'),('inventory.receive','inventory','Receive stock'),('inventory.reserve','inventory','Reserve stock'),('inventory.issue','inventory','Issue stock'),('inventory.transfer','inventory','Transfer stock'),('inventory.count','inventory','Count stock'),('inventory.adjust_request','inventory','Request inventory adjustment'),('inventory.adjust_approve','inventory','Approve inventory adjustment'),('inventory.quarantine','inventory','Quarantine stock'),('inventory.release_quarantine','inventory','Release quarantined stock'),
('purchasing.read','purchasing','Read purchasing'),('purchasing.draft','purchasing','Draft purchase requests'),('purchasing.approve','purchasing','Approve purchase commitments'),('production.read','production','Read production'),('production.assign','production','Assign production operations'),('production.operate','production','Operate assigned jobs'),('production.record_output','production','Record output'),('production.correct_output','production','Correct output with reason'),('production.close_shift','production','Close shift'),('production.handover','production','Submit or acknowledge handover'),
('machines.read','machines','Read machine status'),('machines.status','machines','Change permitted machine status'),('machines.downtime','machines','Record downtime'),('maintenance.manage','maintenance','Manage maintenance work'),('maintenance.approve','maintenance','Approve maintenance windows'),('rolls.read','rolls','Read roll passports'),('rolls.move','rolls','Move rolls'),('quality.read','quality','Read quality records'),('quality.inspect','quality','Record inspection'),('quality.release','quality','Release quality holds'),('quality.reject','quality','Reject quality'),('quality.quarantine','quality','Quarantine quality records'),('quality.override','quality','Override quality gate'),('quality.incident','quality','Manage quality incidents'),('quality.plans_manage','quality','Manage inspection plans'),
('dispatch.read','dispatch','Read dispatch'),('dispatch.create','dispatch','Create shipments'),('dispatch.allocate','dispatch','Allocate eligible rolls'),('dispatch.confirm','dispatch','Confirm dispatch'),('dispatch.reverse','dispatch','Request dispatch reversal'),('dispatch.approve_reversal','dispatch','Approve dispatch reversal'),
('hr.read','hr','Read HR records'),('attendance.record','attendance','Record attendance'),('attendance.approve','attendance','Approve attendance'),('payroll.read','payroll','Read payroll'),('payroll.calculate','payroll','Calculate example payroll'),('payroll.approve','payroll','Approve payroll'),('compensation.read','compensation','Read compensation'),('finance.read','finance','Read finance and cost data'),('finance.cost_entry','finance','Enter costs'),('finance.approve','finance','Approve finance actions'),('expenses.submit','expenses','Submit expenses'),('expenses.approve','expenses','Approve expenses'),('reports.read','reports','Read reports'),('reports.export','reports','Export reports'),('reports.financial_export','reports','Export finance reports'),('tasks.manage','tasks','Manage tasks'),('approvals.decide','approvals','Decide approval requests'),('dashboard.manager','dashboard','Manager dashboard'),('dashboard.floor','dashboard','Shop-floor dashboard'),('assistant.use','assistant','Use guardrailed assistant'),('buyer.portal','buyer','Use buyer portal')
ON CONFLICT(key) DO NOTHING;

WITH role_map(role_key, perm_keys) AS (VALUES
('system_admin',ARRAY['users.manage','users.approve','roles.manage','settings.manage','audit.read','integrations.manage','automations.manage','master.read','master.manage','reports.read','dashboard.manager','assistant.use']),
('factory_manager',ARRAY['master.read','orders.read','orders.create','orders.update','orders.confirm','orders.approve','orders.cancel','orders.override_feasibility','plans.create','plans.release','plans.override','inventory.read','inventory.adjust_approve','inventory.release_quarantine','purchasing.read','purchasing.approve','production.read','production.assign','production.correct_output','machines.read','maintenance.approve','rolls.read','quality.read','quality.override','quality.incident','dispatch.read','dispatch.approve_reversal','finance.read','hr.read','reports.read','reports.export','tasks.manage','approvals.decide','dashboard.manager','assistant.use']),
('production_supervisor',ARRAY['master.read','orders.read','plans.create','production.read','production.assign','production.operate','production.record_output','production.correct_output','production.close_shift','production.handover','machines.read','machines.status','machines.downtime','maintenance.manage','inventory.read','inventory.issue','rolls.read','rolls.move','quality.read','tasks.manage','dashboard.floor','assistant.use']),
('machine_operator',ARRAY['production.read','production.operate','production.record_output','machines.read','machines.status','machines.downtime','rolls.read','dashboard.floor']),
('storekeeper',ARRAY['master.read','inventory.read','inventory.receive','inventory.reserve','inventory.issue','inventory.transfer','inventory.count','inventory.adjust_request','inventory.quarantine','purchasing.read','purchasing.draft','rolls.read','rolls.move','dashboard.floor','tasks.manage']),
('quality_inspector',ARRAY['master.read','quality.read','quality.inspect','quality.release','quality.reject','quality.quarantine','quality.incident','quality.plans_manage','rolls.read','rolls.move','inventory.quarantine','inventory.release_quarantine','dashboard.floor','assistant.use']),
('dispatch_officer',ARRAY['master.read','orders.read','dispatch.read','dispatch.create','dispatch.allocate','dispatch.confirm','rolls.read','rolls.move','dashboard.floor']),
('hr_payroll_officer',ARRAY['hr.read','attendance.record','attendance.approve','payroll.read','payroll.calculate','compensation.read','expenses.submit','master.read','reports.read']),
('finance_officer',ARRAY['finance.read','finance.cost_entry','finance.approve','expenses.approve','purchasing.read','purchasing.approve','payroll.read','orders.read','reports.read','reports.export','reports.financial_export','approvals.decide']),
('buyer',ARRAY['buyer.portal'])
)
INSERT INTO public.role_permissions(role_id,permission_id)
SELECT r.id,p.id FROM role_map m JOIN public.roles r ON r.key=m.role_key CROSS JOIN LATERAL unnest(m.perm_keys) AS x(perm_key) JOIN public.permissions p ON p.key=x.perm_key
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.handle_new_auth_user() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_buyer uuid; v_invite text; v_kind text;
BEGIN
  v_kind := COALESCE(NEW.raw_user_meta_data->>'account_type','staff');
  v_invite := NEW.raw_user_meta_data->>'buyer_invite_code';
  IF v_kind='buyer' THEN
    SELECT bi.buyer_id INTO v_buyer FROM public.buyer_invites bi WHERE bi.code=v_invite AND bi.used_by IS NULL AND bi.expires_at>now() FOR UPDATE;
    IF v_buyer IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: INVALID_BUYER_INVITE'; END IF;
  END IF;
  INSERT INTO public.profiles(id,email,full_name,phone,status,buyer_id,requested_role)
  VALUES(NEW.id,lower(NEW.email),COALESCE(NEW.raw_user_meta_data->>'full_name',''),NEW.raw_user_meta_data->>'phone','PENDING_APPROVAL',v_buyer,NEW.raw_user_meta_data->>'requested_role');
  IF v_buyer IS NOT NULL THEN UPDATE public.buyer_invites SET used_by=NEW.id,used_at=now() WHERE code=v_invite; END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

CREATE OR REPLACE FUNCTION public.rpc_session_bootstrap() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p public.profiles%ROWTYPE; v_roles jsonb; v_perms jsonb; v_settings jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: AUTH_REQUIRED'; END IF;
  SELECT * INTO p FROM public.profiles WHERE id=auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: PROFILE_NOT_FOUND'; END IF;
  SELECT COALESCE(jsonb_agg(r.key ORDER BY r.key),'[]'::jsonb) INTO v_roles FROM public.user_roles ur JOIN public.roles r ON r.id=ur.role_id WHERE ur.user_id=auth.uid();
  SELECT COALESCE(jsonb_agg(DISTINCT pm.key ORDER BY pm.key),'[]'::jsonb) INTO v_perms FROM public.user_roles ur JOIN public.role_permissions rp ON rp.role_id=ur.role_id JOIN public.permissions pm ON pm.id=rp.permission_id WHERE ur.user_id=auth.uid() AND p.status='ACTIVE';
  SELECT COALESCE(jsonb_object_agg(key,value),'{}'::jsonb) INTO v_settings FROM public.system_settings;
  RETURN jsonb_build_object('profile',jsonb_build_object('id',p.id,'email',p.email,'full_name',p.full_name,'phone',p.phone,'status',p.status,'employee_id',p.employee_id,'buyer_id',p.buyer_id,'mfa_required',p.mfa_required,'last_login_at',p.last_login_at),'roles',v_roles,'permissions',v_perms,'settings',v_settings);
END $$;

CREATE OR REPLACE FUNCTION public.rpc_admin_decide_user(p_user_id uuid,p_decision text,p_role_keys text[] DEFAULT '{}',p_employee_id uuid DEFAULT NULL,p_buyer_id uuid DEFAULT NULL,p_reason text DEFAULT NULL,p_idempotency_key uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_old jsonb; v_new jsonb; v_result jsonb; v_role text;
BEGIN
  PERFORM private.assert_permission('users.approve');
  IF p_idempotency_key IS NOT NULL THEN SELECT response INTO v_result FROM public.idempotency_keys WHERE scope='admin_decide_user' AND key=p_idempotency_key; IF FOUND THEN RETURN v_result; END IF; END IF;
  IF p_decision NOT IN ('approve','reject') THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: INVALID_DECISION'; END IF;
  IF p_decision='reject' AND length(trim(COALESCE(p_reason,'')))<10 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: REASON_REQUIRED'; END IF;
  SELECT to_jsonb(p) INTO v_old FROM public.profiles p WHERE p.id=p_user_id FOR UPDATE;
  IF v_old IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: NOT_FOUND'; END IF;
  IF p_decision='approve' THEN
    IF cardinality(p_role_keys)=0 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: ROLE_REQUIRED'; END IF;
    IF 'buyer'=ANY(p_role_keys) THEN
      IF cardinality(p_role_keys)<>1 OR p_buyer_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: BUYER_SCOPE_REQUIRED'; END IF;
      UPDATE public.profiles SET status='ACTIVE',buyer_id=p_buyer_id,employee_id=NULL,approved_by=auth.uid(),approved_at=now(),rejection_reason=NULL WHERE id=p_user_id;
    ELSE
      IF p_employee_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: EMPLOYEE_LINK_REQUIRED'; END IF;
      UPDATE public.profiles SET status='ACTIVE',employee_id=p_employee_id,buyer_id=NULL,approved_by=auth.uid(),approved_at=now(),rejection_reason=NULL WHERE id=p_user_id;
    END IF;
    DELETE FROM public.user_roles WHERE user_id=p_user_id;
    FOREACH v_role IN ARRAY p_role_keys LOOP
      IF NOT EXISTS(SELECT 1 FROM public.roles WHERE key=v_role) THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: UNKNOWN_ROLE'; END IF;
      INSERT INTO public.user_roles(user_id,role_id,assigned_by) SELECT p_user_id,id,auth.uid() FROM public.roles WHERE key=v_role;
    END LOOP;
  ELSE
    UPDATE public.profiles SET status='REJECTED',rejection_reason=p_reason,approved_by=auth.uid(),approved_at=now() WHERE id=p_user_id;
  END IF;
  SELECT to_jsonb(p) INTO v_new FROM public.profiles p WHERE p.id=p_user_id;
  INSERT INTO public.audit_logs(actor_user_id,actor_role,action,entity_type,entity_id,before_json,after_json,reason) SELECT auth.uid(),r.key,'USER_'||upper(p_decision),'profiles',p_user_id,v_old,v_new,p_reason FROM public.user_roles ur JOIN public.roles r ON r.id=ur.role_id WHERE ur.user_id=auth.uid() ORDER BY r.key LIMIT 1;
  v_result:=jsonb_build_object('user_id',p_user_id,'status',CASE WHEN p_decision='approve' THEN 'ACTIVE' ELSE 'REJECTED' END,'roles',to_jsonb(p_role_keys));
  IF p_idempotency_key IS NOT NULL THEN INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('admin_decide_user',p_idempotency_key,auth.uid(),v_result) ON CONFLICT(scope,key) DO NOTHING; END IF;
  RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_admin_set_user_status(p_user_id uuid,p_status public.user_status,p_reason text DEFAULT NULL,p_idempotency_key uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_old jsonb; v_new jsonb; v_admins integer; v_result jsonb;
BEGIN
  PERFORM private.assert_permission('users.manage');
  IF p_status NOT IN ('ACTIVE','DISABLED','REJECTED') THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: INVALID_USER_STATUS'; END IF;
  IF p_status IN ('DISABLED','REJECTED') AND length(trim(COALESCE(p_reason,'')))<10 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: REASON_REQUIRED'; END IF;
  SELECT to_jsonb(p) INTO v_old FROM public.profiles p WHERE p.id=p_user_id FOR UPDATE;
  IF v_old IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: NOT_FOUND'; END IF;
  IF v_old->>'status'='ACTIVE' AND p_status<>'ACTIVE' AND EXISTS(SELECT 1 FROM public.user_roles ur JOIN public.roles r ON r.id=ur.role_id WHERE ur.user_id=p_user_id AND r.key='system_admin') THEN
    SELECT count(DISTINCT p.id) INTO v_admins FROM public.profiles p JOIN public.user_roles ur ON ur.user_id=p.id JOIN public.roles r ON r.id=ur.role_id WHERE p.status='ACTIVE' AND r.key='system_admin';
    IF v_admins<=1 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: LAST_ADMIN_PROTECTED'; END IF;
  END IF;
  UPDATE public.profiles SET status=p_status,rejection_reason=CASE WHEN p_status='REJECTED' THEN p_reason ELSE NULL END WHERE id=p_user_id;
  SELECT to_jsonb(p) INTO v_new FROM public.profiles p WHERE p.id=p_user_id;
  INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,before_json,after_json,reason) VALUES(auth.uid(),'USER_STATUS_CHANGED','profiles',p_user_id,v_old,v_new,p_reason);
  v_result:=jsonb_build_object('user_id',p_user_id,'status',p_status);
  IF p_idempotency_key IS NOT NULL THEN INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('admin_set_status',p_idempotency_key,auth.uid(),v_result) ON CONFLICT(scope,key) DO NOTHING; END IF;
  RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_admin_set_roles(p_user_id uuid,p_role_keys text[],p_reason text,p_idempotency_key uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_old jsonb; v_new jsonb; v_admins integer; v_role text; v_result jsonb;
BEGIN
  PERFORM private.assert_permission('roles.manage');
  IF cardinality(p_role_keys)=0 OR length(trim(COALESCE(p_reason,'')))<10 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: REASON_REQUIRED'; END IF;
  SELECT COALESCE(jsonb_agg(r.key ORDER BY r.key),'[]'::jsonb) INTO v_old FROM public.user_roles ur JOIN public.roles r ON r.id=ur.role_id WHERE ur.user_id=p_user_id;
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=p_user_id FOR UPDATE) THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: NOT_FOUND'; END IF;
  IF p_user_id=auth.uid() THEN
    SELECT count(DISTINCT p.id) INTO v_admins FROM public.profiles p JOIN public.user_roles ur ON ur.user_id=p.id JOIN public.roles r ON r.id=ur.role_id WHERE p.status='ACTIVE' AND r.key='system_admin';
    IF v_admins>1 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: SEPARATION_OF_DUTIES'; END IF;
  END IF;
  DELETE FROM public.user_roles WHERE user_id=p_user_id;
  FOREACH v_role IN ARRAY p_role_keys LOOP
    IF NOT EXISTS(SELECT 1 FROM public.roles WHERE key=v_role) THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: UNKNOWN_ROLE'; END IF;
    INSERT INTO public.user_roles(user_id,role_id,assigned_by) SELECT p_user_id,id,auth.uid() FROM public.roles WHERE key=v_role;
  END LOOP;
  SELECT COALESCE(jsonb_agg(r.key ORDER BY r.key),'[]'::jsonb) INTO v_new FROM public.user_roles ur JOIN public.roles r ON r.id=ur.role_id WHERE ur.user_id=p_user_id;
  INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,before_json,after_json,reason) VALUES(auth.uid(),'USER_ROLES_CHANGED','profiles',p_user_id,v_old,v_new,p_reason);
  v_result:=jsonb_build_object('user_id',p_user_id,'roles',v_new);
  IF p_idempotency_key IS NOT NULL THEN INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('admin_set_roles',p_idempotency_key,auth.uid(),v_result) ON CONFLICT(scope,key) DO NOTHING; END IF;
  RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_log_logout() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('ok',true); END IF;
  INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id) VALUES(auth.uid(),'LOGOUT','profiles',auth.uid());
  RETURN jsonb_build_object('ok',true);
END $$;

CREATE OR REPLACE FUNCTION public.rpc_validate_buyer_invite(p_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_buyer uuid;
BEGIN
  SELECT buyer_id INTO v_buyer FROM public.buyer_invites WHERE code=p_code AND used_by IS NULL AND expires_at>now();
  IF v_buyer IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: INVALID_BUYER_INVITE'; END IF;
  RETURN jsonb_build_object('valid',true,'buyer_id',v_buyer);
END $$;

-- Default-deny RLS on every table created by this migration.
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['schema_migrations','departments','employees','buyers','profiles','roles','permissions','user_roles','role_permissions','buyer_invites','login_attempts','system_settings','document_sequences','idempotency_keys','audit_logs'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
  END LOOP;
END $$;
CREATE POLICY schema_migrations_admin_select ON public.schema_migrations FOR SELECT TO authenticated USING (private.has_permission('settings.manage'));
CREATE POLICY departments_read ON public.departments FOR SELECT TO authenticated USING (private.has_permission('master.read'));
CREATE POLICY departments_manage ON public.departments FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY employees_read ON public.employees FOR SELECT TO authenticated USING (private.has_any_permission(ARRAY['master.read','hr.read']));
CREATE POLICY employees_manage ON public.employees FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY buyers_read ON public.buyers FOR SELECT TO authenticated USING (private.has_permission('master.read'));
CREATE POLICY buyers_manage ON public.buyers FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY profiles_own_read ON public.profiles FOR SELECT TO authenticated USING (id=auth.uid() AND status='ACTIVE');
CREATE POLICY profiles_admin_read ON public.profiles FOR SELECT TO authenticated USING (private.has_permission('users.manage'));
CREATE POLICY roles_admin_read ON public.roles FOR SELECT TO authenticated USING (private.has_permission('roles.manage'));
CREATE POLICY permissions_admin_read ON public.permissions FOR SELECT TO authenticated USING (private.has_permission('roles.manage'));
CREATE POLICY user_roles_admin_read ON public.user_roles FOR SELECT TO authenticated USING (private.has_permission('roles.manage') OR user_id=auth.uid());
CREATE POLICY role_permissions_admin_read ON public.role_permissions FOR SELECT TO authenticated USING (private.has_permission('roles.manage'));
CREATE POLICY buyer_invites_admin_read ON public.buyer_invites FOR SELECT TO authenticated USING (private.has_permission('users.manage'));
CREATE POLICY system_settings_admin_read ON public.system_settings FOR SELECT TO authenticated USING (private.has_permission('settings.manage'));
CREATE POLICY audit_admin_read ON public.audit_logs FOR SELECT TO authenticated USING (private.has_permission('audit.read'));

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
GRANT SELECT ON public.departments,public.employees,public.buyers,public.profiles,public.roles,public.permissions,public.user_roles,public.role_permissions,public.buyer_invites,public.system_settings,public.audit_logs,public.schema_migrations TO authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.departments,public.employees,public.buyers TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_session_bootstrap(),public.rpc_admin_decide_user(uuid,text,text[],uuid,uuid,text,uuid),public.rpc_admin_set_user_status(uuid,public.user_status,text,uuid),public.rpc_admin_set_roles(uuid,text[],text,uuid),public.rpc_log_logout(),public.rpc_validate_buyer_invite(text) TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_active_user(),private.has_permission(text),private.has_any_permission(text[]),private.current_buyer_id(),private.current_employee_id(),private.assert_permission(text),private.next_doc_no(text) TO authenticated,service_role;
GRANT USAGE,SELECT,UPDATE ON ALL SEQUENCES IN SCHEMA public TO authenticated,service_role;
