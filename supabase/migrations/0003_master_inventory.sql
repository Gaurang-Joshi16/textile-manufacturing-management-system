-- Phase 2: master data, procurement, raw material, and append-only inventory ledger.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated;
DO $$ BEGIN CREATE TYPE public.batch_status AS ENUM ('AVAILABLE','QUARANTINED','HOLD','DEPLETED'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE public.movement_type AS ENUM ('RECEIPT','QUARANTINE_IN','QUARANTINE_OUT','ISSUE','RETURN','ADJUSTMENT_IN','ADJUSTMENT_OUT','WASTE','TRANSFER','PRODUCTION_OUTPUT','DISPATCH','DISPATCH_REVERSAL','REVERSAL'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE public.item_kind AS ENUM ('YARN_BATCH','FABRIC_ROLL','WIP_LOT'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE public.purchase_order_status AS ENUM ('DRAFT','PENDING_APPROVAL','APPROVED','SENT','PARTIALLY_RECEIVED','RECEIVED','CANCELLED'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE public.approval_status_stock AS ENUM ('PENDING','APPROVED','REJECTED'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE public.cost_basis AS ENUM ('ACTUAL','ALLOCATED','ESTIMATED'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS public.suppliers (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), supplier_code text NOT NULL UNIQUE, name text NOT NULL, contact_name text, email text, phone text, address text, lead_time_days integer NOT NULL DEFAULT 0 CHECK(lead_time_days>=0), is_active boolean NOT NULL DEFAULT true, source text NOT NULL DEFAULT 'LIVE', created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.products (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), product_code text NOT NULL UNIQUE, description text NOT NULL, colour text NOT NULL DEFAULT '', width_cm numeric(10,2), gsm numeric(10,2), unit text NOT NULL DEFAULT 'm', tolerance_json jsonb NOT NULL DEFAULT '{}'::jsonb, specification_json jsonb NOT NULL DEFAULT '{}'::jsonb, standard_roll_length numeric(14,3) NOT NULL DEFAULT 50 CHECK(standard_roll_length>0), is_active boolean NOT NULL DEFAULT true, source text NOT NULL DEFAULT 'LIVE', created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.yarn_items (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), item_code text NOT NULL UNIQUE, name text NOT NULL, yarn_count text, yarn_type text, colour text NOT NULL DEFAULT '', unit text NOT NULL DEFAULT 'kg', reorder_point numeric(14,3) NOT NULL DEFAULT 0 CHECK(reorder_point>=0), safety_buffer numeric(14,3) NOT NULL DEFAULT 0 CHECK(safety_buffer>=0), preferred_supplier_id uuid REFERENCES public.suppliers(id), standard_unit_cost numeric(16,2) NOT NULL DEFAULT 0 CHECK(standard_unit_cost>=0), currency text NOT NULL DEFAULT 'INR', requires_inspection boolean NOT NULL DEFAULT false, is_dye_chemical boolean NOT NULL DEFAULT false, is_active boolean NOT NULL DEFAULT true, source text NOT NULL DEFAULT 'LIVE', created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.unit_conversions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), from_unit text NOT NULL, to_unit text NOT NULL, factor numeric(18,8) NOT NULL CHECK(factor>0), yarn_item_id uuid REFERENCES public.yarn_items(id), product_id uuid REFERENCES public.products(id), created_at timestamptz NOT NULL DEFAULT now(), CHECK(yarn_item_id IS NOT NULL OR product_id IS NOT NULL), UNIQUE(from_unit,to_unit,yarn_item_id,product_id)
);
CREATE TABLE IF NOT EXISTS public.process_definitions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), code text NOT NULL UNIQUE, name text NOT NULL, machine_type text, creates_rolls boolean NOT NULL DEFAULT false, default_sequence integer NOT NULL DEFAULT 0, is_active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.product_routes (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), product_id uuid NOT NULL REFERENCES public.products(id), process_id uuid NOT NULL REFERENCES public.process_definitions(id), sequence integer NOT NULL CHECK(sequence>0), is_applicable boolean NOT NULL DEFAULT true, expected_yield_pct numeric(6,3) NOT NULL DEFAULT 100 CHECK(expected_yield_pct>0 AND expected_yield_pct<=100), expected_waste_pct numeric(6,3) NOT NULL DEFAULT 0 CHECK(expected_waste_pct>=0 AND expected_waste_pct<=100), created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(product_id,sequence)
);
CREATE TABLE IF NOT EXISTS public.product_bom (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), product_id uuid NOT NULL REFERENCES public.products(id), yarn_item_id uuid NOT NULL REFERENCES public.yarn_items(id), qty_per_output_unit numeric(14,3) NOT NULL CHECK(qty_per_output_unit>0), wastage_pct numeric(6,3) NOT NULL DEFAULT 0 CHECK(wastage_pct>=0 AND wastage_pct<=100), created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(product_id,yarn_item_id)
);
CREATE TABLE IF NOT EXISTS public.machines (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), machine_code text NOT NULL UNIQUE, name text NOT NULL, process_id uuid REFERENCES public.process_definitions(id), machine_type text NOT NULL, location text NOT NULL DEFAULT '', capacity_per_hour numeric(14,3) NOT NULL DEFAULT 0 CHECK(capacity_per_hour>=0), capacity_unit text NOT NULL DEFAULT 'm', status text NOT NULL DEFAULT 'IDLE' CHECK(status IN ('RUNNING','IDLE','SETUP','PLANNED_MAINTENANCE','BREAKDOWN','OFFLINE')), image_file_id uuid, cost_per_minute numeric(16,2) NOT NULL DEFAULT 0 CHECK(cost_per_minute>=0), counter_hours numeric(14,3) NOT NULL DEFAULT 0 CHECK(counter_hours>=0), last_maintenance_at timestamptz, next_maintenance_due timestamptz, is_active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.shifts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL UNIQUE, start_time time NOT NULL, end_time time NOT NULL, crosses_midnight boolean NOT NULL DEFAULT false, timezone text NOT NULL DEFAULT 'Asia/Kolkata', is_active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.employees ADD CONSTRAINT employees_default_shift_fk FOREIGN KEY(default_shift_id) REFERENCES public.shifts(id);
CREATE TABLE IF NOT EXISTS public.shift_instances (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), shift_id uuid NOT NULL REFERENCES public.shifts(id), work_date date NOT NULL, status text NOT NULL DEFAULT 'OPEN' CHECK(status IN ('OPEN','CLOSED')), closed_by uuid REFERENCES public.profiles(id), closed_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(shift_id,work_date)
);
CREATE TABLE IF NOT EXISTS public.shift_roster (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), employee_id uuid NOT NULL REFERENCES public.employees(id), shift_id uuid NOT NULL REFERENCES public.shifts(id), work_date date NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(employee_id,shift_id,work_date)
);
CREATE TABLE IF NOT EXISTS public.warehouses (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), code text NOT NULL UNIQUE, name text NOT NULL, type text NOT NULL CHECK(type IN ('RAW','WIP','FINISHED','QUARANTINE','REWORK')), is_active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.stock_locations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), warehouse_id uuid NOT NULL REFERENCES public.warehouses(id), code text NOT NULL, description text NOT NULL DEFAULT '', is_active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(warehouse_id,code)
);
CREATE TABLE IF NOT EXISTS public.defect_categories (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), code text NOT NULL UNIQUE, name text NOT NULL, default_severity text NOT NULL DEFAULT 'LOW' CHECK(default_severity IN ('INFO','LOW','MEDIUM','HIGH','CRITICAL')), auto_action text NOT NULL DEFAULT 'NONE' CHECK(auto_action IN ('NONE','REWORK','REJECT','QUARANTINE')), is_active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.downtime_reasons (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), code text NOT NULL UNIQUE, name text NOT NULL, category text NOT NULL CHECK(category IN ('BREAKDOWN','MATERIAL_WAIT','CHANGEOVER','NO_OPERATOR','POWER','PLANNED_MAINT','OTHER')), is_active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.cost_categories (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), code text NOT NULL UNIQUE CHECK(code IN ('MATERIAL','LABOUR','MACHINE','CHEMICAL','MAINTENANCE','REWORK','WASTE','PACKAGING','DISPATCH','OTHER')), name text NOT NULL, approval_threshold numeric(16,2) NOT NULL DEFAULT 0 CHECK(approval_threshold>=0), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.inspection_plans (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), product_id uuid NOT NULL REFERENCES public.products(id), process_id uuid REFERENCES public.process_definitions(id), name text NOT NULL, version integer NOT NULL DEFAULT 1, sampling_rule jsonb NOT NULL DEFAULT '{}'::jsonb, is_active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(product_id,name,version)
);
CREATE TABLE IF NOT EXISTS public.inspection_plan_checks (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), plan_id uuid NOT NULL REFERENCES public.inspection_plans(id) ON DELETE CASCADE, check_name text NOT NULL, expected_min numeric(14,3), expected_max numeric(14,3), unit text NOT NULL, mandatory boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.spare_parts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), part_code text NOT NULL UNIQUE, name text NOT NULL, stock_qty numeric(14,3) NOT NULL DEFAULT 0 CHECK(stock_qty>=0), min_qty numeric(14,3) NOT NULL DEFAULT 0 CHECK(min_qty>=0), unit text NOT NULL, unit_cost numeric(16,2) NOT NULL DEFAULT 0 CHECK(unit_cost>=0), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.purchase_orders (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), po_number text NOT NULL UNIQUE, supplier_id uuid NOT NULL REFERENCES public.suppliers(id), status public.purchase_order_status NOT NULL DEFAULT 'DRAFT', expected_date date, currency text NOT NULL DEFAULT 'INR', source text NOT NULL DEFAULT 'MANUAL' CHECK(source IN ('MANUAL','AUTO_SHORTAGE')), is_rfq_draft boolean NOT NULL DEFAULT false, event_key text UNIQUE, approved_by uuid REFERENCES public.profiles(id), price_flag boolean NOT NULL DEFAULT false, created_by uuid REFERENCES public.profiles(id), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.purchase_order_lines (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), po_id uuid NOT NULL REFERENCES public.purchase_orders(id) ON DELETE CASCADE, yarn_item_id uuid NOT NULL REFERENCES public.yarn_items(id), ordered_qty numeric(14,3) NOT NULL CHECK(ordered_qty>0), unit text NOT NULL, unit_price numeric(16,2) NOT NULL CHECK(unit_price>=0), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.purchase_receipts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), receipt_number text NOT NULL UNIQUE, supplier_id uuid NOT NULL REFERENCES public.suppliers(id), po_id uuid REFERENCES public.purchase_orders(id), delivery_reference text, received_at timestamptz NOT NULL DEFAULT now(), received_by uuid REFERENCES public.profiles(id), status text NOT NULL DEFAULT 'POSTED' CHECK(status IN ('POSTED','CANCELLED')), variance_flag boolean NOT NULL DEFAULT false, notes text, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.yarn_batches (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), batch_code text NOT NULL UNIQUE, yarn_item_id uuid NOT NULL REFERENCES public.yarn_items(id), receipt_id uuid REFERENCES public.purchase_receipts(id), po_line_id uuid REFERENCES public.purchase_order_lines(id), supplier_lot text NOT NULL DEFAULT '', received_qty numeric(14,3) NOT NULL CHECK(received_qty>0), accepted_qty numeric(14,3) NOT NULL DEFAULT 0 CHECK(accepted_qty>=0), damaged_qty numeric(14,3) NOT NULL DEFAULT 0 CHECK(damaged_qty>=0), quarantined_qty numeric(14,3) NOT NULL DEFAULT 0 CHECK(quarantined_qty>=0), unit text NOT NULL, unit_cost numeric(16,2) NOT NULL CHECK(unit_cost>=0), currency text NOT NULL DEFAULT 'INR', colour text NOT NULL DEFAULT '', received_date date NOT NULL DEFAULT current_date, status public.batch_status NOT NULL DEFAULT 'AVAILABLE', hold_reason text, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), CHECK(received_qty=accepted_qty+damaged_qty+quarantined_qty)
);
CREATE INDEX IF NOT EXISTS yarn_batches_item_status_idx ON public.yarn_batches(yarn_item_id,status,received_date,id);
CREATE TABLE IF NOT EXISTS public.inventory_movements (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), movement_no text NOT NULL UNIQUE, item_kind public.item_kind NOT NULL DEFAULT 'YARN_BATCH', yarn_batch_id uuid REFERENCES public.yarn_batches(id), roll_id uuid, wip_lot_id uuid, movement_type public.movement_type NOT NULL, qty numeric(14,3) NOT NULL CHECK(qty>0), unit text NOT NULL, from_location_id uuid REFERENCES public.stock_locations(id), to_location_id uuid REFERENCES public.stock_locations(id), source_type text, source_id uuid, reason text, reverses_movement_id uuid REFERENCES public.inventory_movements(id), idempotency_key uuid UNIQUE, created_by uuid REFERENCES public.profiles(id), created_at timestamptz NOT NULL DEFAULT now(), CHECK((item_kind='YARN_BATCH' AND yarn_batch_id IS NOT NULL) OR (item_kind='FABRIC_ROLL' AND roll_id IS NOT NULL) OR (item_kind='WIP_LOT' AND wip_lot_id IS NOT NULL)), CHECK(from_location_id IS DISTINCT FROM to_location_id)
);
CREATE INDEX IF NOT EXISTS inventory_movements_batch_idx ON public.inventory_movements(yarn_batch_id,created_at);
CREATE INDEX IF NOT EXISTS inventory_movements_location_idx ON public.inventory_movements(from_location_id,to_location_id,created_at);
CREATE TABLE IF NOT EXISTS public.material_reservations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), plan_id uuid, order_line_id uuid, yarn_batch_id uuid NOT NULL REFERENCES public.yarn_batches(id), location_id uuid NOT NULL REFERENCES public.stock_locations(id), qty numeric(14,3) NOT NULL CHECK(qty>0), consumed_qty numeric(14,3) NOT NULL DEFAULT 0 CHECK(consumed_qty>=0), status text NOT NULL DEFAULT 'ACTIVE' CHECK(status IN ('ACTIVE','AT_RISK','CONSUMED','RELEASED','CANCELLED')), reserved_by uuid REFERENCES public.profiles(id), released_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), CHECK(consumed_qty<=qty)
);
CREATE INDEX IF NOT EXISTS material_reservations_batch_status_idx ON public.material_reservations(yarn_batch_id,location_id,status);
CREATE TABLE IF NOT EXISTS public.stock_adjustments (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), adj_no text NOT NULL UNIQUE, yarn_batch_id uuid REFERENCES public.yarn_batches(id), roll_id uuid, location_id uuid NOT NULL REFERENCES public.stock_locations(id), qty_delta numeric(14,3) NOT NULL CHECK(qty_delta<>0), reason text NOT NULL, status public.approval_status_stock NOT NULL DEFAULT 'PENDING', requested_by uuid NOT NULL REFERENCES public.profiles(id), approved_by uuid REFERENCES public.profiles(id), approval_id uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.cycle_counts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), location_id uuid NOT NULL REFERENCES public.stock_locations(id), status text NOT NULL DEFAULT 'OPEN' CHECK(status IN ('OPEN','SUBMITTED')), counted_by uuid REFERENCES public.profiles(id), created_at timestamptz NOT NULL DEFAULT now(), submitted_at timestamptz
);
CREATE TABLE IF NOT EXISTS public.cycle_count_lines (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), count_id uuid NOT NULL REFERENCES public.cycle_counts(id) ON DELETE CASCADE, yarn_batch_id uuid REFERENCES public.yarn_batches(id), roll_id uuid, system_qty numeric(14,3) NOT NULL, counted_qty numeric(14,3) NOT NULL CHECK(counted_qty>=0), variance numeric(14,3) GENERATED ALWAYS AS(counted_qty-system_qty) STORED
);
CREATE TABLE IF NOT EXISTS public.wip_lots (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), wip_code text NOT NULL UNIQUE, plan_id uuid, operation_id uuid, qty numeric(14,3) NOT NULL CHECK(qty>=0), unit text NOT NULL, status text NOT NULL DEFAULT 'AVAILABLE' CHECK(status IN ('AVAILABLE','CONSUMED','HOLD')), location_id uuid REFERENCES public.stock_locations(id), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.cost_entries (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), order_id uuid, order_line_id uuid, operation_id uuid, shipment_id uuid, category_id uuid REFERENCES public.cost_categories(id), description text NOT NULL DEFAULT '', amount numeric(16,2) NOT NULL, currency text NOT NULL, cost_basis public.cost_basis NOT NULL, source_type text, source_id uuid, source_ref text, external_id text UNIQUE, idempotency_key uuid UNIQUE, reverses_cost_entry_id uuid REFERENCES public.cost_entries(id), approved_by uuid REFERENCES public.profiles(id), created_by uuid REFERENCES public.profiles(id), created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.validate_yarn_movement() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_from numeric(14,3); v_to numeric(14,3);
BEGIN
 IF NEW.item_kind<>'YARN_BATCH' THEN RETURN NEW; END IF;
 PERFORM 1 FROM public.yarn_batches WHERE id=NEW.yarn_batch_id FOR UPDATE;
 IF NEW.from_location_id IS NOT NULL THEN
   SELECT COALESCE(sum(CASE WHEN to_location_id=NEW.from_location_id THEN qty WHEN from_location_id=NEW.from_location_id THEN -qty ELSE 0 END),0) INTO v_from FROM public.inventory_movements WHERE yarn_batch_id=NEW.yarn_batch_id;
   IF v_from<NEW.qty THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: INSUFFICIENT_STOCK'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER inventory_movement_balance BEFORE INSERT ON public.inventory_movements FOR EACH ROW EXECUTE FUNCTION public.validate_yarn_movement();
