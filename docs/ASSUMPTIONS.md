# Assumptions and configuration decisions

## Adopted for the prototype

- Company, timezone, currency, date format, week start, shifts, base units, tolerance, alert thresholds, and idle timeouts use the defaults listed in the supplied build specification.
- Prototype/demo authentication uses email confirmation disabled, the in-app-only notification mode (email provider not configured), and optional rather than enforced TOTP. These are the specification's demo-mode choices; production settings must be reviewed before go-live.
- The frontend site URL and redirect allowlist will be set to the actual deployed prototype URL after the hosting URL is established. No guessed production domain is configured.
- Demo data/accounts follow the deterministic story in Section 16, with generated credentials kept out of source control and shown only in the final handover if the seeding gate succeeds.
- Storage buckets are private. `qc-evidence` is capped at 10 MiB and restricted to JPEG, PNG, WebP, and PDF as required.
- No SMTP/email, WhatsApp/SMS, MQTT, or external LLM provider has been supplied; any such feature must show NOT CONFIGURED or SIMULATED, as applicable.

## Unresolved user-specific item

- The required real System Administrator's name and email were not supplied. No real administrator account has been created. The demo admin identity is separate and does not substitute for the required real owner account.

## Phase C observations

- REST anon gateway, Auth settings read, database connection, Storage bucket list/create, and Edge Function deploy/invoke passed.
- `pgcrypto` is installed; `pg_cron`, `pg_net`, and `pg_trgm` are available to install; Supabase Realtime publication exists.
- The PostgreSQL URI password was URI-encoded in the ignored local config because it contains an `@` delimiter. Credentials are not copied into frontend source or this document.
