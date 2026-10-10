#!/usr/bin/env python3
"""Safe, read-only Supabase Phase C connectivity probe.

Loads server credentials from ../supabase/.env.local and prints status only;
never prints environment values, response bodies, or database error text.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENV_FILE = ROOT / "supabase" / ".env.local"


def load_env(path: Path) -> None:
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ[key.strip()] = value.strip().strip('"').strip("'")


def request(url: str, headers: dict[str, str] | None = None) -> tuple[int, bytes]:
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def main() -> int:
    if not ENV_FILE.exists():
        print("Credentials: FAIL (local server env file missing)")
        return 2
    load_env(ENV_FILE)
    url = os.environ["SUPABASE_URL"].rstrip("/")
    project = os.environ["SUPABASE_PROJECT_REF"]
    anon = os.environ["SUPABASE_ANON_KEY"]
    service = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    pat = os.environ["SUPABASE_ACCESS_TOKEN"]
    db_url = os.environ["SUPABASE_DB_URL"]

    # A schema miss proves PostgREST accepted the anon key without reading business data.
    code, body = request(
        f"{url}/rest/v1/phase_c_nonexistent_probe?select=id&limit=1",
        {"apikey": anon, "Authorization": f"Bearer {anon}", "Accept": "application/json"},
    )
    try:
        err = json.loads(body).get("code", "")
    except Exception:
        err = ""
    print(f"REST anon gateway: {'PASS' if code == 404 and err.startswith('PGRST') else 'FAIL'} (HTTP {code})")

    code, _ = request(f"https://api.supabase.com/v1/projects/{project}/config/auth", {"Authorization": f"Bearer {pat}"})
    print(f"Auth settings read: {'PASS' if code == 200 else 'FAIL'} (HTTP {code})")

    code, body = request(f"{url}/storage/v1/bucket", {"apikey": service, "Authorization": f"Bearer {service}"})
    print(f"Storage bucket list: {'PASS' if code == 200 else 'FAIL'} (HTTP {code})")
    if code == 200:
        try:
            buckets = json.loads(body)
            print(f"Storage buckets present: {len(buckets)}")
        except Exception:
            print("Storage bucket response: UNREADABLE")

    try:
        import psycopg

        with psycopg.connect(db_url, connect_timeout=12) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT extname FROM pg_extension")
                installed = {r[0] for r in cur.fetchall()}
                cur.execute("SELECT name FROM pg_available_extensions")
                available = {r[0] for r in cur.fetchall()}
                cur.execute("SELECT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')")
                realtime = bool(cur.fetchone()[0])
                cur.execute("SELECT current_database()")
                cur.fetchone()
        for name in ("pg_cron", "pg_net", "pgcrypto", "pg_trgm"):
            state = "INSTALLED" if name in installed else ("AVAILABLE" if name in available else "UNAVAILABLE")
            print(f"Extension {name}: {state}")
        print(f"Realtime publication: {'AVAILABLE' if realtime else 'NOT FOUND'}")
        print("Database connection: PASS")
    except Exception as exc:
        print(f"Database connection: FAIL ({type(exc).__name__})")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
