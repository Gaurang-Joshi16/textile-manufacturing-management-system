#!/usr/bin/env python3
"""Live production assignment/material issue/output and roll-passport integration."""
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
STORY=ROOT/'supabase'/'.demo-story.json';state=json.loads(STORY.read_text())
def account(role):return next(a for a in creds if a['role']==role)
def request(method,path,payload=None,token=None):
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
 a=account(role);return request('POST','/auth/v1/token?grant_type=password',{'email':a['email'],'password':a['password']})[1]['access_token']
def key(name):return str(uuid.uuid5(uuid.NAMESPACE_URL,'everest-demo-story:'+name))
def rpc(name,args,token):return request('POST','/rest/v1/rpc/'+name,args,token)[1]
manager=login('factory_manager');supervisor=login('production_supervisor');storekeeper=login('storekeeper')
with psycopg.connect(os.environ['SUPABASE_DB_URL']) as c:
 ops=c.execute("select id,sequence,status,process_id,stage,unit from public.production_operations where plan_id=%s order by sequence",(state['plan_id'],)).fetchall()
 op={r[1]:{'id':str(r[0]),'status':r[2],'process_id':str(r[3]),'stage':r[4],'unit':r[5]} for r in ops}
 supervisor_emp=c.execute("select id from public.employees where employee_code='EMP-DEMO-005'").fetchone()[0]
 # Find active, certified demo operators with an open rostered shift for today.
 def worker(skill):
  return c.execute("select e.id,e.employee_code,sr.shift_id,si.id from public.employees e join public.employee_skills es on es.employee_id=e.id join public.skills sk on sk.id=es.skill_id join public.shift_roster sr on sr.employee_id=e.id and sr.work_date=current_date join public.shift_instances si on si.shift_id=sr.shift_id and si.work_date=sr.work_date where sk.code=%s and e.employment_status='ACTIVE' and si.status='OPEN' order by e.employee_code limit 1",(skill,)).fetchone()
 spin_worker=worker('SPIN-OP');weave_worker=worker('WEAVE-OP')
 if not spin_worker or not weave_worker:raise RuntimeError('No certified rostered demo worker found')
 machines={r[0]:str(r[1]) for r in c.execute("select machine_code,id from public.machines where source='DEMO'")}
 reservations=c.execute("select id,qty,consumed_qty,status from public.material_reservations where plan_id=%s order by created_at",(state['plan_id'],)).fetchall()
 # Idempotently issue each reserved batch quantity.
 for rid,qty,consumed,status in reservations:
  if status!='CONSUMED':
   rpc('rpc_issue_material',{'p_reservation_id':str(rid),'p_qty':float(qty-consumed),'p_idempotency_key':key('issue:'+str(rid))},storekeeper)
 # Ensure the upstream spinning stage is controlled and completed before weaving.
 spin=op[1]
 if spin['status'] in ('PLANNED','READY'):
  rpc('rpc_assign_operation',{'p_operation_id':spin['id'],'p_machine_id':machines['SP-01'],'p_shift_id':str(spin_worker[2]),'p_supervisor_id':str(supervisor_emp),'p_employee_ids':[str(spin_worker[0])]},manager)
  spin={**spin,'status':'READY'}
 if spin['status']=='READY':rpc('rpc_set_operation_state',{'p_operation_id':spin['id'],'p_action':'START','p_reason':None},supervisor)
 with psycopg.connect(os.environ['SUPABASE_DB_URL']) as c:
  spin_status=c.execute('select status::text from public.production_operations where id=%s',(spin['id'],)).fetchone()[0]
 if spin_status=='IN_PROGRESS':rpc('rpc_set_operation_state',{'p_operation_id':spin['id'],'p_action':'COMPLETE','p_reason':None},supervisor)
 # Assign and start the weaving line only after upstream completion.
 weave=op[2]
 if weave['status']=='PLANNED':
  rpc('rpc_assign_operation',{'p_operation_id':weave['id'],'p_machine_id':machines['WV-02'],'p_shift_id':str(weave_worker[2]),'p_supervisor_id':str(supervisor_emp),'p_employee_ids':[str(weave_worker[0])]},manager)
  weave={**weave,'status':'READY'}
 if weave['status']=='READY':rpc('rpc_set_operation_state',{'p_operation_id':weave['id'],'p_action':'START','p_reason':None},supervisor)
 output=rpc('rpc_record_output',{'p_operation_id':weave['id'],'p_shift_instance_id':str(weave_worker[3]),'p_good_qty':600,'p_waste_qty':0,'p_reject_qty':0,'p_unit':'m','p_idempotency_key':key('weaving-output-600m'),'p_waste_reason':None,'p_reject_reason':None,'p_notes':'Synthetic flagship demo output: 600 m.'},supervisor)
rolls=output.get('rolls',[])
if len(rolls)!=12 or round(sum(float(r['qty']) for r in rolls),1)!=600:
 raise RuntimeError(f'Expected 12 rolls / 600 m; received {len(rolls)} rolls')
with psycopg.connect(os.environ['SUPABASE_DB_URL']) as c:
 demo_count=c.execute("select count(*) from public.fabric_rolls where output_id=%s and is_demo",(output['output_id'],)).fetchone()[0]
 source_count=c.execute("select count(*) from public.roll_material_sources where roll_id=any(%s::uuid[])",[ [r['roll_id'] for r in rolls] ]).fetchone()[0]
if demo_count!=12 or source_count<12:raise RuntimeError(f'Roll traceability failed: demo_count={demo_count}, material_source_rows={source_count}')
state.update({'output_id':output['output_id'],'rolls':rolls,'weaving_operation_id':weave['id'],'production_qty':600})
STORY.write_text(json.dumps(state,indent=2)+'\n');os.chmod(STORY,0o600)
print('Production/output integration: PASS')
print('Upstream spinning completed; WV-02 weaving output recorded: 600 m.')
print(f"Created {len(rolls)} demo roll passports, each traceable to issued cotton lots; first roll: {rolls[0]['roll_code']}.")
