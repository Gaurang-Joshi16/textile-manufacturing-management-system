# Remaining objectives — Everest Textile Mills prototype

**Status convention:** Complete only when the behavior is usable and its source data/action is covered by evidence. A tab existing in navigation is not completion. All sample records must be synthetic, schema-valid, idempotently seeded, and marked DEMO; no copied real factory/customer data. Permanent public deployment is out of scope for this preview request.

## Role workspaces and routing — PARTIAL
- `system_admin`: Users & approvals; Roles; Settings; Automations; Integration health; Audit; Reconciliation.
- `factory_manager`: Command centre; Exceptions; Approvals; Orders; Plans; Dispatch board; Machines; Inventory shortages; Quality holds; Dispatch readiness; Costing; Reports; Audit (read).
- `production_supervisor`: Shift board; Dispatch board; Operations; Machines & downtime; Maintenance; Handover; WIP; Tasks.
- `machine_operator`: My jobs; Scan machine; Record output; Report issue.
- `storekeeper`: Receipts; Stock by location; Ledger; Reservations/issues; Quarantine; Adjustments; Counts; RFQ drafts; Shortages.
- `quality_inspector`: Inspection queue; Scan roll; Rework queue; Quarantine; Incidents; Defect analytics; Inspection plans.
- `dispatch_officer`: Ready orders; Eligible rolls; Shipment drafts; Scan manifest; Dispatch history; Documents.
- `hr_payroll_officer`: Roster; Attendance; Corrections; Payroll periods; Skills; Reports.
- `finance_officer`: Order costs; Variance cases; Cost entries; Expenses; Invoices; Exports; Approvals.
- `buyer`: My orders; Order timeline; Documents; Change requests; Notifications.
- Shared: login/signup/forgot/reset, awaiting-approval, profile & sessions, global search, notification centre, roll passport `/r/:token`, permission-denied (explains missing permission), 404, offline/error boundaries. Navigation items render only if the permission exists, and every route is guarded in the router and by RLS/RPC.

## Distinct screens and safe actions — PARTIAL
- Replace generic repeated fallback screens with route-specific pages. Back each list with real role-scoped Supabase queries and clear loading, error, no-record and not-configured states.
- Provide workflow controls only through existing permission-checked RPCs; show the server's human-readable validation result. Never make unsupported routes appear functional merely by adding buttons.
- Expand validated action paths for order feasibility/planning; receiving and ledger visibility; operation assignment/start/output/handover; inspection/rework; shipment allocation/scan/confirm; buyer-safe order timelines. Add remaining CRUD/approval/reversal/document/report flows only where corresponding safe backend support is present.

## Synthetic industry-shaped demo data — PARTIAL
- Keep the existing deterministic flagship order story and its recorded 2,000 m quantity, BOM and receipt split. Preserve its history.
- Add secondary Lotus/Zenith orders and state diversity for planning, production, maintenance, quality, dispatch, approvals, exceptions, handover, HR/payroll and finance routes where schema constraints permit.
- Ensure every row is synthetic and follows existing `is_demo=true` or master `source='DEMO'` markers, has valid foreign keys, stable IDs and idempotent seeding. Never delete existing data during normal seed runs. Do not fabricate measured analytics: values must be derived from seeded rows.
- Include intentional empty/not-configured cases with explanatory UI where a safe example cannot be created; distinguish these from accidental query failures.

## Business modules, reports and platform capabilities — PARTIAL / NOT COMPLETE
- Master-data CRUD/import/deactivation and usage guards.
- Procurement: receipt wizard, batch genealogy, supplier scorecards, adjustments, counts, reservations/issues/returns/waste, quarantine/release, RFQ approval and discrepancy actions.
- Orders/planning: revisions, buyer change requests, blocked/at-risk/ready feasibility states, replanning, deterministic schedule suggestions with explanations.
- Production: machine-lane dispatch board, operator scan/start/pause/output/issue/complete shift, target-vs-actual, WIP, shift close and handover acknowledge/escalation.
- Machines/maintenance/spares and explicitly SIMULATED telemetry.
- Roll passports with genealogy, QR/printable labels and server-calculated next actions.
- Quality incidents, corrective actions, defect analytics, quarantine release, recall drill and rejection/reinspection paths.
- WIP/finished-goods transfers and cycle-count/adjustment paths.
- Dispatch validation/mismatch summary, cancel/reversal, dispatch note/packing list/invoice documents and dispatch suggestion.
- Buyer documents/change requests/dispatch acknowledgement/issues/notification preferences, with strict cross-buyer isolation.
- HR corrections/approval, payroll draft/review/SoD/lock/reopen and expense receipts; payroll stays explicitly non-statutory.
- Finance source-linked Actual/Allocated/Estimated/Missing costs, variance cases, cost summary/drill-through, exports and contribution labelled “Not audited profit.”
- Command-centre KPI formulas and drilldowns; actionable exceptions/tasks/approvals; Realtime notifications; data-quality panel; reports/CSV/PDF/XLSX; global search; guardrailed assistant; automation runner A01–A30 and retry recovery.

## Verification — PARTIAL
- Reconcile every required route against the role navigation, router permission map, backend RLS/RPC enforcement and role login.
- Run live role-scoped read-query smoke checks and database security tests; run `pnpm build` and dependency audit.
- Complete Section 11 E01–E52, Section 18 security/RLS/RPC, concurrency, reconciliation, E2E and scale benchmark tests; report missing tests as NOT RUN rather than passing.
- Test 360/768/1024/1440 responsive layouts, keyboard/focus/accessibility, and the defined UX step-count targets.
- Confirm no service key, DB URL or personal access token appears in the frontend bundle or public artifacts.

## Handover — PARTIAL
- Deliver working project source folder and temporary Live Preview link, role coverage report, seeded data catalogue, feature-by-feature verification report, ten-minute walkthrough and runbook.
- State the temporary URL and its expiry limitations; no permanent site is published by this work.
