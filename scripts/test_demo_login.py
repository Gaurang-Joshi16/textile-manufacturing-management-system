#!/usr/bin/env python3
"""Validate the deployed auth-login proxy without displaying credentials or tokens."""
from __future__ import annotations
import json, os, urllib.error, urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
for raw in (ROOT/'supabase'/'.env.local').read_text().splitlines():
 line=raw.strip()
 if line and not line.startswith('#') and '=' in line:
  k,v=line.split('=',1);os.environ[k]=v.strip().strip('"').strip("'")
cred=json.loads((ROOT/'supabase'/'.demo-credentials.json').read_text())['accounts'][0]
payload=json.dumps({'email':cred['email'],'password':cred['password']}).encode()
origin='https://4173-if4h7mw2f6wmcuzp77bwg-05d5ee2a.sg2.manus.computer'
req=urllib.request.Request(os.environ['SUPABASE_URL'].rstrip('/')+'/functions/v1/auth-login',data=payload,method='POST',headers={'Origin':origin,'apikey':os.environ['SUPABASE_ANON_KEY'],'Content-Type':'application/json'})
try:
 with urllib.request.urlopen(req,timeout=25) as r:
  data=json.loads(r.read());print('Demo login proxy:', 'PASS' if r.status==200 and data.get('session',{}).get('access_token') else f'FAIL (HTTP {r.status})')
except urllib.error.HTTPError as e:
 print('Demo login proxy:',f'FAIL (HTTP {e.code})')
