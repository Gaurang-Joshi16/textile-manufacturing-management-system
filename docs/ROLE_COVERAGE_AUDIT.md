# Everest Textile — Role Coverage Audit

**Audience:** Product owner  
**Audit basis:** Ten independent role audits of the supplied specification and frontend source (`web/src/navigation.ts`, `web/src/App.tsx`, `web/src/LivePages.tsx`, `web/src/services/data.ts`).  
**Important boundary:** This is a **source-level feature-surface audit**. The auditors did **not** run live database queries, inspect live row contents, or claim that RLS/RPC behavior was verified in a deployed database. A visible tab is counted only as functional when its data and meaningful actions are wired; a list-only surface is partial.

## Executive summary

All ten requested roles were audited; none is missing. Navigation coverage is broad, but working workflow coverage is shallow. Only two role surfaces contain a substantial end-to-end path in the inspected UI: the **factory manager's order → feasibility → confirmation → plan/release flow** and the **storekeeper's receipt posting path** (the latter remains partial because it is not PO-linked). The remaining roles are primarily read-only lists, limited queue decisions, or generic/static placeholders.

### Overall current readiness

**25% rough feature-surface estimate (not a passed acceptance-test percentage).**

Method: the independent role estimates are **28%, 32%, 15%, 15%, 40%, 25%, 38%, 18%, 18%, and 25%**. Their arithmetic mean is **25.4%**, rounded to the nearest 5% = **25%**. This estimate reflects judged usability of required role workflows, not visual polish, database completeness, production readiness, or the percentage of acceptance tests passed. The final verification report separately records selected integration tests passing while the full E01–E52, browser workflow, concurrency, accessibility, responsive, performance-at-scale, provider-integration, and production gates were not run.

## Role-by-role coverage

| Role | Required tabs | Functional | Partial / read-only | Inactive / placeholder / inaccessible | Estimated readiness |
|---|---|---|---|---|---:|
| **System administrator** | Users & approvals; Roles; Settings; Automations; Integration health; Audit; Reconciliation | Audit: query-backed capped read-only audit list | Users & approvals; Roles; Automations; Integration health: lists without management/retry actions | Settings; Reconciliation: generic shells; no settings or reconciliation workflow | **28%** |
| **Factory manager** | Command centre; Exceptions; Approvals; Orders; Plans; Dispatch board; Machines; Inventory shortages; Quality holds; Dispatch readiness; Costing; Reports; Audit (read) | Orders: meaningful order → feasibility → confirmation → plan creation/release path | Command centre; Exceptions; Approvals; Plans; Machines; Inventory shortages; Quality holds; Dispatch readiness; Costing: mostly lists or limited actions | Dispatch board; Reports: static/generic; Audit: hidden/denied under the specified default grant conflict | **32%** |
| **Production supervisor** | Shift board; Dispatch board; Operations; Machines & downtime; Maintenance; Handover; WIP; Tasks | None end-to-end | Shift board; Operations; Machines & downtime; Maintenance; Handover; Tasks: read-only lists | Dispatch board: static lanes/no-op schedule; WIP: generic landing/no query | **15%** |
| **Machine operator** | My jobs; Scan machine; Record output; Report issue | None | My jobs: assigned-operation list only | Scan machine: scanner/manual lookup no-op; Record output: generic table/no output RPC; Report issue: generic fallback/no downtime form | **15%** |
| **Storekeeper** | Receipts; Stock by location; Ledger; Reservations / issues; Quarantine; Adjustments; Counts; RFQ drafts; Shortages | Stock by location; Ledger: usable read lists only (not complete mutation workflows) | Receipts; Reservations / issues; Quarantine; Shortages: limited receipt/list surfaces, no complete actions | Adjustments; Counts; RFQ drafts: no query/action path; generic stock-like fallback | **40%** |
| **Quality inspector** | Inspection queue; Scan roll; Rework queue; Quarantine; Incidents; Defect analytics; Inspection plans | None complete | Inspection queue: limited Pass/Rework/Quarantine RPC path; Rework queue; Quarantine: lists without linked actions/release | Scan roll: no-op scanner/lookup; Incidents; Defect analytics; Inspection plans: generic placeholders | **25%** |
| **Dispatch officer** | Ready orders; Eligible rolls; Shipment drafts; Scan manifest; Dispatch history; Documents | Eligible rolls: accepted-roll read list only | Ready orders; Shipment drafts; Dispatch history: limited/misfiltered lists and shipment actions | Scan manifest: no-op scanner/lookup; Documents: generic/mislabelled readiness screen | **38%** |
| **HR & payroll officer** | Roster; Attendance; Corrections; Payroll periods; Skills; Reports | None complete | Roster; Attendance; Payroll periods; Skills: read lists with no lifecycle actions | Corrections; Reports: generic/static; dedicated payroll screen is bypassed by earlier LivePage routing | **18%** |
| **Finance officer** | Order costs; Variance cases; Cost entries; Expenses; Invoices; Exports; Approvals | None complete | Order costs; Cost entries; Expenses; Invoices; Approvals: raw/read-only lists | Variance cases; Exports: static FinanceScreen placeholders | **18%** |
| **Buyer** | My orders; Order timeline; Documents; Change requests; Notifications | None complete | My orders; Order timeline: buyer-safe read RPCs, but incomplete fields/thread and first-order-only behavior | Documents; Change requests; Notifications: generic empty states/no workflows | **25%** |

