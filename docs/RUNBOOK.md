# Everest Textile Mills — Prototype Runbook

**Verified:** 2026-10-10. **Status:** internal prototype; not production-ready.

## 1. Preview and configuration

- Temporary preview: https://4173-if4h7mw2f6wmcuzp77bwg-05d5ee2a.sg2.manus.computer/
- Frontend public variables: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`.
- Private project file: `supabase/.env.local` (ignored; never commit or paste into logs). It currently needs `SUPABASE_URL`, `SUPABASE_PROJECT_REF`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_DB_URL`, `SUPABASE_DB_PASSWORD`, and `SUPABASE_ACCESS_TOKEN`.
- The sandbox preview URL and Vite dev server are temporary; configure a stable host, CSP/security headers, TLS, allowed hosts, redirects and CORS before external use.
- SMTP, WhatsApp/SMS, MQTT, external assistant provider and live buyer notifications are not configured. Demo messaging is in-app/simulated only.

## 2. Apply migrations and seed the demo

From the project root:

```bash
python3 scripts/apply_migrations.py
python3 scripts/run_db_tests.py
python3 scripts/seed_demo.py
python3 scripts/test_live_ui_queries.py
```

Migrations are ordered and checksum-tracked. **Never edit an applied migration**; add a new numbered migration. Demo seeding is idempotent and writes only marked synthetic records. The credential and story JSON files are local-only, mode-restricted, and ignored by git.

The seeded user list includes a synthetic system administrator; it does not substitute for the real system administrator identity omitted from the requirements intake. No real administrator was created.

### Demo reset

No destructive reset script is shipped or run. To reset safely, use a fresh isolated Supabase project, apply migrations, then seed again. Do not delete rows using a broad `is_demo` predicate in the active project: cross-module foreign keys and immutable/audit history require a reviewed reset implementation first.

## 3. Build and tests

```bash
cd web
pnpm install --frozen-lockfile
pnpm build
pnpm audit --prod
```

Database, workflow and UI smoke scripts are listed in `FINAL_REPORT.md`. The full E01–E52 suite, concurrency tests and responsive/accessibility passes have **not** been completed; see the report.

## 4. Backup

Supabase’s Free plan has **no automatic database backups**. The official plan docs recommend regular exports. Run:

```bash
./scripts/backup.sh
```

The script uses PostgreSQL 17 `pg_dump`, creates a custom-format full logical archive in ignored `.local-backups/`, sets directory/file permissions to 0700/0600, validates the archive TOC, and locally prunes archives older than seven days. It does not provide off-site storage, monitoring or storage-object backup; protect and copy archives to a separate secure location. Supabase Storage file objects are not included in a database dump.

A verified archive from this session is retained locally in `.local-backups/`; it contains private demo/database metadata and is intentionally not attached or committed.

## 5. Restore test and recovery

A full archive was restored successfully into an isolated local PostgreSQL 17 scratch database. For that test only, unavailable Supabase-managed `pg_net` and `supabase_vault` extension entries were excluded, and encrypted `vault.secrets` rows were not restored; all 116 public tables, 91 public policies, 30 automation-rule rows, 12 demo profiles, and the flagship order/shipment restored and matched expected states. The scratch restored database was deleted after verification. This is an application-schema restore test, **not** a full Supabase Auth/Storage service recovery rehearsal.

For a disaster-recovery rehearsal, use a separate Supabase project with compatible extensions and a separately protected archive. Never experiment against the active project. Inspect before restoring:

```bash
/usr/lib/postgresql/17/bin/pg_restore --list .local-backups/everest-supabase-<timestamp>.dump
```

Restore into a newly created scratch database only, using a PostgreSQL 17+ client and `pg_restore --no-owner --no-acl --exit-on-error`. Provision required Supabase managed extensions and roles, then validate RLS, Auth, Storage metadata, seed counts and a known demo workflow before considering a recovery complete. Do not use `--clean` against the active project.

## 6. Secret rotation (recommended before any external exposure)

The service-role key, database password and Supabase personal access token were supplied in the task conversation. Treat them as exposed and rotate them in the Supabase Dashboard before production or wider sharing:

1. Rotate the service-role/API secret in the project's API settings; update the ignored local config and redeploy Edge Functions.
2. Reset the database password in project database settings; update `SUPABASE_DB_URL` and `SUPABASE_DB_PASSWORD`.
3. Revoke the shared personal access token and create a replacement; update CLI environment configuration.
4. Validate login, migrations and function invocation with the rotated credentials. Never put the service-role key in the frontend.

The compiled frontend secret scan passed: no supplied service-role key, database URL or PAT appeared in `web/dist`.

## 7. Rollback / recovery policy

This project uses forward-only migrations. Review [MIGRATION_ROLLBACK.md](MIGRATION_ROLLBACK.md) before changes. For an applied schema change, prefer a new corrective migration. A database restore is a high-impact replacement and must be performed only in an approved isolated target after checking the backup and outage plan.

## 8. Current operational limitations

- No real administrator account was provisioned because the required real name/email was not supplied.
- No production hosting, stable domain, CI/CD, CSP/security headers, external messaging, integrations, automation runner, scheduled cron jobs, PDF/CSV export pipeline, assistant or QR passport page is deployed.
- Several modules are schema- or read-screen-level only; do not treat their presence as completed business workflows.
- The prototype is demo-only. Do not enter live personal, payroll, supplier, customer, commercial or regulated records.

## References

- [Supabase database backups](https://supabase.com/docs/guides/platform/backups): Pro/Team/Enterprise receive daily backups (7/14 days); Free projects should export regularly. Database dumps do not contain Storage API file objects.
- [Supabase pricing](https://supabase.com/pricing): Free-plan automatic backups are not included.
