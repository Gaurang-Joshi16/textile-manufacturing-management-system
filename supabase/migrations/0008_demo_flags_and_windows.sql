-- Keep synthetic operational records separately identifiable and enforce machine-time exclusivity.
ALTER TYPE public.severity ADD VALUE IF NOT EXISTS 'MAJOR';
ALTER TABLE public.defect_categories DROP CONSTRAINT IF EXISTS defect_categories_default_severity_check;
ALTER TABLE public.defect_categories ADD CONSTRAINT defect_categories_default_severity_check CHECK(default_severity IN ('INFO','LOW','MEDIUM','MAJOR','HIGH','CRITICAL'));
ALTER TABLE public.employee_compensation ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;
ALTER TABLE public.operation_assignments ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;
ALTER TABLE public.operation_materials ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;
ALTER TABLE public.operation_wip_inputs ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;
ALTER TABLE public.plan_material_requirements ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;
ALTER TABLE public.roll_dye_lots ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;
ALTER TABLE public.buyer_invites ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;
CREATE EXTENSION IF NOT EXISTS btree_gist;
DO $$ BEGIN
 ALTER TABLE public.production_operations ADD CONSTRAINT machine_operation_time_excl EXCLUDE USING gist (machine_id WITH =, tstzrange(planned_start,planned_end,'[)') WITH &&) WHERE (machine_id IS NOT NULL AND planned_start IS NOT NULL AND planned_end IS NOT NULL AND status NOT IN ('CANCELLED','COMPLETED'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
 ALTER TABLE public.downtime_events ADD CONSTRAINT machine_downtime_overlap_excl EXCLUDE USING gist (machine_id WITH =, tstzrange(started_at,COALESCE(ended_at,'infinity'::timestamptz),'[)') WITH &&);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