**Role estimate caveat:** These percentages are deliberately rough and conservative. They credit usable read/decision surfaces but do not credit a tab merely because it is present in navigation. No role reached a complete, end-to-end implementation of all required tabs.

## Repeated root causes

1. **Navigation is ahead of implementation.** Most required tabs are declared in `navigation.ts`, but `App.tsx` routes many paths to one generic `TableScreen`/`LandingView`; several screens have no query, form, or mutation at all.
2. **Shared list scaffold instead of role workflows.** `LivePages.tsx` supplies capped, generic table reads (generally up to 50 rows) and only a small number of specialized actions. Many business workflows lack role-specific forms, detail views, validation, status transitions, audit confirmation, and error handling.
3. **Missing action/RPC wiring.** Core actions are absent across operations, downtime, maintenance, handover, tasks, inventory adjustments/counts/RFQs, quality incidents/plans/rework release, HR corrections/payroll, finance decisions/exports, buyer requests/documents, and admin settings/recovery.
4. **Scanner and lookup controls are inert.** Machine scan, roll scan, and manifest scan screens show unavailable/no-op controls rather than a working camera or manual identifier lookup with server-confirmed outcomes.
5. **Duplicate or unreachable UI paths.** Live-path dispatch occurs before older specialized branches in `App.tsx`; examples include the dedicated payroll and buyer timeline paths. This creates conflicting implementations and makes a seemingly richer component unreachable.
6. **Empty-state ambiguity.** With missing frontend Supabase variables, the app reports not configured or returns empty lists; with a configured client, no rows can mean no seed/workflow records, RLS scope, or a legitimate status filter. Placeholder screens are empty because they have no query. The audit did not distinguish these cases through a live database check.
7. **Read surfaces are mistaken for workflow completion.** A query-backed table can be useful, but it does not prove create/update/approve/release/scan/reconcile/export capability, idempotency, audit history, or role-correct server authorization.

## Permission and routing concerns

- **Frontend guards are not backend authorization evidence.** `App.tsx` filters navigation and direct routes by a permission key plus nav membership, but the audits did not execute live RLS/RPC tests. Server-side policies and RPC checks must remain the source of truth.
- **Factory manager contradictions:** the required Audit (read) tab is mapped to `audit.read`, while the specified default factory-manager grants omit it. Dispatch readiness exposes create/allocate/confirm controls although the default manager grants list read/reversal permissions rather than those dispatch mutations. These are inferred code/spec mismatches, not observed live denials.
- **Storekeeper route gaps:** `/stores/adjustments`, `/stores/counts`, and `/stores/rfq` lack frontend route-permission mappings, so nav/deep-link protection is weaker than required even if backend controls might still protect writes.
- **System admin granularity:** Users & approvals is guarded by `users.manage` while approval is a distinct `users.approve` permission; Reconciliation is coupled to `settings.manage` because no reconciliation-specific permission is defined. Any future action must enforce the narrower permission server-side.
- **Action-vs-read coupling:** Quality queue/holds/rework routes are exposed with `quality.read` even though actions need stronger inspect/release/reject/quarantine permissions. Finance entries/invoices are similarly gated by action permissions rather than cleanly separating page read from mutation rights.
- **HR routing:** Corrections is mapped to `attendance.approve`, which may hide the page from an HR user who should be able to submit corrections but not approve them; HR reports use broad `reports.read` despite HR-only export expectations.
- **Machine operator scope:** operator routes do not map the required `machines.status`/`machines.downtime` action permissions, and Report issue has no dedicated action path. The job → scan → output flow is detached.
- **Buyer-safe routing:** Buyer access is correctly intended to use buyer-scoped RPCs rather than operational tables, but `/orders/order` is guarded by `orders.read` and is not reachable by the buyer's `buyer.portal` grant. Portal documents, changes, and notifications share a broad portal guard but have no implementations.
- **Deep-link behavior:** A valid permission alone may not be enough; the current guard also requires the exact path to be in the selected role's nav. This can hide/deny a route after a permission change and should be covered by a route/permission matrix test.

## Major shared modules missing working UX

