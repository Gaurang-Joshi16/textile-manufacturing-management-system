#!/usr/bin/env python3
"""Authenticated receipt + material reservation acceptance test; no supplier email is sent."""
import json,os,urllib.error,urllib.request,uuid
from pathlib import Path
import psycopg
ROOT=Path(__file__).resolve().parents[1]
for raw in (ROOT/'supabase'/'.env.local').read_text().splitlines():
 line=raw.strip()
 if line and not line.startswith('#') and '=' in line:
  k,v=line.split('=',1);os.environ[k]=v.strip().strip('"').strip("'")
BASE=os.environ['SUPABASE_URL'].rstrip('/');ANON=os.environ['SUPABASE_ANON_KEY']
creds=json.loads((ROOT/'supabase'/'.demo-credentials.json').read_text())['accounts']
state=json.loads((ROOT/'supabase'/'.demo-story.json').read_text())
def get_account(role):return next(a for a in creds if a['role']==role)
def call(method,path,payload=None,token=None):
 h={'apikey':ANON,'Content-Type':'application/json'}
 if token:h['Authorization']='Bearer '+token
 req=urllib.request.Request(BASE+path,data=None if payload is None else json.dumps(payload).encode(),headers=h,method=method)
 try:
  with urllib.request.urlopen(req,timeout=45) as r:
   raw=r.read();return r.status,json.loads(raw) if raw else {}
 except urllib.error.HTTPError as e:
  try:d=json.loads(e.read())
  except:d={}
  raise RuntimeError(f'{path}: HTTP {e.code} {str(d.get("message") or d.get("msg") or d.get("error") or "request failed")[:260]}') from None
def token_for(role):return call('POST','/auth/v1/token?grant_type=password',{'email':get_account(role)['email'],'password':get_account(role)['password']})[1]['access_token']
def key(name):return str(uuid.uuid5(uuid.NAMESPACE_URL,'everest-demo-story:'+name))
def rpc(name,args,token):return call('POST','/rest/v1/rpc/'+name,args,token)[1]
store=token_for('storekeeper');mgr=token_for('factory_manager')
with psycopg.connect(os.environ['SUPABASE_DB_URL']) as c:
 item=c.execute("select id from public.yarn_items where item_code='YRN-COT-30S'").fetchone()[0]
 supplier=c.execute("select preferred_supplier_id from public.yarn_items where id=%s",(item,)).fetchone()[0]
receipt=rpc('rpc_post_receipt',{'p_supplier_id':str(supplier),'p_po_id':None,'p_delivery_reference':'DEMO-DELIVERY-430-30','p_lines':[{'yarn_item_id':str(item),'received_qty':500,'accepted_qty':430,'damaged_qty':40,'quarantined_qty':30,'unit':'kg','unit_cost':120,'supplier_lot':'DEMO-COT-430-30'}],'p_idempotency_key':key('cotton-receipt')},store)
release=rpc('rpc_release_plan',{'p_plan_id':state['plan_id'],'p_idempotency_key':key('release-plan')},mgr)
with psycopg.connect(os.environ['SUPABASE_DB_URL']) as c:
 stock=c.execute("select coalesce(sum(available),0),coalesce(sum(quarantined),0),coalesce(sum(reserved),0) from public.v_yarn_stock where yarn_item_id=%s",(item,)).fetchone()
 reserve=c.execute("select coalesce(sum(qty),0) from public.material_reservations where plan_id=%s and status='ACTIVE'",(state['plan_id'],)).fetchone()[0]
if tuple(round(float(x),1) for x in stock)!=(164.4,30.0,665.6) or round(float(reserve),1)!=665.6:
 raise RuntimeError(f'unexpected post-release balances: {stock}; reservation={reserve}')
state.update({'receipt_id':receipt['receipt_id'],'receipt_number':receipt['receipt_number'],'plan_status':'RELEASED','reservation_qty':float(reserve)})
(ROOT/'supabase'/'.demo-story.json').write_text(json.dumps(state,indent=2)+'\n');os.chmod(ROOT/'supabase'/'.demo-story.json',0o600)
print('Receipt/reservation integration: PASS')
print(f"Receipt {receipt['receipt_number']}: 500 kg total = 430 kg accepted + 40 kg damaged + 30 kg quarantined")
print(f"Stock after 665.6 kg reservation: {float(stock[0]):.1f} kg available, {float(stock[1]):.1f} kg quarantined, {float(stock[2]):.1f} kg reserved")
print(f"Plan release: {release['status']}")
