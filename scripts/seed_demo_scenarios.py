#!/usr/bin/env python3
"""Additive, deterministic DEMO scenario rows for screens not covered by the flagship story.

This only inserts/upserts synthetic records. It never deletes rows or edits existing business
history. Run after scripts/seed_demo.py and migrations. Demo salaries/costs are examples only.
"""
from __future__ import annotations

import json
import os
import uuid
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path

import psycopg
from psycopg.types.json import Jsonb

ROOT = Path(__file__).resolve().parents[1]
for raw in (ROOT / "supabase" / ".env.local").read_text().splitlines():
    line = raw.strip()
    if line and not line.startswith("#") and "=" in line:
        key, value = line.split("=", 1)
        os.environ[key] = value.strip().strip('"').strip("'")

DB_URL = os.environ["SUPABASE_DB_URL"]
CREDENTIALS = json.loads((ROOT / "supabase" / ".demo-credentials.json").read_text())["accounts"]
ACTORS = {a["alias"]: uuid.UUID(a["user_id"]) for a in CREDENTIALS if a.get("is_demo")}
NS = uuid.UUID("0b30a5f6-cb9f-4a36-a3a2-6d8a5af204c5")
UTC = timezone.utc
NOW = datetime.now(UTC).replace(microsecond=0)
TODAY = NOW.date()

def stable(label: str) -> uuid.UUID:
    return uuid.uuid5(NS, label)

def one(conn, query: str, args=()):
    row = conn.execute(query, args).fetchone()
    if row is None:
        raise RuntimeError("Required synthetic demo source record is missing")
    return row[0]

def insert_demo(conn, table: str, columns: tuple[str, ...], values: tuple, cast_json: tuple[str, ...] = ()) -> None:
    names = ",".join(columns)
    placeholders = []
    for column in columns:
        placeholders.append("%s::jsonb" if column in cast_json else "%s")
    conn.execute(
        f"INSERT INTO public.{table} ({names}) VALUES ({','.join(placeholders)}) "
        "ON CONFLICT (id) DO NOTHING",
        values,
    )

