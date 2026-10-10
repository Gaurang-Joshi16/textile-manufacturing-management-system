#!/usr/bin/env python3
"""Live Phase 1 Auth/RPC security tests. Never prints credentials or tokens."""
from __future__ import annotations
import json, os, urllib.error, urllib.request, uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
for raw in (ROOT/'supabase'/'.env.local').read_text().splitlines():
 line=raw.strip()
 if line and not line.startswith('#') and '=' in line:
  k,v=line.split('=',1);os.environ[k]=v.strip().strip('"').strip("'")
cred=json.loads((ROOT/'supabase'/'.demo-credentials.json').read_text())['accounts'][0]
base=os.environ['SUPABASE_URL'].rstrip('/'); anon=os.environ['SUPABASE_ANON_KEY']
origin='https://4173-if4h7mw2f6wmcuzp77bwg-05d5ee2a.sg2.manus.computer'
def call(path, payload=None, token=None, origin_header=None):
 headers={'apikey':anon,'Content-Type':'application/json'}
 if token: headers['Authorization']=f'Bearer {token}'
 else: headers['Authorization']=f'Bearer {anon}'
 if origin_header: headers['Origin']=origin_header
 req=urllib.request.Request(base+path,data=None if payload is None else json.dumps(payload).encode(),method='GET' if payload is None else 'POST',headers=headers)
 try:
  with urllib.request.urlopen(req,timeout=25) as r:return r.status,json.loads(r.read() or b'{}')
 except urllib.error.HTTPError as e:
  try: body=json.loads(e.read() or b'{}')
  except Exception: body={}
  return e.code,body

status,data=call('/functions/v1/auth-login',{'email':cred['email'],'password':cred['password']},origin_header=origin)
token=data.get('session',{}).get('access_token')
print('E2E demo admin login:', 'PASS' if status==200 and token else f'FAIL (HTTP {status})')
if not token: raise SystemExit(1)
status,boot=call('/rest/v1/rpc/rpc_session_bootstrap',{},token=token)
print('Session bootstrap role/status:', 'PASS' if status==200 and boot.get('profile',{}).get('status')=='ACTIVE' and 'system_admin' in boot.get('roles',[]) else f'FAIL (HTTP {status})')
status,denied=call('/rest/v1/rpc/rpc_admin_set_user_status',{'p_user_id':boot.get('profile',{}).get('id'),'p_status':'DISABLED','p_reason':'Test last administrator guard','p_idempotency_key':str(uuid.uuid4())},token=token)
print('E46 LAST_ADMIN_PROTECTED:', 'PASS' if status>=400 and 'LAST_ADMIN_PROTECTED' in str(denied) else f'FAIL (HTTP {status})')
status,_=call('/rest/v1/rpc/rpc_admin_set_user_status',{'p_user_id':boot.get('profile',{}).get('id'),'p_status':'DISABLED','p_reason':'Unauthorized test','p_idempotency_key':str(uuid.uuid4())})
print('Anonymous admin RPC denial:', 'PASS' if status>=400 else f'FAIL (HTTP {status})')

email=f"lockout-{uuid.uuid4().hex}@everest-demo.test"
results=[]
for _ in range(6):
 st,_=call('/functions/v1/auth-login',{'email':email,'password':'incorrect-password'},origin_header=origin)
 results.append(st)
print('E48 five-failure lockout:', 'PASS' if results[:5]==[401]*5 and results[5]==429 else f'FAIL ({results})')
if results[:5]!=[401]*5 or results[5]!=429: raise SystemExit(1)
