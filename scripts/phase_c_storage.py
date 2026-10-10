#!/usr/bin/env python3
"""Idempotently provision the six private Storage buckets in the project spec."""
from __future__ import annotations
import json, os, urllib.error, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
for raw in (ROOT / "supabase" / ".env.local").read_text().splitlines():
    line = raw.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1); os.environ[k] = v.strip().strip('"').strip("'")
base = os.environ["SUPABASE_URL"].rstrip("/") + "/storage/v1"
key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
headers = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
def request(method: str, path: str, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as r: return r.status, r.read()
    except urllib.error.HTTPError as e: return e.code, e.read()
status, body = request("GET", "/bucket")
if status != 200:
    print(f"Bucket list failed (HTTP {status}); no bucket changes attempted."); raise SystemExit(1)
existing = {b["id"]: b for b in json.loads(body)}
required = {
    "qc-evidence": {"id": "qc-evidence", "name": "qc-evidence", "public": False, "file_size_limit": 10485760, "allowed_mime_types": ["image/jpeg", "image/png", "image/webp", "application/pdf"]},
    "machine-images": {"id": "machine-images", "name": "machine-images", "public": False},
    "supplier-docs": {"id": "supplier-docs", "name": "supplier-docs", "public": False},
    "expense-receipts": {"id": "expense-receipts", "name": "expense-receipts", "public": False},
    "generated-documents": {"id": "generated-documents", "name": "generated-documents", "public": False},
    "company-assets": {"id": "company-assets", "name": "company-assets", "public": False},
}
failed = False
for name, config in required.items():
    if name in existing:
        print(f"{name}: already present; public={bool(existing[name].get('public'))}")
        if existing[name].get("public"):
            print(f"ERROR: {name} is public, contrary to spec."); failed = True
        continue
    code, _ = request("POST", "/bucket", config)
    print(f"{name}: {'CREATED' if code in (200, 201) else 'FAILED'} (HTTP {code})")
    failed |= code not in (200, 201)
status, body = request("GET", "/bucket")
if status != 200:
    print(f"Final bucket list failed (HTTP {status})"); raise SystemExit(1)
final = {b["id"]: b for b in json.loads(body)}
for name in required:
    print(f"verify {name}: {'PASS' if name in final and not final[name].get('public') else 'FAIL'}")
    failed |= name not in final or bool(final[name].get("public"))
print(f"Storage bucket create/list gate: {'FAIL' if failed else 'PASS'}")
raise SystemExit(1 if failed else 0)