CREATE TRIGGER inventory_movement_append_only BEFORE UPDATE OR DELETE ON public.inventory_movements FOR EACH ROW EXECUTE FUNCTION public.prevent_update_delete();
CREATE TRIGGER yarn_batches_updated_at BEFORE UPDATE ON public.yarn_batches FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER suppliers_updated_at BEFORE UPDATE ON public.suppliers FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER products_updated_at BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER yarn_items_updated_at BEFORE UPDATE ON public.yarn_items FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER machines_updated_at BEFORE UPDATE ON public.machines FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER shifts_updated_at BEFORE UPDATE ON public.shifts FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER purchase_orders_updated_at BEFORE UPDATE ON public.purchase_orders FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER stock_adjustments_updated_at BEFORE UPDATE ON public.stock_adjustments FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE VIEW public.v_yarn_stock AS
WITH ledger AS (
 SELECT b.id AS yarn_batch_id,b.yarn_item_id,m.to_location_id AS location_id,sum(m.qty) AS qty FROM public.yarn_batches b JOIN public.inventory_movements m ON m.yarn_batch_id=b.id WHERE m.to_location_id IS NOT NULL GROUP BY b.id,b.yarn_item_id,m.to_location_id
 UNION ALL
 SELECT b.id,b.yarn_item_id,m.from_location_id,-sum(m.qty) FROM public.yarn_batches b JOIN public.inventory_movements m ON m.yarn_batch_id=b.id WHERE m.from_location_id IS NOT NULL GROUP BY b.id,b.yarn_item_id,m.from_location_id
), balances AS (
 SELECT yarn_batch_id,yarn_item_id,location_id,sum(qty) on_hand FROM ledger GROUP BY yarn_batch_id,yarn_item_id,location_id
), reserves AS (
 SELECT yarn_batch_id,location_id,sum(qty-consumed_qty) reserved FROM public.material_reservations WHERE status IN ('ACTIVE','AT_RISK') GROUP BY yarn_batch_id,location_id
)
SELECT b.yarn_item_id,b.id AS yarn_batch_id,bal.location_id,bal.on_hand,COALESCE(r.reserved,0)::numeric(14,3) reserved,
 CASE WHEN w.type='QUARANTINE' OR b.status<>'AVAILABLE' THEN bal.on_hand ELSE 0 END::numeric(14,3) quarantined,
 CASE WHEN w.type='RAW' AND b.status='AVAILABLE' THEN greatest(0,bal.on_hand-COALESCE(r.reserved,0)) ELSE 0 END::numeric(14,3) available,
 0::numeric(14,3) AS expected