def main() -> None:
    required = {"admin", "manager", "supervisor", "operator1", "storekeeper", "inspector", "dispatch", "hr", "finance", "buyer.lotus", "buyer.zenith"}
    if not required.issubset(ACTORS):
        raise RuntimeError("The required synthetic account set is incomplete; no database rows were written")

    with psycopg.connect(DB_URL, connect_timeout=25) as conn:
        with conn.transaction():
            manager = ACTORS["manager"]
            storekeeper = ACTORS["storekeeper"]
            hr_user = ACTORS["hr"]
            finance = ACTORS["finance"]
            lotus_user = ACTORS["buyer.lotus"]
            zenith_user = ACTORS["buyer.zenith"]

            buyers = dict(conn.execute("SELECT buyer_code,id FROM public.buyers WHERE source='DEMO'"))
            products = dict(conn.execute("SELECT product_code,id FROM public.products WHERE source='DEMO'"))
            employees = dict(conn.execute("SELECT employee_code,id FROM public.employees WHERE source='DEMO'"))
            machines = dict(conn.execute("SELECT machine_code,id FROM public.machines WHERE source='DEMO'"))
            shifts = dict(conn.execute("SELECT name,id FROM public.shifts WHERE source='DEMO'"))
            locations = dict(conn.execute("SELECT code,id FROM public.stock_locations WHERE source='DEMO'"))
            categories = dict(conn.execute("SELECT code,id FROM public.cost_categories WHERE source='DEMO'"))
            if not all(code in buyers for code in ("BUY-LOTUS", "BUY-ZENITH")):
                raise RuntimeError("Synthetic buyer master records are not ready")

            # Two additional, untouched synthetic orders exercise buyer isolation and planning states.
            order_specs = [
                ("ORD-2026-0002", "BUY-ZENITH", "FAB-POPLIN-WHITE", 1200, 210, 14, "CONFIRMED", "DEMO · poplin reorder awaiting plan release"),
                ("ORD-2026-0003", "BUY-LOTUS", "FAB-CANVAS-OLIVE", 800, 245, 28, "DRAFT", "DEMO · canvas seasonal order awaiting feasibility review"),
            ]
            orders: dict[str, uuid.UUID] = {}
            lines: dict[str, uuid.UUID] = {}
            for number, buyer_code, product_code, qty, rate, due_days, status, note in order_specs:
                oid = stable(number)
                lid = stable(number + ":LINE:1")
                buyer_id = buyers[buyer_code]
                product_id = products[product_code]
                existing = conn.execute("SELECT id FROM public.buyer_orders WHERE order_number=%s", (number,)).fetchone()
                if existing and existing[0] != oid:
                    oid = existing[0]
                insert_demo(
                    conn,
                    "buyer_orders",
                    ("id", "order_number", "buyer_id", "requested_date", "promised_date", "status", "priority", "currency", "notes_internal", "notes_buyer", "confirmed_by", "confirmed_at", "created_by", "source", "is_demo", "created_at"),
                    (oid, number, buyer_id, TODAY - timedelta(days=2), TODAY + timedelta(days=due_days), status, "NORMAL", "INR", note, "Synthetic demo order", manager if status == "CONFIRMED" else None, NOW - timedelta(days=1) if status == "CONFIRMED" else None, manager, "DEMO", True, NOW - timedelta(days=2)),
                )
                found_line = conn.execute("SELECT id FROM public.buyer_order_lines WHERE order_id=%s AND line_no=1", (oid,)).fetchone()
                if found_line:
                    lid = found_line[0]
                else:
                    insert_demo(
                        conn,
                        "buyer_order_lines",
                        ("id", "order_id", "line_no", "product_id", "colour", "ordered_qty", "unit", "unit_rate", "spec_overrides", "is_demo"),
                        (lid, oid, 1, product_id, "White" if product_code == "FAB-POPLIN-WHITE" else "Olive", qty, "m", rate, Jsonb({"demo": True}), True),
                    )
                orders[number] = oid
                lines[number] = lid

            flagship_row = conn.execute("SELECT id FROM public.buyer_orders WHERE order_number='ORD-2026-0001' AND is_demo=true").fetchone()
            flagship_id = flagship_row[0] if flagship_row else None
            opening = conn.execute("SELECT id FROM public.yarn_batches WHERE batch_code='DEMO-OPENING-COTTON-400' AND is_demo=true").fetchone()
            if not flagship_id or not opening:
                raise RuntimeError("Flagship order/opening stock is missing; run the core demo seed first")

            # A draft plan is intentionally un-released, so it adds visible planned work without
            # inventing material reservations or falsely counting production output.
            plan_id = stable("PLAN-DEMO-2026-0002")
            already_plan = conn.execute("SELECT id FROM public.production_plans WHERE plan_no='PLAN-DEMO-2026-0002'").fetchone()
            if already_plan:
                plan_id = already_plan[0]
            else:
                insert_demo(
                    conn,
                    "production_plans",
                    ("id", "plan_no", "order_line_id", "planned_qty", "expected_yield_pct", "status", "created_by", "is_demo", "created_at"),
                    (plan_id, "PLAN-DEMO-2026-0002", lines["ORD-2026-0002"], 1200, 97, "DRAFT", manager, True, NOW - timedelta(days=1)),
                )
                route = conn.execute(
                    "SELECT pr.sequence,pr.is_applicable,pr.expected_yield_pct,pd.id,pd.name,pd.code "
                    "FROM public.product_routes pr JOIN public.products p ON p.id=pr.product_id "
                    "JOIN public.process_definitions pd ON pd.id=pr.process_id "
                    "WHERE p.product_code='FAB-POPLIN-WHITE' ORDER BY pr.sequence"
                ).fetchall()
                previous = None
                for sequence, applicable, yield_pct, process_id, stage, process_code in route:
                    op_id = stable(f"PLAN-DEMO-2026-0002:OP:{sequence}")
                    machine_id = machines.get("WV-04") if process_code == "WEAVE" else None
                    insert_demo(
                        conn,
                        "production_operations",
                        ("id", "operation_no", "plan_id", "process_id", "stage", "sequence", "status", "is_not_applicable", "machine_id", "shift_id", "supervisor_id", "planned_start", "planned_end", "target_qty", "unit", "previous_operation_id", "waiting_reason", "at_risk", "created_by", "is_demo", "created_at"),
                        (op_id, f"OP-DEMO-2026-0002-{sequence:02d}", plan_id, process_id, stage, sequence, "COMPLETED" if not applicable else "PLANNED", not applicable, machine_id, shifts.get("Shift A") if process_code == "WEAVE" else None, employees.get("EMP-DEMO-002") if process_code == "WEAVE" else None, NOW + timedelta(days=1, hours=sequence * 2), NOW + timedelta(days=1, hours=sequence * 2 + 4), 1200, "m", previous, "Not applicable in product route" if not applicable else None, False, manager, True, NOW - timedelta(days=1)),
                    )
                    if applicable:
                        previous = op_id

            # Buyer change request remains pending and never mutates the confirmed plan.
            change_id = stable("DEMO-CHANGE-0002-QUANTITY")
            insert_demo(
                conn,
                "order_change_requests",
                ("id", "order_id", "requested_by", "request_type", "payload", "impact_analysis", "status", "is_demo", "created_at"),
                (change_id, orders["ORD-2026-0002"], zenith_user, "QUANTITY", Jsonb({"from": 1200, "to": 1350, "unit": "m"}), Jsonb({"plan_impact": "Review required before any plan change", "additional_yarn_required_kg": 37.152, "buyer_visible": True}), "PENDING", True, NOW - timedelta(hours=5)),
                ("payload", "impact_analysis"),
            )
            insert_demo(
                conn,
                "order_revisions",
                ("id", "order_id", "field", "old_value", "new_value", "reason", "changed_by", "changed_at", "is_demo"),
                (stable("DEMO-REVISION-0002-DUE-DATE"), orders["ORD-2026-0002"], "promised_date", Jsonb((TODAY + timedelta(days=12)).isoformat()), Jsonb((TODAY + timedelta(days=14)).isoformat()), "Synthetic planner estimate updated before buyer confirmation", manager, NOW - timedelta(days=1), True),
                ("old_value", "new_value"),
            )

            # Open physical count with a disclosed 2 kg variance; the ledger is not changed until
            # the separate approved adjustment workflow runs.
            count_id = stable("DEMO-COUNT-RAW-01-2026")
            raw_location = locations.get("RAW-01")
            if raw_location:
                insert_demo(conn, "cycle_counts", ("id", "location_id", "status", "counted_by", "created_at", "is_demo"), (count_id, raw_location, "OPEN", storekeeper, NOW - timedelta(hours=3), True))
                batch_id = opening[0]
                qty_row = conn.execute("SELECT COALESCE(sum(on_hand),0) FROM public.v_yarn_stock WHERE yarn_batch_id=%s AND location_id=%s", (batch_id, raw_location)).fetchone()
                on_hand = float(qty_row[0])
                insert_demo(
                    conn,
                    "cycle_count_lines",
                    ("id", "count_id", "yarn_batch_id", "system_qty", "counted_qty", "is_demo"),
                    (stable("DEMO-COUNT-LINE-RAW-01-OPENING"), count_id, batch_id, on_hand, max(0, on_hand - 2), True),
                )

            # One open quality incident with a marked incomplete genealogy preview. The seed does
            # not silently quarantine or release any roll and does not claim a confirmed root cause.
            incident_id = stable("DEMO-QI-SUSPECT-BATCH-0001")
            insert_demo(
                conn,
                "quality_incidents",
                ("id", "incident_no", "trigger", "status", "root_cause", "details", "opened_by", "is_demo", "created_at"),
                (incident_id, "QI-DEMO-2026-0001", "SUSPECT_BATCH", "INVESTIGATING", None, Jsonb({"batch_id": str(opening[0]), "batch_code": "DEMO-OPENING-COTTON-400", "review_state": "For review; no root cause confirmed", "genealogy_complete": False, "containment": "Preview only; hold requires an authorised confirmation"}), ACTORS["inspector"], True, NOW - timedelta(hours=4)),
                ("details",),
            )
            first_roll = conn.execute("SELECT id FROM public.fabric_rolls WHERE is_demo=true ORDER BY created_at,id LIMIT 1").fetchone()
            if first_roll and flagship_id:
                insert_demo(
                    conn,
                    "quality_incident_rolls",
                    ("id", "incident_id", "roll_id", "order_id", "genealogy_complete", "action_taken", "is_demo"),
                    (stable("DEMO-QI-ROLL-PREVIEW-0001"), incident_id, first_roll[0], flagship_id, False, "Trace preview only; no hold or buyer communication was confirmed", True),
                )
            insert_demo(
                conn,
                "corrective_actions",
                ("id", "incident_id", "type", "description", "owner_id", "due_date", "status", "is_demo"),
                (stable("DEMO-CA-SUPPLIER-0001"), incident_id, "SUPPLIER", "Review the supplier lot inspection evidence and submit a documented disposition.", employees.get("EMP-DEMO-017"), TODAY + timedelta(days=3), "OPEN", True),
            )

            # Maintenance and planned-maintenance schedule on a separate machine, not the breakdown
            # demonstration machine. These are fixture examples, not completed work.
            fn_id = machines.get("FN-01")
            if fn_id:
                wo_id = stable("DEMO-MAINT-WO-2026-0001")
                insert_demo(
                    conn,
                    "maintenance_schedules",
                    ("id", "machine_id", "type", "interval_days", "interval_hours", "next_due", "is_demo"),
                    (stable("DEMO-MAINT-SCHEDULE-FN01"), fn_id, "PREVENTIVE", 30, 250, NOW + timedelta(days=6), True),
                )
                insert_demo(
                    conn,
                    "maintenance_work_orders",
                    ("id", "wo_number", "machine_id", "type", "status", "due_at", "window_start", "window_end", "assigned_to", "spares_ready", "is_demo", "created_at", "updated_at"),
                    (wo_id, "MWO-DEMO-2026-0001", fn_id, "PREVENTIVE", "OPEN", NOW + timedelta(days=6), NOW + timedelta(days=6), NOW + timedelta(days=6, hours=2), employees.get("EMP-DEMO-016"), True, True, NOW - timedelta(days=2), NOW - timedelta(days=2)),
                )

            # Example payroll snapshot and detail rows are synthetic, role-protected, and explicitly
            # non-statutory. The period is calculated but intentionally not approved or locked.
            payroll_rule = one(conn, "SELECT id FROM public.payroll_rules WHERE name='Example monthly payroll — not statutory' ORDER BY version DESC LIMIT 1")
            period_id = stable("DEMO-PAYROLL-2026-CURRENT-MONTH")
            period_start = TODAY.replace(day=1)
            period_end = TODAY
            rule_snapshot = {"label": "Example rules — not statutory", "monthly_base_pay_inr": 25000, "overtime_multiplier": 1.5, "rounding": "nearest rupee", "confirmed_policy": False}
            insert_demo(
                conn,
                "payroll_periods",
                ("id", "period_no", "period_start", "period_end", "status", "rules_id", "rules_snapshot", "calculated_by", "approved_by", "needs_recalc", "is_demo", "created_at"),
                (period_id, f"DEMO-PAY-{period_start:%Y-%m}", period_start, period_end, "CALCULATED", payroll_rule, Jsonb(rule_snapshot), hr_user, None, False, True, NOW - timedelta(hours=12)),
                ("rules_snapshot",),
            )
            employee_rows = conn.execute("SELECT employee_code,id FROM public.employees WHERE source='DEMO' ORDER BY employee_code").fetchall()
            for ix, (employee_code, employee_id) in enumerate(employee_rows, 1):
                base_pay = 25000
                overtime = (ix % 4) * 375
                allowance = 500 if ix % 3 == 0 else 0
                deduction = 250 if ix % 7 == 0 else 0
                net = base_pay + overtime + allowance - deduction
                insert_demo(
                    conn,
                    "payroll_lines",
                    ("id", "period_id", "employee_id", "base_pay", "overtime_pay", "allowances", "deductions", "advances", "reimbursements", "net_pay", "calc_breakdown", "is_demo"),
                    (stable(f"DEMO-PAYLINE-{period_id}-{employee_code}"), period_id, employee_id, base_pay, overtime, allowance, deduction, 0, 0, net, Jsonb({"calculation": "synthetic example only", "attendance_rows": 14, "rule_snapshot": rule_snapshot}), True),
                    ("calc_breakdown",),
                )
            insert_demo(
                conn,
                "payroll_adjustments",
                ("id", "period_id", "employee_id", "type", "amount", "note", "created_by", "is_demo", "created_at"),
                (stable("DEMO-PAYROLL-ALLOWANCE-001"), period_id, employees["EMP-DEMO-008"], "ALLOWANCE", 500, "Synthetic transport allowance example", hr_user, True, NOW - timedelta(hours=10)),
            )

            # Finance basis examples link to source records; the deliberately absent DISPATCH line is
            # surfaced as Missing by finance views instead of inventing an amount.
            shipment_row = conn.execute("SELECT id FROM public.shipments WHERE order_id=%s AND is_demo=true ORDER BY created_at DESC LIMIT 1", (flagship_id,)).fetchone()
            line_row = conn.execute("SELECT id FROM public.buyer_order_lines WHERE order_id=%s ORDER BY line_no LIMIT 1", (flagship_id,)).fetchone()
            op_row = conn.execute("SELECT id FROM public.production_operations WHERE plan_id IN (SELECT id FROM public.production_plans WHERE order_line_id=%s) ORDER BY sequence LIMIT 1", (line_row[0],)).fetchone() if line_row else None
            source_map = {
                "MATERIAL": ("YARN_BATCH", opening[0], 79872, "665.6 kg × ₹120/kg synthetic material basis", "ACTUAL"),
                "LABOUR": ("PAYROLL_LINE", stable(f"DEMO-PAYLINE-{period_id}-EMP-DEMO-002"), 8400, "Allocated example; operation minutes share documented for the period", "ALLOCATED"),
                "MACHINE": ("PRODUCTION_OPERATION", op_row[0] if op_row else None, 1800, "Estimated loom time pending approved machine-rate source", "ESTIMATED"),
                "PACKAGING": ("SHIPMENT", shipment_row[0] if shipment_row else None, 1250, "Synthetic packing cost linked to the posted shipment", "ACTUAL"),
            }
            for category, (source_type, source_id, amount, description, basis) in source_map.items():
                if category not in categories or source_id is None:
                    continue
                insert_demo(
                    conn,
                    "cost_entries",
                    ("id", "order_id", "order_line_id", "operation_id", "shipment_id", "category_id", "description", "amount", "currency", "cost_basis", "source_type", "source_id", "source_ref", "external_id", "idempotency_key", "created_by", "created_at", "is_demo"),
                    (stable(f"DEMO-COST-{category}-ORD0001"), flagship_id, line_row[0] if line_row else None, op_row[0] if op_row and source_type == "PRODUCTION_OPERATION" else None, shipment_row[0] if shipment_row and source_type == "SHIPMENT" else None, categories[category], description, amount, "INR", basis, source_type, source_id, f"DEMO:{source_type}:{source_id}", f"DEMO-COST-{category}-ORD0001", stable(f"DEMO-COST-KEY-{category}-ORD0001"), finance, NOW - timedelta(days=1), True),
                )
                insert_demo(
                    conn,
                    "order_cost_plans",
                    ("id", "order_id", "category_id", "planned_amount", "planned_qty", "assumptions", "is_demo"),
                    (stable(f"DEMO-COST-PLAN-{category}-ORD0001"), flagship_id, categories[category], amount * 0.9, 2000, Jsonb({"basis": "planning estimate", "currency": "INR", "unit": "m", "demo": True}), True),
                    ("assumptions",),
                )
            variance_id = stable("DEMO-COST-VARIANCE-ORD0001-MATERIAL")
            if "MATERIAL" in categories:
                insert_demo(
                    conn,
                    "cost_variance_cases",
                    ("id", "order_id", "category_id", "variance_amount", "variance_pct", "status", "breakdown", "is_demo", "created_at"),
                    (variance_id, flagship_id, categories["MATERIAL"], 7987.2, 10, "OPEN", Jsonb({"planned_inr": 71884.8, "recorded_inr": 79872, "reason": "Synthetic example variance; verify the source and assumptions", "denominator": "planned amount"}), True, NOW - timedelta(hours=6)),
                    ("breakdown",),
                )

            expense_id = stable("DEMO-EXPENSE-2026-0001")
            if "OTHER" in categories:
                insert_demo(
                    conn,
                    "expenses",
                    ("id", "expense_no", "employee_id", "category_id", "order_id", "amount", "currency", "status", "external_id", "is_demo", "created_at"),
                    (expense_id, "EXP-DEMO-2026-0001", employees["EMP-DEMO-017"], categories["OTHER"], orders["ORD-2026-0002"], 1840, "INR", "SUBMITTED", "DEMO-EXPENSE-2026-0001", True, NOW - timedelta(hours=8)),
                )
                insert_demo(
                    conn,
                    "approval_requests",
                    ("id", "request_type", "entity_type", "entity_id", "payload", "requested_by", "reason", "required_permission", "status", "deadline", "impact_summary", "is_demo", "created_at"),
                    (stable("DEMO-APPROVAL-EXPENSE-0001"), "EXPENSE_APPROVAL", "expenses", expense_id, Jsonb({"amount": 1840, "currency": "INR", "status": "SUBMITTED"}), hr_user, "Review synthetic receipt/expense example; approve only after evidence", "expenses.approve", "PENDING", NOW + timedelta(days=2), Jsonb({"recorded_cost_on_approval": True, "demo": True}), True, NOW - timedelta(hours=8)),
                    ("payload", "impact_summary"),
                )

            # A private buyer-safe draft document record is intentionally pending generation; it has
            # no file/signature and is not exposed as a downloadable document.
            if shipment_row:
                insert_demo(
                    conn,
                    "documents",
                    ("id", "doc_type", "entity_type", "entity_id", "version", "status", "attempts", "buyer_shareable", "is_demo", "created_at"),
                    (stable("DEMO-DOC-SHIPMENT-PACKING-LIST"), "PACKING_LIST", "shipment", shipment_row[0], 1, "PENDING", 0, False, True, NOW - timedelta(hours=2)),
                )

            # Synthetic telemetry is strictly segregated from production decisions.
            for machine_code, machine_id in machines.items():
                for metric, value, unit, offset in (("temperature", 41 + len(machine_code), "C", 5), ("vibration", 1.2 + (len(machine_code) % 3) / 10, "mm/s", 10), ("counter", 1820 + len(machine_code) * 17, "cycles", 15)):
                    insert_demo(
                        conn,
                        "machine_telemetry",
                        ("id", "machine_id", "metric", "value", "unit", "recorded_at", "event_key", "is_simulated", "is_demo"),
                        (stable(f"DEMO-TELEMETRY-{machine_code}-{metric}"), machine_id, metric, value, unit, NOW - timedelta(minutes=offset), f"demo-telemetry:{machine_code}:{metric}:v1", True, True),
                    )

            # A pending task and role-scoped in-app notice give supervisors, stores, QC, HR, finance,
            # dispatch and buyer accounts distinct records to inspect without leaking other buyers.
            task_id = stable("DEMO-TASK-ORDER-PLAN-0002")
            insert_demo(
                conn,
                "tasks",
                ("id", "task_no", "title", "description", "assignee_user_id", "assignee_role", "due_at", "status", "entity_type", "entity_id", "checklist", "created_by", "is_demo", "created_at"),
                (task_id, "TSK-DEMO-2026-0002", "Review Lotus order timeline", "Confirm feasibility, materials and an estimated production window before releasing a plan.", manager, "factory_manager", NOW + timedelta(days=1), "OPEN", "buyer_orders", orders["ORD-2026-0002"], Jsonb(["Review BOM and stock", "Confirm due-date estimate", "Create/release plan when ready"]), manager, True, NOW - timedelta(hours=4)),
                ("checklist",),
            )
            notices = [
                ("manager", "ORDER_RISK", "Review order feasibility", "Zenith poplin order ORD-2026-0002 needs feasibility and a plan review.", "buyer_orders", orders["ORD-2026-0002"], "/orders"),
                ("supervisor", "MACHINE_BREAKDOWN", "Breakdown requires response", "WV-04 breakdown status is part of the synthetic demo story; review downtime and affected work.", "machines", machines.get("WV-04"), "/machines"),
                ("storekeeper", "CYCLE_COUNT", "Cycle count variance awaiting review", "A synthetic 2 kg count difference is not posted to the ledger until approved.", "cycle_counts", count_id, "/stores/counts"),
                ("inspector", "QUALITY_INCIDENT", "Suspect batch review", "A demo incident is under investigation; genealogy is explicitly incomplete and containment is not confirmed.", "quality_incidents", incident_id, "/quality/incidents"),
                ("dispatch", "DISPATCH_READY", "Dispatch history available", "Review the existing synthetic dispatch and pending document-generation record.", "shipments", shipment_row[0] if shipment_row else None, "/dispatch/history"),
                ("hr", "PAYROLL_REVIEW", "Example payroll period ready for review", "Example rules — not statutory. This calculated demo period is not approved or locked.", "payroll_periods", period_id, "/hr/payroll"),
                ("finance", "COST_VARIANCE", "Review demo cost variance", "Amounts are synthetic examples with source-basis labels; not audited profit.", "cost_variance_cases", variance_id, "/finance/variance"),
                ("buyer.zenith", "ORDER_UPDATE", "Order timeline has a pending change request", "A synthetic quantity request is pending review and has not changed the confirmed plan.", "order_change_requests", change_id, "/portal/changes"),
            ]
            for alias, kind, title, body, entity_type, entity_id, route in notices:
                if entity_id is None:
                    continue
                insert_demo(
                    conn,
                    "notifications",
                    ("id", "user_id", "type", "severity", "title", "body", "entity_type", "entity_id", "action_url", "dedupe_key", "is_demo", "created_at"),
                    (stable(f"DEMO-NOTICE-{alias}-{kind}"), ACTORS[alias], kind, "MEDIUM", title, body, entity_type, entity_id, route, f"demo:{alias}:{kind}:v1", True, NOW - timedelta(minutes=20)),
                )

    print("Synthetic demo scenario seed complete (idempotent/additive): two buyer orders, draft plan, order change/revision, open count, quality incident, corrective action, maintenance schedule/work order, 24 payroll lines, source-linked cost examples, one pending expense/document, 21 simulated telemetry readings, task, and role-targeted in-app notices.")
    print("No existing rows were deleted or updated; generated values and payroll rules are synthetic, non-statutory demo examples.")

if __name__ == "__main__":
    main()
