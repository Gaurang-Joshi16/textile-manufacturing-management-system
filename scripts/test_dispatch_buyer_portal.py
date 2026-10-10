#!/usr/bin/env python3
"""Authenticated shipment/manifest and buyer-safe portal acceptance test."""
import json,os,urllib.error,urllib.request,uuid
from pathlib import Path
import psycopg
ROOT=Path(__file__).resolve().parents[1]
for raw in (ROOT/'supabase'/'.env.local').read_text().splitlines():
 line=raw.strip()
 if line and not line.startswith('#') and '=' in line:k,v=line.split('=',1);os.environ[k]=v.strip().strip('"').strip("'")
BASE=os.environ['SUPABASE_URL'].rstrip('/');ANON=os.environ['SUPABASE_ANON_KEY'];STORY=ROOT/'supabase'/'.demo-story.json';state=json.loads(STORY.read_text())
accounts=json.loads((ROOT/'supabase'/'.demo-credentials.json').read_text())['accounts']
def account(role):return next(a for a in accounts if a['role']==role)
def call(method,path,payload=None,token=None):
 h={'apikey':ANON,'Content-Type':'application/json'}
 if token:h['Authorization']='Bearer '+token
 req=urllib.request.Request(BASE+path,data=None if payload is None else json.dumps(payload).encode(),headers=h,method=method)
 try:
  with urllib.request.urlopen(req,timeout=45) as r:
   b=r.read();return r.status,json.loads(b) if b else {}
 except urllib.error.HTTPError as e:
  try:d=json.loads(e.read())
  except:d={}
  raise RuntimeError(f'{path}: HTTP {e.code} {str(d.get("message") or d.get("msg") or d.get("error") or "request failed")[:260]}') from None
def login(role):
 a=account(role);return call('POST','/auth/v1/token?grant_type=password',{'email':a['email'],'password':a['password']})[1]['access_token']
def rpc(name,args,token):return call('POST','/rest/v1/rpc/'+name,args,token)[1]
def key(name):return str(uuid.uuid5(uuid.NAMESPACE_URL,'everest-demo-story:'+name))
dispatcher=login('dispatch_officer')
order_id=state['order_id']
created=rpc('rpc_create_shipment',{'p_order_id':order_id,'p_requested_qty':500,'p_idempotency_key':key('shipment-create'),'p_carrier':'DEMO CARRIER','p_vehicle_no':'DEMO-TRUCK-01'},dispatcher)
shipment_id=created['shipment_id']
with psycopg.connect(os.environ['SUPABASE_DB_URL']) as c:
 status=c.execute('select status::text from public.shipments where id=%s',(shipment_id,)).fetchone()[0]
 status=c.execute('select status::text from public.shipments where id=%s',(shipment_id,)).fetchone()[0]
if status=='DRAFT':
 with psycopg.connect(os.environ['SUPABASE_DB_URL']) as c:
  roll_rows=c.execute("select id,roll_code,qty from public.fabric_rolls where output_id=%s and status='ACCEPTED' order by roll_code limit 10",(state['output_id'],)).fetchall()
 if len(roll_rows)!=10 or round(sum(float(x[2]) for x in roll_rows),1)!=500:raise RuntimeError('Expected 10 accepted 50 m rolls')
 rpc('rpc_allocate_rolls',{'p_shipment_id':shipment_id,'p_roll_ids':[str(x[0]) for x in roll_rows],'p_idempotency_key':key('shipment-allocate')},dispatcher)
 status='ALLOCATED'
else:
 with psycopg.connect(os.environ['SUPABASE_DB_URL']) as c:
  roll_rows=c.execute('select r.id,r.roll_code,r.qty from public.shipment_rolls sr join public.fabric_rolls r on r.id=sr.roll_id where sr.shipment_id=%s order by r.roll_code',(shipment_id,)).fetchall()
if len(roll_rows)!=10:raise RuntimeError(f'Expected 10 allocated rolls, found {len(roll_rows)}')
if status=='ALLOCATED':
 for _,roll_code,_qty in roll_rows:rpc('rpc_scan_manifest',{'p_shipment_id':shipment_id,'p_roll_code':roll_code},dispatcher)
 confirmed=rpc('rpc_confirm_shipment',{'p_shipment_id':shipment_id,'p_ack_mismatch':False,'p_mismatch_reason':None,'p_idempotency_key':key('shipment-confirm')},dispatcher)
elif status=='CONFIRMED':confirmed=rpc('rpc_confirm_shipment',{'p_shipment_id':shipment_id,'p_ack_mismatch':False,'p_mismatch_reason':None,'p_idempotency_key':key('shipment-confirm')},dispatcher)
else:raise RuntimeError(f'Unexpected shipment state {status}')
# Verify using a real buyer session and a buyer-scoped RPC, never direct priced rows.
buyer_token=login('buyer')
timeline=rpc('rpc_buyer_order_timeline',{'p_order_id':order_id},buyer_token)
if timeline['status']!='PARTIALLY_DISPATCHED' or len(timeline.get('shipments',[]))!=1 or timeline['shipments'][0]['status']!='CONFIRMED':raise RuntimeError('Buyer-safe shipment milestone is missing')
if any(k in json.dumps(timeline).lower() for k in ['unit_rate','subtotal','tax_amount','total']):raise RuntimeError('Buyer timeline leaked invoice pricing')
with psycopg.connect(os.environ['SUPABASE_DB_URL']) as c:
 shipped=c.execute("select count(*),coalesce(sum(allocated_qty),0) from public.shipment_rolls where shipment_id=%s and status='DISPATCHED'",(shipment_id,)).fetchone()
 invoice=c.execute("select status::text,currency,subtotal from public.invoices where shipment_id=%s",(shipment_id,)).fetchone()
 states=c.execute("select status::text,count(*) from public.fabric_rolls where output_id=%s group by status",(state['output_id'],)).fetchall()
if (int(shipped[0]),float(shipped[1]))!=(10,500.0) or not invoice or invoice[0]!='DRAFT':raise RuntimeError(f'dispatch/invoice verification failed: {shipped}, {invoice}')
state.update({'shipment_id':shipment_id,'shipment_number':created['shipment_number'],'shipment_status':'CONFIRMED','shipment_roll_ids':[str(x[0]) for x in roll_rows],'dispatch_qty':500,'invoice_status':invoice[0],'buyer_timeline_status':timeline['status'],'final_roll_statuses':{k:int(v) for k,v in states}})
STORY.write_text(json.dumps(state,indent=2)+'\n');os.chmod(STORY,0o600)
print('Dispatch/buyer-portal integration: PASS')
print(f"Shipment {created['shipment_number']}: {int(shipped[0])} rolls / {float(shipped[1]):.0f} m; manifest scanned 10/10.")
print(f"Order milestone: {timeline['status']} | invoice: {invoice[0]} (draft only) | buyer payload excludes all pricing fields.")