FROM public.yarn_batches b JOIN balances bal ON bal.yarn_batch_id=b.id JOIN public.stock_locations l ON l.id=bal.location_id JOIN public.warehouses w ON w.id=l.warehouse_id LEFT JOIN reserves r ON r.yarn_batch_id=b.id AND r.location_id=bal.location_id;

CREATE OR REPLACE FUNCTION public.rpc_post_receipt(p_supplier_id uuid,p_po_id uuid,p_delivery_reference text,p_lines jsonb,p_idempotency_key uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_existing jsonb; v_receipt uuid; v_receipt_no text; v_line jsonb; v_item public.yarn_items%ROWTYPE; v_batch uuid; v_batch_code text; v_received numeric(14,3); v_accepted numeric(14,3); v_damaged numeric(14,3); v_quarantined numeric(14,3); v_unit text; v_cost numeric(16,2); v_raw uuid; v_quar uuid; v_total numeric(14,3); v_result jsonb; v_qty numeric(14,3);
BEGIN
 PERFORM private.assert_permission('inventory.receive');
 SELECT response INTO v_existing FROM public.idempotency_keys WHERE scope='post_receipt' AND key=p_idempotency_key; IF FOUND THEN RETURN v_existing; END IF;
 IF jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)=0 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: RECEIPT_LINES_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.suppliers WHERE id=p_supplier_id AND is_active) THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: SUPPLIER_NOT_FOUND'; END IF;
 v_receipt_no:=private.next_doc_no('RCP');
 INSERT INTO public.purchase_receipts(receipt_number,supplier_id,po_id,delivery_reference,received_by) VALUES(v_receipt_no,p_supplier_id,p_po_id,p_delivery_reference,auth.uid()) RETURNING id INTO v_receipt;
 FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
   SELECT * INTO v_item FROM public.yarn_items WHERE id=(v_line->>'yarn_item_id')::uuid AND is_active FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: YARN_ITEM_NOT_FOUND'; END IF;
   v_received:=(v_line->>'received_qty')::numeric; v_accepted:=(v_line->>'accepted_qty')::numeric; v_damaged:=(v_line->>'damaged_qty')::numeric; v_quarantined:=(v_line->>'quarantined_qty')::numeric; v_unit:=COALESCE(v_line->>'unit',''); v_cost:=(v_line->>'unit_cost')::numeric;
   IF v_received<=0 OR v_accepted<0 OR v_damaged<0 OR v_quarantined<0 OR v_received<>v_accepted+v_damaged+v_quarantined THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: RECEIPT_QTY_MISMATCH'; END IF;
   IF v_unit<>v_item.unit THEN IF NOT EXISTS(SELECT 1 FROM public.unit_conversions WHERE yarn_item_id=v_item.id AND from_unit=v_unit AND to_unit=v_item.unit) THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: UNIT_CONVERSION_MISSING'; END IF; RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: RECEIPT_UNIT_CONVERSION_REQUIRED'; END IF;
   SELECT id INTO v_raw FROM public.stock_locations l JOIN public.warehouses w ON w.id=l.warehouse_id WHERE w.type='RAW' AND l.is_active ORDER BY l.code LIMIT 1;
   SELECT id INTO v_quar FROM public.stock_locations l JOIN public.warehouses w ON w.id=l.warehouse_id WHERE w.type='QUARANTINE' AND l.is_active ORDER BY l.code LIMIT 1;
   IF v_raw IS NULL OR v_quar IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: STOCK_LOCATIONS_NOT_CONFIGURED'; END IF;
   v_total:=v_accepted+v_quarantined;
   INSERT INTO public.yarn_batches(batch_code,yarn_item_id,receipt_id,po_line_id,supplier_lot,received_qty,accepted_qty,damaged_qty,quarantined_qty,unit,unit_cost,currency,colour,status,hold_reason)
   VALUES(private.next_doc_no('YB'),v_item.id,v_receipt,NULL,COALESCE(v_line->>'supplier_lot',''),v_received,v_accepted,v_damaged,v_quarantined,v_item.unit,v_cost,COALESCE(v_line->>'currency','INR'),COALESCE(v_line->>'colour',v_item.colour),CASE WHEN v_item.requires_inspection OR v_quarantined>0 THEN 'QUARANTINED'::public.batch_status ELSE 'AVAILABLE'::public.batch_status END,CASE WHEN v_item.requires_inspection THEN 'Inspection required' WHEN v_quarantined>0 THEN 'Supplier quarantine' ELSE NULL END) RETURNING id,batch_code INTO v_batch,v_batch_code;
   IF v_item.requires_inspection THEN
     IF v_total>0 THEN INSERT INTO public.inventory_movements(movement_no,yarn_batch_id,movement_type,qty,unit,to_location_id,source_type,source_id,created_by) VALUES(private.next_doc_no('MOV'),v_batch,'QUARANTINE_IN',v_total,v_item.unit,v_quar,'receipt',v_receipt,auth.uid()); END IF;
   ELSE
     IF v_accepted>0 THEN INSERT INTO public.inventory_movements(movement_no,yarn_batch_id,movement_type,qty,unit,to_location_id,source_type,source_id,created_by) VALUES(private.next_doc_no('MOV'),v_batch,'RECEIPT',v_accepted,v_item.unit,v_raw,'receipt',v_receipt,auth.uid()); END IF;
     IF v_quarantined>0 THEN INSERT INTO public.inventory_movements(movement_no,yarn_batch_id,movement_type,qty,unit,to_location_id,source_type,source_id,created_by) VALUES(private.next_doc_no('MOV'),v_batch,'QUARANTINE_IN',v_quarantined,v_item.unit,v_quar,'receipt',v_receipt,auth.uid()); END IF;
   END IF;
 END LOOP;
 v_result:=jsonb_build_object('receipt_id',v_receipt,'receipt_number',v_receipt_no,'status','POSTED');
 INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('post_receipt',p_idempotency_key,auth.uid(),v_result);
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,after_json) VALUES(auth.uid(),'RECEIPT_POSTED','purchase_receipts',v_receipt,v_result);
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_reserve_material(p_yarn_item_id uuid,p_qty numeric,p_unit text,p_plan_id uuid DEFAULT NULL,p_order_line_id uuid DEFAULT NULL,p_idempotency_key uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_existing jsonb; v_item public.yarn_items%ROWTYPE; v_available numeric(14,3); v_need numeric(14,3); v_take numeric(14,3); r record; v_rows jsonb:='[]'::jsonb; v_res uuid; v_result jsonb; v_factor numeric(18,8);
BEGIN
 PERFORM private.assert_permission('inventory.reserve');
 IF p_qty<=0 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: QUANTITY_INVALID'; END IF;
 IF p_idempotency_key IS NOT NULL THEN SELECT response INTO v_existing FROM public.idempotency_keys WHERE scope='reserve_material' AND key=p_idempotency_key; IF FOUND THEN RETURN v_existing; END IF; END IF;
 PERFORM pg_advisory_xact_lock(hashtext(p_yarn_item_id::text));
 SELECT * INTO v_item FROM public.yarn_items WHERE id=p_yarn_item_id AND is_active FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: YARN_ITEM_NOT_FOUND'; END IF;
 v_need:=p_qty;
 IF p_unit<>v_item.unit THEN SELECT factor INTO v_factor FROM public.unit_conversions WHERE yarn_item_id=v_item.id AND from_unit=p_unit AND to_unit=v_item.unit; IF v_factor IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: UNIT_CONVERSION_MISSING'; END IF; v_need:=p_qty*v_factor; END IF;
 SELECT COALESCE(sum(available),0) INTO v_available FROM public.v_yarn_stock WHERE yarn_item_id=p_yarn_item_id;
 IF v_available<v_need THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: INSUFFICIENT_STOCK'; END IF;
 FOR r IN SELECT s.yarn_batch_id,s.location_id,s.available FROM public.v_yarn_stock s JOIN public.yarn_batches b ON b.id=s.yarn_batch_id WHERE s.yarn_item_id=p_yarn_item_id AND s.available>0 ORDER BY b.received_date,b.id,s.location_id FOR UPDATE OF b LOOP
   EXIT WHEN v_need<=0;
   v_take:=least(r.available,v_need);
   INSERT INTO public.material_reservations(plan_id,order_line_id,yarn_batch_id,location_id,qty,reserved_by) VALUES(p_plan_id,p_order_line_id,r.yarn_batch_id,r.location_id,v_take,auth.uid()) RETURNING id INTO v_res;
   v_rows:=v_rows||jsonb_build_array(jsonb_build_object('reservation_id',v_res,'batch_id',r.yarn_batch_id,'location_id',r.location_id,'qty',v_take,'unit',v_item.unit));
   v_need:=v_need-v_take;
 END LOOP;
 v_result:=jsonb_build_object('reserved',true,'qty',p_qty,'unit',p_unit,'lines',v_rows);
 IF p_idempotency_key IS NOT NULL THEN INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('reserve_material',p_idempotency_key,auth.uid(),v_result); END IF;
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,after_json) VALUES(auth.uid(),'MATERIAL_RESERVED','material_reservations',v_result);
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_release_reservation(p_reservation_id uuid,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_row public.material_reservations%ROWTYPE;
BEGIN
 PERFORM private.assert_permission('inventory.reserve');
 IF length(trim(COALESCE(p_reason,'')))<3 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: REASON_REQUIRED'; END IF;
 SELECT * INTO v_row FROM public.material_reservations WHERE id=p_reservation_id FOR UPDATE;
 IF NOT FOUND OR v_row.status NOT IN ('ACTIVE','AT_RISK') THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: RESERVATION_NOT_ACTIVE'; END IF;
 UPDATE public.material_reservations SET status='RELEASED',released_at=now() WHERE id=p_reservation_id;
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,reason) VALUES(auth.uid(),'RESERVATION_RELEASED','material_reservations',p_reservation_id,p_reason);
 RETURN jsonb_build_object('reservation_id',p_reservation_id,'status','RELEASED');
