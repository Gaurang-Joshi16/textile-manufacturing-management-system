# Everest Textile Mills — Prototype Preview Handoff

**Preview (temporary):** https://4173-if4h7mw2f6wmcuzp77bwg-05d5ee2a.sg2.manus.computer/

This is the React + TypeScript prototype backed by the configured Supabase project. The preview is for testing synthetic demo data only; it is not permanent hosting or a production ERP. Demo account identifiers and passwords are kept in the ignored/private verification report and local `.demo-credentials.json`; never publish those files or the private environment configuration.

## What you can test now

The role-aware shell exposes tabs for system administration, factory management, production supervision, machine operation, stores, quality, dispatch, HR/payroll, finance, and buyer access. The validated core story covers a 2,000 m order, feasibility and planning, yarn-receipt split, material reservation, production output, roll inspection/rework/quarantine, accepted-roll allocation, manifest scanning, dispatch confirmation, and a buyer-safe order timeline. Synthetic scenarios also include the Zenith buyer order/change request, a pending stock count, quality incident/CAPA preview, preventive maintenance example, payroll/cost examples, and the WV-04 breakdown. Some of these are seeded review states, not completed business transactions.

Working interactive areas added or available include manager order create/feasibility/plan/release, split yarn receipt, QC disposition, output capture, machine issue reporting, optional QR-camera/manual roll or machine lookup, demo-only stock-adjustment request, shipment draft/allocation, manual one-roll-at-a-time manifest scanning and reviewed confirmation. Server-side Supabase authorization and validation remain authoritative. Other tabs include live role-scoped lists and partial or read-only surfaces; consult `docs/FINAL_REPORT.md` and `docs/ROLE_COVERAGE_AUDIT.md` for the exact boundaries.

## Local start and verification

```bash
cd web
pnpm install
# Provide VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in a local, untracked .env file
pnpm dev --host 0.0.0.0
pnpm build
```

Never put the service-role key, database password or access token into `web/`, browser variables, or a published bundle. Build verification most recently passed (`tsc -b && vite build`); Vite reports a non-blocking large-chunk advisory. The preview URL is temporary and may stop when its sandbox session ends.

## Private docs and deployment boundary

`docs/FINAL_REPORT.md` includes demo passwords and must remain private. Do not include it in public hosting or the portable source archive. The archive deliberately excludes local `.env` files, credential JSON, private demo passwords, dumps/backups, `node_modules`, and generated build output. The code bundle includes the sanitized continuation status and source. The full folder and report remain in the active sandbox path `/home/ubuntu/everest-textile`.
