#!/usr/bin/env python3
"""Activate the synthetic WV-04 breakdown through the authenticated server RPC.

Uses the ignored synthetic demo-account file and the production-supervisor permission path. It never prints
credentials, tokens, or returned record contents. Re-running is a no-op while WV-04 is already
in BREAKDOWN state.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from pathlib import Path

import psycopg

ROOT = Path(__file__).resolve().parents[1]
for raw in (ROOT / "supabase" / ".env.local").read_text().splitlines():
    line = raw.strip()
    if line and not line.startswith("#") and "=" in line:
        key, value = line.split("=", 1)
        os.environ[key] = value.strip().strip('"').strip("'")

BASE = os.environ["SUPABASE_URL"].rstrip("/")
ANON = os.environ["SUPABASE_ANON_KEY"]
ACCOUNTS = json.loads((ROOT / "supabase" / ".demo-credentials.json").read_text())["accounts"]
SUPERVISOR = next(account for account in ACCOUNTS if account.get("alias") == "supervisor")

def request(path: str, method: str, body: dict | None = None, token: str | None = None):
    headers = {"apikey": ANON, "Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(
        BASE + path,
        data=None if body is None else json.dumps(body).encode(),
        headers=headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=25) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            payload = json.loads(raw) if raw else {}
        except Exception:
            payload = {}
        return error.code, payload


def main() -> None:
    with psycopg.connect(os.environ["SUPABASE_DB_URL"], connect_timeout=25) as conn:
        row = conn.execute("SELECT id,status FROM public.machines WHERE machine_code='WV-04' AND source='DEMO'").fetchone()
    if row is None:
        raise RuntimeError("Synthetic machine WV-04 is missing")
    machine_id, current = str(row[0]), row[1]
    if current == "BREAKDOWN":
        print("WV-04 demo breakdown already active; no write performed.")
        return
    if current not in ("IDLE", "SETUP"):
        raise RuntimeError(f"WV-04 is {current}; refusing to force a state transition")

    code, session = request(
        "/auth/v1/token?grant_type=password",
        "POST",
        {"email": SUPERVISOR["email"], "password": SUPERVISOR["password"]},
    )
    token = session.get("access_token") if code == 200 and isinstance(session, dict) else None
    if not token:
        raise RuntimeError(f"Synthetic supervisor authentication failed (HTTP {code})")

    code, result = request(
        "/rest/v1/rpc/rpc_set_machine_status",
        "POST",
        {
            "p_machine_id": machine_id,
            "p_new_status": "BREAKDOWN",
            "p_reason": "Synthetic demo scenario: mechanical vibration requires inspection; no real machine is represented.",
        },
        token,
    )
    if code >= 400:
        error_code = result.get("code", "unknown") if isinstance(result, dict) else "unknown"
        message = result.get("message", "") if isinstance(result, dict) else ""
        safe = message.split("CODE:")[-1].strip() if "CODE:" in message else "permission_or_rpc_error"
        raise RuntimeError(f"Machine status RPC rejected (HTTP {code}, {error_code}, {safe})")
    status = result.get("status") if isinstance(result, dict) else None
    if status != "BREAKDOWN":
        raise RuntimeError("Machine status RPC returned an unexpected state")
    print("WV-04 set to BREAKDOWN through the supervisor RPC; linked downtime, task, exception and audit events are active.")

if __name__ == "__main__":
    main()