END $$;

CREATE OR REPLACE FUNCTION public.rpc_issue_material(p_reservation_id uuid,p_qty numeric,p_idempotency_key uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_existing jsonb; v_r public.material_reservations%ROWTYPE; v_batch public.yarn_batches%ROWTYPE; v_mov uuid; v_result jsonb;
BEGIN
 PERFORM private.assert_permission('inventory.issue');
 SELECT response INTO v_existing FROM public.idempotency_keys WHERE scope='issue_material' AND key=p_idempotency_key; IF FOUND THEN RETURN v_existing; END IF;
 SELECT * INTO v_r FROM public.material_reservations WHERE id=p_reservation_id FOR UPDATE;
 IF NOT FOUND OR v_r.status NOT IN ('ACTIVE','AT_RISK') OR p_qty<=0 OR p_qty>v_r.qty-v_r.consumed_qty THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: RESERVATION_QTY_INVALID'; END IF;
 SELECT * INTO v_batch FROM public.yarn_batches WHERE id=v_r.yarn_batch_id FOR UPDATE;
 INSERT INTO public.inventory_movements(movement_no,yarn_batch_id,movement_type,qty,unit,from_location_id,source_type,source_id,idempotency_key,created_by) VALUES(private.next_doc_no('MOV'),v_batch.id,'ISSUE',p_qty,v_batch.unit,v_r.location_id,'reservation',p_reservation_id,p_idempotency_key,auth.uid()) RETURNING id INTO v_mov;
 UPDATE public.material_reservations SET consumed_qty=consumed_qty+p_qty,status=CASE WHEN consumed_qty+p_qty>=qty THEN 'CONSUMED' ELSE status END WHERE id=p_reservation_id;
 v_result:=jsonb_build_object('movement_id',v_mov,'qty',p_qty,'unit',v_batch.unit,'unit_cost_snapshot',v_batch.unit_cost);
 INSERT INTO public.idempotency_keys(scope,key,user_id,response) VALUES('issue_material',p_idempotency_key,auth.uid(),v_result);
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,after_json) VALUES(auth.uid(),'MATERIAL_ISSUED','inventory_movements',v_mov,v_result);
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.rpc_request_adjustment(p_yarn_batch_id uuid,p_location_id uuid,p_qty_delta numeric,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid; v_no text;
BEGIN
 PERFORM private.assert_permission('inventory.adjust_request');
 IF p_qty_delta=0 OR length(trim(COALESCE(p_reason,'')))<10 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: REASON_REQUIRED'; END IF;
 v_no:=private.next_doc_no('ADJ');
 INSERT INTO public.stock_adjustments(adj_no,yarn_batch_id,location_id,qty_delta,reason,requested_by) VALUES(v_no,p_yarn_batch_id,p_location_id,p_qty_delta,p_reason,auth.uid()) RETURNING id INTO v_id;
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,after_json,reason) VALUES(auth.uid(),'ADJUSTMENT_REQUESTED','stock_adjustments',v_id,jsonb_build_object('qty_delta',p_qty_delta),p_reason);
 RETURN jsonb_build_object('adjustment_id',v_id,'adj_no',v_no,'status','PENDING');
