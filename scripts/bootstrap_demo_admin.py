#!/usr/bin/env python3
"""Create the spec's synthetic demo administrator through the bootstrap path."""
from __future__ import annotations
import json, os, secrets, stat, urllib.error, urllib.request
from pathlib import Path
import psycopg
ROOT=Path(__file__).resolve().parents[1]
for raw in (ROOT/'supabase'/'.env.local').read_text().splitlines():
 line=raw.strip()
 if line and not line.startswith('#') and '=' in line:
  k,v=line.split('=',1);os.environ[k]=v.strip().strip('"').strip("'")
url=os.environ['SUPABASE_URL'].rstrip('/')
service=os.environ['SUPABASE_SERVICE_ROLE_KEY']
email='admin@everest-demo.test'
name='Everest Demo Administrator'
cred_path=ROOT/'supabase'/'.demo-credentials.json'
headers={'apikey':service,'Authorization':f'Bearer {service}','Content-Type':'application/json'}
def api(method,path,payload=None):
 data=None if payload is None else json.dumps(payload).encode()
 req=urllib.request.Request(url+path,data=data,headers=headers,method=method)
 try:
  with urllib.request.urlopen(req,timeout=25) as r:return r.status,json.loads(r.read() or b'{}')
 except urllib.error.HTTPError as e:return e.code,json.loads(e.read() or b'{}')

status,listing=api('GET','/auth/v1/admin/users?page=1&per_page=1000')
if status!=200: raise SystemExit(f'Auth user lookup failed: HTTP {status}')
users=listing.get('users',[])
user=next((u for u in users if (u.get('email') or '').lower()==email),None)
if user and not cred_path.exists():
 raise SystemExit('Demo admin already exists but its credential file is missing; password will not be reset automatically.')
if not user:
 password=secrets.token_urlsafe(32)+'Aa1!'
 status,created=api('POST','/auth/v1/admin/users',{'email':email,'password':password,'email_confirm':True,'user_metadata':{'full_name':name,'account_type':'staff','requested_role':'system_admin','is_demo':True}})
 if status not in (200,201) or not created.get('id'):
  raise SystemExit(f'Demo user creation failed: HTTP {status}')
 user=created
 if not cred_path.exists():
  cred_path.write_text(json.dumps({'accounts':[{'role':'system_admin','email':email,'password':password,'is_demo':True}]},indent=2)+'\n')
  cred_path.chmod(stat.S_IRUSR|stat.S_IWUSR)
user_id=user['id']
with psycopg.connect(os.environ['SUPABASE_DB_URL'],connect_timeout=20) as conn:
 with conn.transaction():
  conn.execute("UPDATE public.profiles SET status='ACTIVE',full_name=%s,approved_by=%s,approved_at=now() WHERE id=%s",(name,user_id,user_id))
  conn.execute("INSERT INTO public.user_roles(user_id,role_id,assigned_by) SELECT %s,id,%s FROM public.roles WHERE key='system_admin' ON CONFLICT DO NOTHING",(user_id,user_id))
  conn.execute("INSERT INTO public.audit_logs(actor_user_id,actor_role,action,entity_type,entity_id,reason,after_json) VALUES(%s,'system_admin','DEMO_ADMIN_BOOTSTRAPPED','profiles',%s,'Synthetic demo bootstrap account per specification',jsonb_build_object('is_demo',true))",(user_id,user_id))
print('Synthetic demo administrator: READY (password saved in mode-0600 ignored local file)')
