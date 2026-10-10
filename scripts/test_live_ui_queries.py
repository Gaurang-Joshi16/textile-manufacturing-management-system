#!/usr/bin/env python3
"""Read-only role-scoped PostgREST smoke checks for the routes wired in LivePages.tsx.
Requires the ignored local Supabase env and synthetic demo credentials files.
Never prints identity fields, credentials, JWTs, or returned business records.
"""
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
for raw in (ROOT / 'supabase' / '.env.local').read_text().splitlines():
    line = raw.strip()
    if line and not line.startswith('#') and '=' in line:
        key, value = line.split('=', 1)
        os.environ[key] = value.strip().strip('"').strip("'")
BASE = os.environ['SUPABASE_URL'].rstrip('/')
ANON = os.environ['SUPABASE_ANON_KEY']
accounts = json.loads((ROOT / 'supabase' / '.demo-credentials.json').read_text())['accounts']

def account(role, email_prefix=None):
    values = [a for a in accounts if a.get('role') == role]
    if email_prefix:
        values = [a for a in values if a.get('email', '').lower().startswith(email_prefix)]
    if not values:
        raise RuntimeError(f'Missing synthetic account for {role}')
    return values[0]

def call(method, path, payload=None, token=None):
    headers = {'apikey': ANON, 'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(BASE + path, data=None if payload is None else json.dumps(payload).encode(), headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        return error.code, None

def role_for(path):
    if path == '/portal': return 'buyer'
    if path.startswith('/admin/'): return 'system_admin'
    if path.startswith('/finance/'): return 'finance_officer'
    if path.startswith('/hr/'): return 'hr_payroll_officer'
    if path.startswith('/quality/'): return 'quality_inspector'
    if path.startswith('/dispatch/'): return 'dispatch_officer'
    if path.startswith('/stores'): return 'storekeeper'
    if path in ['/operations','/shift-board','/machines','/maintenance','/handover']: return 'production_supervisor'
    if path == '/my-jobs': return 'machine_operator'
    return 'factory_manager'

def login(role):
    prefix = 'buyer.lotus' if role == 'buyer' else None
    user = account(role, prefix)
    status, payload = call('POST', '/auth/v1/token?grant_type=password', {'email': user['email'], 'password': user['password']})
    if status != 200 or not isinstance(payload, dict) or not payload.get('access_token'):
        raise RuntimeError(f'Login failed for synthetic role {role} (HTTP {status})')
    return payload['access_token']

text = (ROOT / 'web' / 'src' / 'LivePages.tsx').read_text()
configs = re.findall(r"'(/[^']+)': \{ title: '[^']*', description: '[^']*', table: '([^']+)', select: '([^']*)'", text)
tokens = {}
failures = []
for path, table, select in configs:
    role = role_for(path)
    if role not in tokens:
        try:
            tokens[role] = login(role)
        except Exception:
            failures.append((path, 'login'))
            continue
    if table == 'rpc_buyer_list_orders':
        code, _ = call('POST', '/rest/v1/rpc/rpc_buyer_list_orders', {}, tokens[role])
    else:
        query = urllib.parse.urlencode({'select': select, 'limit': '1'}, safe=',')
        code, _ = call('GET', f'/rest/v1/{table}?{query}', token=tokens[role])
    if code >= 400:
        failures.append((path, str(code)))
        print(f'FAIL {path}: HTTP {code}')
    else:
        print(f'PASS {path}')

# Compound reads used by the receipt wizard and shipment allocation flow.
for role, table, select in [
    ('storekeeper', 'suppliers', 'id,supplier_code,name'),
    ('storekeeper', 'yarn_items', 'id,item_code,name,unit,standard_unit_cost,preferred_supplier_id'),
    ('factory_manager', 'buyers', 'id,buyer_code,name,currency'),
    ('factory_manager', 'products', 'id,product_code,description,colour,unit,standard_roll_length'),
    ('dispatch_officer', 'buyer_orders', 'id,order_number,status,promised_date'),
    ('dispatch_officer', 'shipments', 'id,shipment_number,status,manifest_expected_count,manifest_scanned_count'),
]:
    if role not in tokens:
        try: tokens[role] = login(role)
        except Exception:
            failures.append((table, 'login')); continue
    query = urllib.parse.urlencode({'select': select, 'limit': '1'}, safe=',')
    code, _ = call('GET', f'/rest/v1/{table}?{query}', token=tokens[role])
    if code >= 400:
        failures.append((table, str(code))); print(f'FAIL wizard query {table}: HTTP {code}')
    else:
        print(f'PASS wizard query {table}')

# The scan screen reads only the manifest roll identifier and its safe human-readable code.
if 'dispatch_officer' in tokens:
    code, _ = call('GET', '/rest/v1/shipment_rolls?select=roll_id,fabric_rolls(roll_code)&limit=1', token=tokens['dispatch_officer'])
    if code >= 400:
        failures.append(('shipment_rolls relation', str(code))); print(f'FAIL dispatch relation query: HTTP {code}')
    else:
        print('PASS dispatch manifest relation query')

# The buyer timeline RPC must stay scoped to the logged-in Lotus account and expose no price fields.
buyer_token = tokens.get('buyer')
if buyer_token:
    code, orders = call('POST', '/rest/v1/rpc/rpc_buyer_list_orders', {}, buyer_token)
    if code < 400 and isinstance(orders, list) and orders:
        first = orders[0]
        order_id = first.get('order_id') or first.get('id')
        tcode, timeline = call('POST', '/rest/v1/rpc/rpc_buyer_order_timeline', {'p_order_id': order_id}, buyer_token) if order_id else (400, None)
        encoded = json.dumps(timeline or {}).lower()
        if tcode >= 400 or any(key in encoded for key in ['unit_rate','subtotal','tax_amount','total']):
            failures.append(('/portal/timeline', str(tcode))); print('FAIL /portal/timeline')
        else:
            print('PASS /portal/timeline')
    else:
        print('PASS /portal/timeline (no buyer orders in this buyer scope)')

if failures:
    raise SystemExit(f'Live UI query smoke: {len(configs) + 7 - len(failures)} pass, {len(failures)} fail')
print(f'Live UI query smoke: PASS ({len(configs)} configured routes + 7 wizard/relationship queries)')
