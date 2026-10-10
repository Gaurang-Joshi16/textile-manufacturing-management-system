#!/usr/bin/env python3
"""Live, redacted integration test for the order -> feasibility -> RFQ -> plan path."""
from __future__ import annotations
import json, os, urllib.error, urllib.parse, urllib.request, uuid
from datetime import date, timedelta
from pathlib import Path
import psycopg
ROOT=Path(__file__).resolve().parents[1]
for raw in (ROOT/'supabase'/'.env.local').read_text().splitlines():
    line=raw.strip()
    if line and not line.startswith('#') and '=' in line:
        k,v=line.split('=',1);os.environ[k]=v.strip().strip('"').strip("'")
BASE=os.environ['SUPABASE_URL'].rstrip('/')
ANON=os.environ['SUPABASE_ANON_KEY']
CRED=json.loads((ROOT/'supabase'/'.demo-credentials.json').read_text())
STORY=ROOT/'supabase'/'.demo-story.json'
state=json.loads(STORY.read_text()) if STORY.exists() else {}
account=next(a for a in CRED['accounts'] if a['role']=='factory_manager')
def request(method,path,payload=None,token=None):
    headers={'apikey':ANON,'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    data=None if payload is None else json.dumps(payload).encode()
    req=urllib.request.Request(BASE+path,data=data,headers=headers,method=method)
    try:
        with urllib.request.urlopen(req,timeout=30) as r:
            raw=r.read()
            return r.status,json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        body=e.read()
        try: data=json.loads(body)
        except Exception: data={}
        msg=data.get('message') or data.get('msg') or data.get('error') or 'request failed'
        raise RuntimeError(f'{method} {path}: HTTP {e.code} {str(msg)[:240]}') from None

def key(name): return str(uuid.uuid5(uuid.NAMESPACE_URL,'everest-demo-story:'+name))
def rpc(name,args,token): return request('POST','/rest/v1/rpc/'+name,args,token)[1]

status,auth=request('POST','/auth/v1/token?grant_type=password',{'email':account['email'],'password':account['password']})
token=auth['access_token']
if 'order_id' not in state:
    with psycopg.connect(os.environ['SUPABASE_DB_URL']) as conn:
        buyer_id=conn.execute("SELECT id FROM public.buyers WHERE buyer_code='BUY-LOTUS'").fetchone()[0]
        product_id=conn.execute("SELECT id FROM public.products WHERE product_code='FAB-TWILL-INDIGO'").fetchone()[0]
    result=rpc('rpc_create_order',{'p_payload':{'buyer_id':str(buyer_id),'requested_date':(date.today()+timedelta(days=21)).isoformat(),'promised_date':(date.today()+timedelta(days=21)).isoformat(),'priority':'HIGH','currency':'INR','notes_buyer':'Demo flagship order; shipment requested in 21 days.','notes_internal':'Synthetic acceptance walkthrough; demo only.','lines':[{'product_id':str(product_id),'colour':'Indigo','ordered_qty':2000,'unit':'m','unit_rate':185}]},'p_idempotency_key':key('create-order')},token)
    state.update({'order_id':result['order_id'],'order_number':result['order_number'],'line_id':result['lines'][0]['id']})
    STORY.write_text(json.dumps(state,indent=2)+'\n');os.chmod(STORY,0o600)
else:
    # Retrieve the deterministic line without exposing prices.
    with psycopg.connect(os.environ['SUPABASE_DB_URL']) as conn:
        state['line_id']=str(conn.execute('SELECT id FROM public.buyer_order_lines WHERE order_id=%s',(state['order_id'],)).fetchone()[0])
feas=rpc('rpc_run_feasibility',{'p_order_id':state['order_id']},token)
mat=next((x for x in feas['details']['materials'] if x.get('item_code')=='YRN-COT-30S'),None)
if not mat: raise RuntimeError('cotton material missing from feasibility details')
if round(float(mat['required_qty']),1)!=665.6 or round(float(mat['available_qty']),1)!=400.0 or round(float(mat['shortage_qty']),1)!=265.6:
    raise RuntimeError('unexpected flagship BOM/stock feasibility result')
rfq=rpc('rpc_generate_rfq_drafts',{'p_order_id':state['order_id'],'p_idempotency_key':key('rfq')},token)
rpc('rpc_confirm_order',{'p_order_id':state['order_id'],'p_idempotency_key':key('confirm-order'),'p_override_reason':None},token)
if 'plan_id' not in state:
    plan=rpc('rpc_create_plan',{'p_order_line_id':state['line_id'],'p_planned_qty':2000,'p_idempotency_key':key('create-plan')},token)
    state.update({'plan_id':plan['plan_id'],'plan_no':plan['plan_no']})
    STORY.write_text(json.dumps(state,indent=2)+'\n');os.chmod(STORY,0o600)
print('Order/planning integration: PASS')
print(f"Order: {state['order_number']} | feasibility: {feas['result']} | cotton required/available/shortage: {mat['required_qty']}/{mat['available_qty']}/{mat['shortage_qty']} kg")
print(f"RFQ drafts: {len(rfq.get('drafts',[]))} (not sent) | plan: {state.get('plan_no','created')}")
