#!/usr/bin/env python3
"""Authenticated QC/rework/quarantine acceptance test."""
import json,os,urllib.error,urllib.request,uuid
from pathlib import Path
import psycopg
ROOT=Path(__file__).resolve().parents[1]
for raw in (ROOT/'supabase'/'.env.local').read_text().splitlines():
 line=raw.strip()
 if line and not line.startswith('#') and '=' in line:k,v=line.split('=',1);os.environ[k]=v.strip().strip('"').strip("'")
BASE=os.environ['SUPABASE_URL'].rstrip('/');ANON=os.environ['SUPABASE_ANON_KEY'];STORY=ROOT/'supabase'/'.demo-story.json';state=json.loads(STORY.read_text())
accounts=json.loads((ROOT/'supabase'/'.demo-credentials.json').read_text())['accounts'];a=next(x for x in accounts if x['role']=='quality_inspector')
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
_,auth=call('POST','/auth/v1/token?grant_type=password',{'email':a['email'],'password':a['password']});token=auth['access_token']
def rpc(name,args):return call('POST','/rest/v1/rpc/'+name,args,token)[1]
def key(name):return str(uuid.uuid5(uuid.NAMESPACE_URL,'everest-demo-story:'+name))
rolls=state['rolls']
with psycopg.connect(os.environ['SUPABASE_DB_URL']) as c:
 checks=c.execute("select ipc.id,ipc.check_name,ipc.expected_min,ipc.expected_max,ipc.unit from public.inspection_plan_checks ipc join public.inspection_plans ip on ip.id=ipc.plan_id join public.fabric_rolls r on r.id=%s join public.buyer_order_lines l on l.id=r.order_line_id where ip.product_id=l.product_id and ip.is_active order by ipc.id",(rolls[0]['roll_id'],)).fetchall()
 if not checks:raise RuntimeError('Inspection plan checks are missing')
 measurements=[]
 for cid,name,lo,hi,unit in checks:
  value=0 if lo is None or hi is None else (float(lo)+float(hi))/2
  measurements.append({'check_id':str(cid),'measured_value':value,'expected_min':None if lo is None else float(lo),'expected_max':None if hi is None else float(hi),'unit':unit,'pass':True})
 # Inspect each initial roll exactly once. Roll 2 is rework; roll 3 is quarantined.
 for i,r in enumerate(rolls,1):
  with psycopg.connect(os.environ['SUPABASE_DB_URL']) as c:status=c.execute('select status::text from public.fabric_rolls where id=%s',(r['roll_id'],)).fetchone()[0]
  if status!='AWAITING_INSPECTION':continue
  if i==2:result='REWORK';defects=[{'category_code':'HOLE','severity':'MAJOR','quantity_or_extent':1,'unit':'defect','pos_x':100,'pos_y':25,'notes':'Major hole; controlled rework required.'}];notes='Roll 2 hole, MAJOR; route to rework.'
  elif i==3:result='QUARANTINE';defects=[{'category_code':'HOLE','severity':'MAJOR','quantity_or_extent':1,'unit':'defect','pos_x':150,'pos_y':20,'notes':'Major hole; hold in QC quarantine.'}];notes='Roll 3 hole, MAJOR; quarantine pending disposition.'
  else:result='PASS';defects=[];notes='Synthetic demo inspection passed.'
  rpc('rpc_inspect_roll',{'p_roll_id':r['roll_id'],'p_result':result,'p_notes':notes,'p_measurements':measurements,'p_defects':defects,'p_idempotency_key':key(f'qc:{r["roll_id"]}:1')})
# Complete the linked rework then require and record a second, passing inspection.
with psycopg.connect(os.environ['SUPABASE_DB_URL']) as c:
 rework=c.execute("select rw.id,rw.status from public.rework_orders rw where rw.roll_id=%s order by rw.created_at desc limit 1",(rolls[1]['roll_id'],)).fetchone()
 roll2_status=c.execute('select status::text from public.fabric_rolls where id=%s',(rolls[1]['roll_id'],)).fetchone()[0]
if rework and rework[1] in ('OPEN','IN_PROGRESS'):
 rpc('rpc_complete_rework',{'p_rework_id':str(rework[0]),'p_notes':'Demo repair completed; submit for QC reinspection.'})
with psycopg.connect(os.environ['SUPABASE_DB_URL']) as c:
 roll2_status=c.execute('select status::text from public.fabric_rolls where id=%s',(rolls[1]['roll_id'],)).fetchone()[0]
if roll2_status=='REINSPECTION_REQUIRED':
 rpc('rpc_inspect_roll',{'p_roll_id':rolls[1]['roll_id'],'p_result':'PASS','p_notes':'Reinspection passed after rework.','p_measurements':measurements,'p_defects':[],'p_idempotency_key':key(f'qc:{rolls[1]["roll_id"]}:2')})
with psycopg.connect(os.environ['SUPABASE_DB_URL']) as c:
 counts=c.execute("select status::text,count(*) from public.fabric_rolls where output_id=%s group by status",(state['output_id'],)).fetchall()
 statuses={k:int(v) for k,v in counts}
 if statuses.get('ACCEPTED')!=11 or statuses.get('QUARANTINED')!=1:raise RuntimeError(f'unexpected roll QC totals: {statuses}')
 if c.execute("select count(*) from public.quality_inspections where roll_id=any(%s::uuid[])",[ [r['roll_id'] for r in rolls] ]).fetchone()[0]!=13:raise RuntimeError('expected 12 first-pass inspections plus one reinspection')
state.update({'quality_statuses':statuses,'rework_id':str(rework[0]) if rework else None,'qc_complete':True})
STORY.write_text(json.dumps(state,indent=2)+'\n');os.chmod(STORY,0o600)
print('Quality/rework integration: PASS')
print('12 rolls inspected; roll 2: MAJOR hole → rework → linked reinspection PASS; roll 3: MAJOR hole → QC quarantine.')
print(f"Eligible after inspection: {statuses.get('ACCEPTED',0)} rolls ({statuses.get('ACCEPTED',0)*50} m); quarantined: {statuses.get('QUARANTINED',0)} roll.")
