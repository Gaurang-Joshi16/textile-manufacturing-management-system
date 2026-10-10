# Role Coverage Delta — 2026-10-10

The detailed [Role Coverage Audit](ROLE_COVERAGE_AUDIT.md) is the original source-level baseline and predates the final preview additions. Its 25% overall feature-surface estimate is not a fresh score for the version now running; no independent role-by-role rescore was performed. These targeted additions do not justify treating every route as complete.

| Role | Now testable in preview | Still incomplete / not claimed |
|---|---|---|
| Factory manager | Existing order create → feasibility → confirm → plan → release flow; updated scenario visibility. | Full settings, exception decisions, reports, costing, and all schedule/dispatch controls. |
| Production supervisor | Live production dispatch board and issue/breakdown action through the status RPC; open maintenance example. | Repair/reschedule workflow, schedule planning, shift close/handover lifecycle, and maintenance closeout. |
| Machine operator | Assigned-operation list; output form calls the protected output RPC; manual machine lookup / optional QR camera. | Complete job-start/pause/complete, WIP transfer, correction, and full UI click-through for assigned-user cases. |
| Storekeeper | Existing receipt posting; pending stock-adjustment request; seeded open count with variance. | Count capture/reconciliation, adjustment approval, reservations/issues/returns, quarantine release and procurement lifecycle. |
| Quality inspector | Inspection queue disposition; roll lookup; seeded open investigation/CAPA preview. | Measurement/defect evidence, incident/CAPA lifecycle, quarantine release/recall and reinspection end-to-end. |
| Dispatch officer | Draft/allocation; individual manual manifest scans; mismatch-reason acknowledgement and separate shipment confirmation. | Dispatch reversal, transfer, document generation/download/retry and full browser verification. |
| Buyer | Buyer-safe list/timeline and isolated Zenith order with pending change request. | Change-request submission/decision UI, buyer documents, acknowledgement, full cross-buyer negative suite. |
| System administrator | Existing identity, roles, automation, integration and audit read surfaces. | Settings mutation, reconciliation workflow, automation execution/retry and full user lifecycle UI. |
| HR/payroll officer | Seeded attendance, roster, skills and non-statutory payroll examples. | Corrections, approval, calculation/review/lock/reopen lifecycle and HR exports. |
| Finance officer | Seeded source-linked costs, draft invoice, expense examples and finance-scoped reads. | Variance/expense approvals, cost review controls, invoice lifecycle and audited exports. |

Build verification passing does not establish an accepted end-to-end workflow. See [Continuation Verification](CONTINUATION_VERIFICATION.md) and the [Final Verification Report](FINAL_REPORT.md); the latter contains synthetic account passwords and is private.