END $$;

CREATE OR REPLACE FUNCTION public.rpc_decide_adjustment(p_adjustment_id uuid,p_decision text,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_a public.stock_adjustments%ROWTYPE; v_on_hand numeric(14,3); v_type public.movement_type;
BEGIN
 PERFORM private.assert_permission('inventory.adjust_approve');
 IF length(trim(COALESCE(p_reason,'')))<10 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: REASON_REQUIRED'; END IF;
 SELECT * INTO v_a FROM public.stock_adjustments WHERE id=p_adjustment_id FOR UPDATE;
 IF NOT FOUND OR v_a.status<>'PENDING' THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: ADJUSTMENT_NOT_PENDING'; END IF;
 IF v_a.requested_by=auth.uid() AND COALESCE((SELECT value::text::boolean FROM public.system_settings WHERE key='sod.stock_adjustment'),true) THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: SEPARATION_OF_DUTIES'; END IF;
 IF p_decision NOT IN ('approve','reject') THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: INVALID_DECISION'; END IF;
 IF p_decision='reject' THEN UPDATE public.stock_adjustments SET status='REJECTED',approved_by=auth.uid() WHERE id=p_adjustment_id; RETURN jsonb_build_object('adjustment_id',p_adjustment_id,'status','REJECTED'); END IF;
 SELECT COALESCE(sum(CASE WHEN to_location_id=v_a.location_id THEN qty WHEN from_location_id=v_a.location_id THEN -qty ELSE 0 END),0) INTO v_on_hand FROM public.inventory_movements WHERE yarn_batch_id=v_a.yarn_batch_id;
 IF v_on_hand+v_a.qty_delta<0 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='CODE: INSUFFICIENT_STOCK'; END IF;
 v_type:=CASE WHEN v_a.qty_delta>0 THEN 'ADJUSTMENT_IN'::public.movement_type ELSE 'ADJUSTMENT_OUT'::public.movement_type END;
 INSERT INTO public.inventory_movements(movement_no,yarn_batch_id,movement_type,qty,unit,from_location_id,to_location_id,source_type,source_id,reason,created_by) SELECT private.next_doc_no('MOV'),v_a.yarn_batch_id,v_type,abs(v_a.qty_delta),b.unit,CASE WHEN v_a.qty_delta<0 THEN v_a.location_id END,CASE WHEN v_a.qty_delta>0 THEN v_a.location_id END,'adjustment',v_a.id,p_reason,auth.uid() FROM public.yarn_batches b WHERE b.id=v_a.yarn_batch_id;
 UPDATE public.stock_adjustments SET status='APPROVED',approved_by=auth.uid() WHERE id=p_adjustment_id;
 INSERT INTO public.audit_logs(actor_user_id,action,entity_type,entity_id,reason) VALUES(auth.uid(),'ADJUSTMENT_APPROVED','stock_adjustments',p_adjustment_id,p_reason);
 RETURN jsonb_build_object('adjustment_id',p_adjustment_id,'status','APPROVED');
END $$;

CREATE INDEX IF NOT EXISTS suppliers_name_trgm_idx ON public.suppliers USING gin(name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS products_description_trgm_idx ON public.products USING gin(description gin_trgm_ops);
CREATE INDEX IF NOT EXISTS yarn_items_name_trgm_idx ON public.yarn_items USING gin(name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS purchase_orders_status_idx ON public.purchase_orders(status,created_at DESC);
CREATE INDEX IF NOT EXISTS inventory_movements_created_idx ON public.inventory_movements(created_at DESC);

DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['suppliers','products','yarn_items','unit_conversions','process_definitions','product_routes','product_bom','machines','shifts','shift_instances','shift_roster','warehouses','stock_locations','defect_categories','downtime_reasons','cost_categories','inspection_plans','inspection_plan_checks','spare_parts','purchase_orders','purchase_order_lines','purchase_receipts','yarn_batches','inventory_movements','material_reservations','stock_adjustments','cycle_counts','cycle_count_lines','wip_lots','cost_entries'] LOOP EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t); END LOOP;
END $$;
CREATE POLICY suppliers_read ON public.suppliers FOR SELECT TO authenticated USING (private.has_permission('master.read') OR private.has_permission('purchasing.read'));
CREATE POLICY suppliers_manage ON public.suppliers FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY products_read ON public.products FOR SELECT TO authenticated USING (private.has_permission('master.read'));
CREATE POLICY products_manage ON public.products FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY yarn_items_read ON public.yarn_items FOR SELECT TO authenticated USING (private.has_any_permission(ARRAY['master.read','inventory.read','purchasing.read']));
CREATE POLICY yarn_items_manage ON public.yarn_items FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY unit_conversions_read ON public.unit_conversions FOR SELECT TO authenticated USING (private.has_permission('master.read'));
CREATE POLICY unit_conversions_manage ON public.unit_conversions FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY process_definitions_read ON public.process_definitions FOR SELECT TO authenticated USING (private.has_permission('master.read'));
CREATE POLICY process_definitions_manage ON public.process_definitions FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY product_routes_read ON public.product_routes FOR SELECT TO authenticated USING (private.has_permission('master.read'));
CREATE POLICY product_routes_manage ON public.product_routes FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY product_bom_read ON public.product_bom FOR SELECT TO authenticated USING (private.has_permission('master.read'));
CREATE POLICY product_bom_manage ON public.product_bom FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY machines_read ON public.machines FOR SELECT TO authenticated USING (private.has_permission('machines.read'));
CREATE POLICY machines_manage ON public.machines FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY shifts_read ON public.shifts FOR SELECT TO authenticated USING (private.has_permission('master.read'));
CREATE POLICY shifts_manage ON public.shifts FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY shift_instances_read ON public.shift_instances FOR SELECT TO authenticated USING (private.has_permission('production.read') OR private.has_permission('hr.read'));
CREATE POLICY shift_roster_read ON public.shift_roster FOR SELECT TO authenticated USING (private.has_permission('production.read') OR private.has_permission('hr.read'));
CREATE POLICY warehouses_read ON public.warehouses FOR SELECT TO authenticated USING (private.has_permission('master.read') OR private.has_permission('inventory.read'));
CREATE POLICY warehouses_manage ON public.warehouses FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY stock_locations_read ON public.stock_locations FOR SELECT TO authenticated USING (private.has_permission('inventory.read') OR private.has_permission('master.read'));
CREATE POLICY stock_locations_manage ON public.stock_locations FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY defect_categories_read ON public.defect_categories FOR SELECT TO authenticated USING (private.has_permission('master.read') OR private.has_permission('quality.read'));
CREATE POLICY defect_categories_manage ON public.defect_categories FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY downtime_reasons_read ON public.downtime_reasons FOR SELECT TO authenticated USING (private.has_permission('master.read') OR private.has_permission('machines.read'));
CREATE POLICY downtime_reasons_manage ON public.downtime_reasons FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY cost_categories_read ON public.cost_categories FOR SELECT TO authenticated USING (private.has_permission('finance.read') OR private.has_permission('master.read'));
CREATE POLICY cost_categories_manage ON public.cost_categories FOR ALL TO authenticated USING (private.has_permission('master.manage')) WITH CHECK (private.has_permission('master.manage'));
CREATE POLICY inspection_plans_read ON public.inspection_plans FOR SELECT TO authenticated USING (private.has_permission('quality.read') OR private.has_permission('master.read'));
CREATE POLICY inspection_plans_manage ON public.inspection_plans FOR ALL TO authenticated USING (private.has_permission('quality.plans_manage')) WITH CHECK (private.has_permission('quality.plans_manage'));
CREATE POLICY inspection_plan_checks_read ON public.inspection_plan_checks FOR SELECT TO authenticated USING (private.has_permission('quality.read') OR private.has_permission('master.read'));
CREATE POLICY inspection_plan_checks_manage ON public.inspection_plan_checks FOR ALL TO authenticated USING (private.has_permission('quality.plans_manage')) WITH CHECK (private.has_permission('quality.plans_manage'));
CREATE POLICY spare_parts_read ON public.spare_parts FOR SELECT TO authenticated USING (private.has_permission('machines.read'));
CREATE POLICY spare_parts_manage ON public.spare_parts FOR ALL TO authenticated USING (private.has_permission('maintenance.manage')) WITH CHECK (private.has_permission('maintenance.manage'));
CREATE POLICY purchase_orders_read ON public.purchase_orders FOR SELECT TO authenticated USING (private.has_permission('purchasing.read') OR private.has_permission('purchasing.draft'));
CREATE POLICY purchase_order_lines_read ON public.purchase_order_lines FOR SELECT TO authenticated USING (private.has_permission('purchasing.read') OR private.has_permission('purchasing.draft'));
CREATE POLICY purchase_receipts_read ON public.purchase_receipts FOR SELECT TO authenticated USING (private.has_permission('inventory.read') OR private.has_permission('purchasing.read'));
CREATE POLICY yarn_batches_read ON public.yarn_batches FOR SELECT TO authenticated USING (private.has_permission('inventory.read') OR private.has_permission('rolls.read'));
CREATE POLICY movements_read ON public.inventory_movements FOR SELECT TO authenticated USING (private.has_permission('inventory.read'));
CREATE POLICY reservations_read ON public.material_reservations FOR SELECT TO authenticated USING (private.has_permission('inventory.read') OR private.has_permission('production.read'));
CREATE POLICY adjustments_read ON public.stock_adjustments FOR SELECT TO authenticated USING (private.has_permission('inventory.read') OR private.has_permission('inventory.adjust_approve'));
CREATE POLICY cycle_counts_read ON public.cycle_counts FOR SELECT TO authenticated USING (private.has_permission('inventory.read'));
CREATE POLICY cycle_count_lines_read ON public.cycle_count_lines FOR SELECT TO authenticated USING (private.has_permission('inventory.read'));
CREATE POLICY wip_lots_read ON public.wip_lots FOR SELECT TO authenticated USING (private.has_permission('inventory.read') OR private.has_permission('production.read'));
CREATE POLICY cost_entries_read ON public.cost_entries FOR SELECT TO authenticated USING (private.has_permission('finance.read'));

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon,authenticated;
GRANT SELECT ON public.suppliers,public.products,public.yarn_items,public.unit_conversions,public.process_definitions,public.product_routes,public.product_bom,public.machines,public.shifts,public.shift_instances,public.shift_roster,public.warehouses,public.stock_locations,public.defect_categories,public.downtime_reasons,public.cost_categories,public.inspection_plans,public.inspection_plan_checks,public.spare_parts,public.purchase_orders,public.purchase_order_lines,public.purchase_receipts,public.yarn_batches,public.inventory_movements,public.material_reservations,public.stock_adjustments,public.cycle_counts,public.cycle_count_lines,public.wip_lots,public.cost_entries TO authenticated;
GRANT INSERT,UPDATE,DELETE ON public.suppliers,public.products,public.yarn_items,public.unit_conversions,public.process_definitions,public.product_routes,public.product_bom,public.machines,public.shifts,public.warehouses,public.stock_locations,public.defect_categories,public.downtime_reasons,public.cost_categories,public.inspection_plans,public.inspection_plan_checks TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_post_receipt(uuid,uuid,text,jsonb,uuid),public.rpc_reserve_material(uuid,numeric,text,uuid,uuid,uuid),public.rpc_release_reservation(uuid,text),public.rpc_issue_material(uuid,numeric,uuid),public.rpc_request_adjustment(uuid,uuid,numeric,text),public.rpc_decide_adjustment(uuid,text,text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.validate_yarn_movement(),public.set_updated_at(),public.prevent_update_delete() FROM PUBLIC,anon,authenticated;
