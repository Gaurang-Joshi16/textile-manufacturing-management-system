# Everest Textile Preview Improvement Plan

## Outcome
A role-correct, data-backed textile-operations prototype that testers can explore in the existing temporary Live Preview. Tabs must resolve to distinct screens backed by permission-appropriate queries or a clearly labelled unavailable/not-configured state. Seeded operational records are deterministic, synthetic, trace-linked, and explicitly marked demo; never use copied personal/customer/factory records.

## Implementation
- Preserve React + TypeScript + Vite and Supabase as the only application data source. Continue using the public anon key/JWT in the browser and existing database RPCs for business writes.
- Reconcile `web/src/navigation.ts`, route permission mapping and screen registry with Section 14.2 and the modules in Sections 9–15. Eliminate duplicate generic fallback routes, show permission-denied and not-configured states honestly, and add working route-specific list/action controls only where backed by existing RLS-safe queries/RPCs.
- Extend the idempotent demo seeder additively. Use fixed synthetic entities, stable IDs, valid foreign keys and DEMO lineage markers; preserve the existing flagship workflow and avoid deletes/resets. Cover empty exception, maintenance, incident, handover, approvals, payroll, finance and secondary buyer/order paths where the schema permits.
- Add role audit, route manifest, seed-data notes, and an updated final readiness report. A visible tab is not counted as functional unless its data and actions are usable and permission-checked.

## Project structure
- `web/src/`: role navigation, route guards, page registry and data-backed UI.
- `web/public/manus-routes.json`: discoverable website/internal page routes.
- `supabase/migrations/`: immutable, ordered schema and RPC history.
- `scripts/`: idempotent synthetic demo scenario seeding and test runners.
- `docs/`: requirements coverage, role audit, demo data catalogue, final verification, runbook and limitations.

## Design
- **Movement:** indigo-dyed workshop ledger: an industrial operations console built for shop-floor clarity.
- **Principles:** role-first navigation; traceable records over decorative metrics; status always expressed in text and icon; synthetic or unconfigured state is explicit.
- **Color philosophy:** deep indigo for control/navigation; teal for safe primary actions; saffron for attention; madder for holds; mist canvas for calm scanning; green only for verified accepted states.
- **Layout:** collapsible left rail with role-filtered links, narrow contextual header, route-specific work area and mobile bottom navigation for floor roles.
- **Signature elements:** textile weave mark; thread-like status timeline; compact monospaced IDs and quantities.
- **Interaction:** list → inspect → explicit RPC action → recorded confirmation; no hidden writes or fictitious success. Empty states point to safe next steps.
- **Motion:** restrained state-change feedback; respect reduced-motion preferences.
- **Typography:** Hanken Grotesk UI, JetBrains Mono for IDs and quantities; consistent 12/14/16/20/24/32 hierarchy.
- **Brand essence:** a precise, traceable factory-workshop ledger for textile teams; grounded, clear, accountable.
- **Voice:** action-specific labels such as “Post receipt” and “Scan manifest”; examples: “No rolls are awaiting inspection.” “This demo action updates synthetic records.”
- **Wordmark/mark:** compact “ET” woven-label square, followed by Everest Textile Mills.
- **Signature color:** weft teal `#0E8C8A`.

## Boundaries
The current hosting target is the temporary Live Preview, not a public permanent deployment. Do not change credentials, Auth security, permissions or production hosting. Do not delete or reset existing records. Do not claim full specification completion, real-world operational validation, statutory payroll compliance, live integrations, or production readiness without specific evidence.
