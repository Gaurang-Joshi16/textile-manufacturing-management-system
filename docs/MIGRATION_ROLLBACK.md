# Migration rollback notes

All migrations in this prototype have been applied to the target Supabase project and are checksum-tracked. Do **not** edit or rerun a modified version of an applied migration. The supported repair path is a new numbered forward migration. The notes below are recovery guidance, not executable rollback SQL.

| Migration | Change class | Rollback / recovery note |
|---|---|---|
| `0001_foundation.sql` | Identity, RBAC, audit, settings, auth bootstrap and admin RPCs | Foundation is referenced throughout the application. No in-place rollback; restore an isolated pre-migration backup or create a new project. Preserve audit and auth identities. |
| `0002_security_hardening.sql` | Function ACL hardening | Do not blanket-regrant. If a client is blocked, add the exact minimum `GRANT EXECUTE` in a forward migration and re-run anonymous/role tests. |
| `0003_master_inventory.sql` | Textile masters, yarn inventory, RLS, ledger RPCs | Data-bearing and referenced by downstream objects. Keep schema; repair function/policy definitions forward. Dropping requires a verified fresh-project reset. |
| `0004_session_state_guard.sql` | Session/profile state guard | Replace the function forward. Do not weaken disabled/rejected account denial. Revalidate E47 and sign-in. |
| `0005_operational_schema.sql` | Orders, production, quality, dispatch, workforce and finance schema | Core data migration. No safe drop rollback after seed/workflow rows exist; restore an isolated backup or use forward repair. |
| `0006_master_source_metadata.sql` | Source lineage metadata | Preserve all source markers. Do not drop metadata columns after seed. Correct classification with an audited forward update. |
| `0007_rpc_acl_hardening.sql` | RPC execute allowlist | Restore only reviewed procedure grants with a forward ACL migration. Keep anon denied except the exact intended public validation helper. |
| `0008_demo_flags_and_windows.sql` | Demo lineage, MAJOR defect severity, exclusion constraints | Keep demo markers and time-window constraints. Repair invalid rows before changing constraints; do not remove provenance fields. |
| `0009_order_planning_workflows.sql` | Feasibility, order transitions, plan creation/release | Workflow state and feasibility snapshots are durable. Correct function behavior forward; do not delete confirmed orders or snapshots. |
| `0010_inventory_receipt_rfqs.sql` | Receipt, RFQ and stock-view/RPC changes | Ledger rows are immutable. Use compensating movements and forward RPC changes; never edit balances directly. |
| `0011_demo_lineage_markers.sql` | Demo lineage propagation triggers | Replace trigger/function logic forward; retain existing `is_demo` lineage. |
| `0012_production_quality_rpc.sql` | Production output, roll passports and quality RPCs | Rolls/inspections are traceability records. Use forward state-machine corrections; never erase original inspections. |
| `0013_dispatch_rpc.sql` | Shipment allocation, scan, confirmation and invoice draft | Dispatch is irreversible without a compensating workflow. Do not drop/reverse confirmed shipment rows manually. |
| `0014_transition_matrix_gate.sql` | State-machine enforcement | Repair transition matrix/trigger rules forward. Preserve current status and audit chronology. |
| `0015_machine_rpc_only.sql` | Machine status write guard | Keep table writes behind controlled RPCs. Add a narrowly scoped forward procedure if an approved action is missing. |
| `0016_location_qualifiers_and_output_gate.sql` | RPC qualification and roll-output constraint | Function-definition correction only. Restore a prior function body only after reproducing the exact failure and retesting each dependent flow. |
| `0017_finish_location_qualifiers.sql` | Finish-goods/dispatch location lookup correction | Function-definition correction only; re-run quality acceptance and dispatch gates after any forward fix. |
| `0018_demo_inventory_genealogy.sql` | Reservation/ledger lineage and material genealogy | Preserve consumed-batch sources. Repair lineage with audited additive records; do not rewrite historical production output. |
| `0019_quality_location_moves.sql` | Rework/quarantine location movement | Use compensating location movements and state transitions. Never reset a roll status directly. |
| `0020_rework_state_path.sql` | Two-step rework completion transition | Keep the required `REWORK_IN_PROGRESS` and `REINSPECTION_REQUIRED` history; only add forward transitions after QC review. |
| `0021_scan_result_labels.sql` | Manifest result labels | Forward-only function correction; preserve scan event audit records. |
| `0022_stock_view_invoker.sql` | Stock view security-invoker and authenticated SELECT grant | Security-critical. Do not restore owner-executed view behavior or grant anon. If broken, revoke the grant and repair the view as security invoker in a forward migration. |

## Procedure

1. Stop business writes and capture an external backup before any recovery action.
2. Reproduce the issue in an isolated copy; review migration checksums and the `schema_migrations` table.
3. Prefer a narrowly scoped, additive correction migration. Add a regression SQL test and rerun the DB suite.
4. If a restore is unavoidable, restore only to an explicitly approved new target; validate RLS, roles, Auth, Storage metadata and demo tests there before any cutover.
5. No migration in this prototype has a tested automated down migration. Dropping objects or restoring over the active project is not a safe rollback method.