- **Production control:** operation assignment/state transitions, shift start/close, target-vs-actual review, output entry, WIP movement, downtime, maintenance actions, handover compilation/acknowledgement, and actionable task assignment.
- **Inventory/procurement:** PO-linked receipts, reservation/issue/return, quarantine release, adjustment requests/approvals, cycle counts, shortage calculation, and RFQ draft generation/review.
- **Quality:** scan/manual roll lookup, plan/check capture, measurements/defects/evidence, Reject and reasoned hold/release, rework start/complete with forced reinspection, incidents/CAPA, and defect analytics.
- **Dispatch/documents:** true order-scoped readiness, shipment-draft review, physical/manual manifest scans with duplicate/mismatch states, dispatch history/reversal, and generated document status/retry/download.
- **HR/payroll:** attendance entry/correction/approval, overtime, payroll calculation and adjustment review, lock/reopen, statutory disclaimer handling, skills maintenance, and HR-scoped reports/exports.
- **Finance:** order-cost aggregation (planned/actual/allocated/estimated/missing), variance cases, cost entry reversal, expense SoD approval, invoice review/document handling, approval decisions, and audited CSV/XLSX exports.
- **Buyer/communications:** multi-order timeline with quantity/date freshness, buyer-safe documents/signed links, change/quality/quantity requests, dispatch acknowledgement, notification feed/preferences, and outbound notification execution.
- **Administration/integrations:** user lifecycle and role assignment, settings, automation runner/history/retry, integration health/retry, reconciliation, filtering/pagination/drill-down, and audit-friendly management actions.

## Prioritized implementation plan

### P0 — Make the product honest and safe

1. **Reconcile the permission contract first.** Produce one machine-readable role × route × action matrix from the spec; resolve manager Audit and dispatch contradictions, storekeeper unmapped routes, HR correction/report intent, quality action granularity, operator machine permissions, and buyer deep links. Add automated positive/negative route tests and server-side RPC/RLS tests; do not treat frontend guards as sufficient.
2. **Remove misleading fallbacks.** Replace generic duplicate screens with explicit `Not implemented`, `Not configured`, `No visible records`, and `Query error` states. Remove or connect unreachable payroll/timeline branches. Ensure every visible tab has a unique route manifest and a declared data/action contract.
3. **Implement the critical floor loop.** Deliver operator assigned jobs → machine/manual lookup → start/pause/complete → validated output/roll creation → issue/downtime, plus supervisor assignment/shift close/handover. Enforce assigned-machine/job scope, idempotency, closed-shift rules, and audit outcomes.
4. **Implement inspection-to-dispatch safety gates.** Deliver real roll/manifest lookup, plan-driven QC capture with PASS/REWORK/REJECT/QUARANTINE, linked reinspection and release, mismatch acknowledgement, and server-confirmed shipment scanning. Do not auto-mark every allocated roll as scanned.

### P1 — Complete inventory and control workflows

5. **Finish store/inventory flows:** PO-linked receipt selection and disposition, reservations/issues/returns, quarantine release, shortage predicate, adjustment approval, cycle counts, and RFQ draft generation/review.
6. **Finish manager control surfaces:** actionable exceptions/approvals, live dispatch board, machine/maintenance decisions, quality-hold/incident drill-down, dispatch readiness, and costing/variance summaries.
7. **Finish HR/payroll and finance:** corrections/attendance approval and overtime, payroll calculate/review/lock/reopen, skills/expiry visibility, finance approval decisions, cost/variance source drill-through, invoice review, and audited exports with SoD controls.

### P2 — Complete admin, buyer, and operational scale UX

8. **Deliver admin and integration operations:** user lifecycle/approvals, role assignments, settings, automation execution/history/retry, integration health/retry, reconciliation, and audit filters/pagination/drill-down.
9. **Deliver buyer portal and communications:** order selection and complete timeline, documents, change/issue requests, dispatch acknowledgement, notifications/preferences, and provider-backed delivery states. Keep unconfigured providers explicitly labelled until credentials and delivery tests exist.
10. **Harden and validate:** pagination/filtering, accessibility/responsive checks, concurrency/idempotency tests, seeded empty/error/RLS states, document retry behavior, performance benchmarks at representative scale, full acceptance suite, and a browser click-through for every role's primary workflow.

## Evidence and limitations

- **Role evidence:** the ten independent audit outputs are preserved in `/home/ubuntu/.manus-jobs/548d37c1ac28_a0/output.txt` through `..._a9/output.txt` (system administrator through buyer). They cite the relevant spec and source lines for each classification and estimate.
- **Project evidence:** `docs/FINAL_REPORT.md` reports selected backend/integration checks and the demo path, but explicitly says many UI pages are list/detail or partial-action prototypes; full E01–E52, concurrency, accessibility, responsive, provider, and production gates were not completed.
- **No live database claim:** this report does not assert that any listed row exists, is absent, or is visible under a deployed account. Empty lists may reflect configuration, seed state, status filters, RLS, or unimplemented query paths. The product owner should treat the next validation step as a role-by-role browser and live-environment authorization test after the P0 routing/action work.
