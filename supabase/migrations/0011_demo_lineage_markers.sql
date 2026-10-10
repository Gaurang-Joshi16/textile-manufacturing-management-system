CREATE OR REPLACE FUNCTION public.mark_demo_record() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 CASE TG_TABLE_NAME
  WHEN 'buyer_orders' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.buyers WHERE id=NEW.buyer_id AND source='DEMO');
  WHEN 'buyer_order_lines','order_revisions','order_change_requests','feasibility_checks' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.buyer_orders WHERE id=NEW.order_id AND is_demo);
  WHEN 'production_plans' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.buyer_order_lines l JOIN public.buyer_orders o ON o.id=l.order_id WHERE l.id=NEW.order_line_id AND o.is_demo);
  WHEN 'plan_material_requirements' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.production_plans WHERE id=NEW.plan_id AND is_demo);
  WHEN 'production_operations' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.production_plans WHERE id=NEW.plan_id AND is_demo);
  WHEN 'operation_assignments' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.production_operations WHERE id=NEW.operation_id AND is_demo);
  WHEN 'operation_materials','operation_wip_inputs','operation_events','production_outputs','waste_ledger' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.production_operations WHERE id=NEW.operation_id AND is_demo);
  WHEN 'fabric_rolls' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.buyer_order_lines l JOIN public.buyer_orders o ON o.id=l.order_id WHERE l.id=NEW.order_line_id AND o.is_demo);
  WHEN 'roll_material_sources','roll_dye_lots','roll_status_history','roll_scan_events' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.fabric_rolls WHERE id=NEW.roll_id AND is_demo);
  WHEN 'roll_genealogy' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.fabric_rolls WHERE id=NEW.parent_roll_id AND is_demo) OR EXISTS(SELECT 1 FROM public.fabric_rolls WHERE id=NEW.child_roll_id AND is_demo);
  WHEN 'quality_inspections' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.fabric_rolls WHERE id=NEW.roll_id AND is_demo);
  WHEN 'quality_inspection_measurements','quality_defects' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.quality_inspections WHERE id=NEW.inspection_id AND is_demo);
  WHEN 'rework_orders' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.fabric_rolls WHERE id=NEW.roll_id AND is_demo);
  WHEN 'shipments' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.buyer_orders WHERE id=NEW.order_id AND is_demo);
  WHEN 'shipment_rolls','shipment_scan_events' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.shipments WHERE id=NEW.shipment_id AND is_demo);
  WHEN 'invoices' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.buyer_orders WHERE id=NEW.order_id AND is_demo) OR EXISTS(SELECT 1 FROM public.shipments WHERE id=NEW.shipment_id AND is_demo);
  WHEN 'dispatch_reversals' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.shipments WHERE id=NEW.shipment_id AND is_demo);
  WHEN 'attendance_records' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.employees WHERE id=NEW.employee_id AND source='DEMO');
  WHEN 'attendance_corrections' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.attendance_records WHERE id=NEW.attendance_id AND is_demo);
  WHEN 'payroll_lines','payroll_adjustments','labour_allocations' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.payroll_periods WHERE id=NEW.period_id AND is_demo);
  WHEN 'payroll_periods' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.payroll_rules WHERE id=NEW.rules_id AND is_demo);
  WHEN 'employee_compensation' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.employees WHERE id=NEW.employee_id AND source='DEMO');
  WHEN 'expenses' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.employees WHERE id=NEW.employee_id AND source='DEMO') OR EXISTS(SELECT 1 FROM public.buyer_orders WHERE id=NEW.order_id AND is_demo);
  WHEN 'cost_entries' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.buyer_orders WHERE id=NEW.order_id AND is_demo);
  WHEN 'order_cost_plans','cost_variance_cases' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.buyer_orders WHERE id=NEW.order_id AND is_demo);
  WHEN 'machine_status_log','downtime_events','maintenance_schedules','maintenance_work_orders','machine_telemetry' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.machines WHERE id=NEW.machine_id AND source='DEMO');
  WHEN 'maintenance_parts_used' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.maintenance_work_orders WHERE id=NEW.wo_id AND is_demo);
  WHEN 'shift_handovers' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.shift_instances WHERE id=NEW.shift_instance_id AND is_demo);
  WHEN 'quality_incident_rolls' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.quality_incidents WHERE id=NEW.incident_id AND is_demo);
  WHEN 'corrective_actions' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.quality_incidents WHERE id=NEW.incident_id AND is_demo);
  WHEN 'documents' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.buyer_orders WHERE id=NEW.entity_id AND is_demo) OR EXISTS(SELECT 1 FROM public.shipments WHERE id=NEW.entity_id AND is_demo);
  WHEN 'tasks' THEN NEW.is_demo:=NEW.is_demo OR EXISTS(SELECT 1 FROM public.exceptions WHERE id=NEW.source_exception_id AND is_demo);
  ELSE NULL;
 END CASE;
 RETURN NEW;
END $$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['buyer_orders','buyer_order_lines','order_revisions','order_change_requests','feasibility_checks','production_plans','plan_material_requirements','production_operations','operation_assignments','operation_materials','operation_wip_inputs','operation_events','production_outputs','shift_handovers','waste_ledger','fabric_rolls','roll_material_sources','roll_genealogy','roll_dye_lots','roll_status_history','roll_scan_events','quality_inspections','quality_inspection_measurements','quality_defects','rework_orders','shipments','shipment_rolls','shipment_scan_events','invoices','dispatch_reversals','attendance_records','attendance_corrections','payroll_periods','payroll_lines','payroll_adjustments','labour_allocations','employee_compensation','expenses','cost_entries','order_cost_plans','cost_variance_cases','machine_status_log','downtime_events','maintenance_schedules','maintenance_work_orders','machine_telemetry','maintenance_parts_used','quality_incident_rolls','corrective_actions','documents','tasks'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS mark_demo_record ON public.%I',t);
  EXECUTE format('CREATE TRIGGER mark_demo_record BEFORE INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION public.mark_demo_record()',t);
 END LOOP;
END $$;
REVOKE EXECUTE ON FUNCTION public.mark_demo_record() FROM PUBLIC,anon,authenticated;
