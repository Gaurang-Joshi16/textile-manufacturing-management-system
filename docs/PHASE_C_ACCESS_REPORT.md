# Phase C — Supabase access report

| Check | Result | Evidence |
|---|---|---|
| REST anon gateway | PASS | PostgREST accepted the anon key; probe returned the expected missing-table schema response before schema creation. |
| Auth settings read | PASS | Supabase Management API returned HTTP 200 using the supplied access token. |
| Database connection | PASS | Direct PostgreSQL connection succeeded. |
| Storage create/list | PASS | Six required buckets created private; subsequent list verified all six. |
| Edge Function deploy/invoke | PASS | `phase-c-hello` deployed and returned the expected health response. |
| `pg_cron` | AVAILABLE, then installed by migration | Listed by `pg_available_extensions`; `CREATE EXTENSION` succeeded. |
| `pg_net` | AVAILABLE, then installed by migration | Listed by `pg_available_extensions`; `CREATE EXTENSION` succeeded. |
| `pgcrypto` | INSTALLED | Present in `pg_extension`. |
| `pg_trgm` | AVAILABLE, then installed by migration | Listed by `pg_available_extensions`; `CREATE EXTENSION` succeeded. |
| Realtime | AVAILABLE | `supabase_realtime` publication exists. |

The verified preview origin is configured as the Supabase Auth site URL and redirect pattern. It is a temporary sandbox URL, not a production domain. No site/domain preference or real administrator identity was supplied; no real administrator account has been created. SMTP, WhatsApp/SMS, MQTT, and external LLM credentials remain unconfigured as required for an honest prototype.
