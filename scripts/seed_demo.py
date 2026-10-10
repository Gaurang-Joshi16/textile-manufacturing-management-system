#!/usr/bin/env python3
"""Idempotently seed the explicitly synthetic Everest Textile demo foundation."""
from __future__ import annotations
import json, os, secrets, urllib.error, urllib.parse, urllib.request, uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
import psycopg
ROOT=Path(__file__).resolve().parents[1]
ENV=ROOT/'supabase'/'.env.local'
for raw in ENV.read_text().splitlines():
    line=raw.strip()
    if line and not line.startswith('#') and '=' in line:
        k,v=line.split('=',1); os.environ[k]=v.strip().strip('"').strip("'")
DB=os.environ['SUPABASE_DB_URL']
URL=os.environ['SUPABASE_URL'].rstrip('/')
SERVICE=os.environ['SUPABASE_SERVICE_ROLE_KEY']
CREDS=ROOT/'supabase'/'.demo-credentials.json'
NAMESPACE=uuid.UUID('9cdaf730-134d-45e9-8dce-a07849d57214')
def key(s:str)->uuid.UUID: return uuid.uuid5(NAMESPACE,s)
def rest(method,path,payload=None):
    body=None if payload is None else json.dumps(payload).encode()
    req=urllib.request.Request(URL+path,data=body,method=method,headers={'apikey':SERVICE,'Authorization':'Bearer '+SERVICE,'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(req,timeout=30) as r: return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        detail=e.read().decode(errors='replace')[:300]
        raise RuntimeError(f'Supabase Auth admin API returned HTTP {e.code}: {detail}') from None

ACCOUNTS=[
 ('admin','admin@everest-demo.test','Demo System Administrator','system_admin',None),
 ('manager','manager@everest-demo.test','Demo Factory Manager','factory_manager','EMP-DEMO-001'),
 ('supervisor','supervisor@everest-demo.test','Demo Production Supervisor','production_supervisor','EMP-DEMO-002'),
 ('operator1','operator1@everest-demo.test','Demo Machine Operator One','machine_operator','EMP-DEMO-003'),
 ('operator2','operator2@everest-demo.test','Demo Machine Operator Two','machine_operator','EMP-DEMO-004'),
 ('storekeeper','storekeeper@everest-demo.test','Demo Storekeeper','storekeeper','EMP-DEMO-005'),
 ('inspector','inspector@everest-demo.test','Demo Quality Inspector','quality_inspector','EMP-DEMO-006'),
 ('dispatch','dispatch@everest-demo.test','Demo Dispatch Officer','dispatch_officer','EMP-DEMO-007'),
 ('hr','hr@everest-demo.test','Demo HR Payroll Officer','hr_payroll_officer','EMP-DEMO-008'),
 ('finance','finance@everest-demo.test','Demo Finance Officer','finance_officer','EMP-DEMO-009'),
 ('buyer.lotus','buyer.lotus@everest-demo.test','Demo Lotus Buyer','buyer','BUY-LOTUS'),
 ('buyer.zenith','buyer.zenith@everest-demo.test','Demo Zenith Buyer','buyer','BUY-ZENITH'),
]

def upsert(conn,table,columns,values,conflict,updates):
    names=','.join(columns); marks=','.join(['%s']*len(values)); sets=','.join(f'{c}=EXCLUDED.{c}' for c in updates)
    return conn.execute(f'INSERT INTO public.{table}({names}) VALUES({marks}) ON CONFLICT({conflict}) DO UPDATE SET {sets} RETURNING id',values).fetchone()[0]
def one(conn,sql,args=()): return conn.execute(sql,args).fetchone()

def main():
    saved=json.loads(CREDS.read_text()) if CREDS.exists() else {'accounts':[]}
    creds={a['email'].lower():a['password'] for a in saved.get('accounts',[]) if a.get('email') and a.get('password')}
    allusers=[]; page=1
    while True:
        data=rest('GET',f'/auth/v1/admin/users?page={page}&per_page=1000')
        users=data.get('users',[])
        allusers.extend(users)
        if len(users)<1000: break
        page+=1
    by_email={u.get('email','').lower():u for u in allusers}
    for alias,email,name,role,link in ACCOUNTS:
        if email.lower() in by_email and email.lower() not in creds:
            raise RuntimeError(f'An existing demo user lacks a recoverable local password: {email}; refusing to reset it.')
        if email.lower() not in by_email:
            creds[email.lower()]=secrets.token_urlsafe(20)
            user=rest('POST','/auth/v1/admin/users',{'email':email,'password':creds[email],'email_confirm':True,'user_metadata':{'full_name':name,'requested_role':role,'demo_account':True}})
            by_email[email.lower()]=user
        uid=by_email[email.lower()].get('id')
        if not uid: raise RuntimeError('Auth admin API did not return a user identifier')
        creds[email.lower()]=creds[email.lower()]
    credential_accounts=[]
    for alias,email,name,role,link in ACCOUNTS:
        credential_accounts.append({'role':role,'alias':alias,'email':email,'password':creds[email.lower()],'user_id':by_email[email.lower()]['id'],'is_demo':True})
    CREDS.write_text(json.dumps({'accounts':credential_accounts},indent=2)+'\n'); os.chmod(CREDS,0o600)
    authids={email:uuid.UUID(by_email[email.lower()]['id']) for _,email,_,_,_ in ACCOUNTS}
    with psycopg.connect(DB,connect_timeout=25) as conn:
        with conn.transaction():
            conn.execute("SET session_replication_role = 'replica'")
            # Departments and assigned shift definitions.
            departments={}
            for code,name in [('ADMIN','Administration'),('PROD','Production'),('STORE','Stores'),('QC','Quality'),('DISPATCH','Dispatch'),('HR','Human Resources'),('FIN','Finance'),('DYE','Dye House')]:
                departments[code]=upsert(conn,'departments',['code','name','is_active','source'],[code,name,True,'DEMO'],'code',['name','is_active','source'])
            shifts={}
            for name,start,end,cross in [('Shift A','06:00','14:00',False),('Shift B','14:00','22:00',False),('Shift C','22:00','06:00',True)]:
                shifts[name]=upsert(conn,'shifts',['name','start_time','end_time','crosses_midnight','timezone','is_active','source'],[name,start,end,cross,'Asia/Kolkata',True,'DEMO'],'name',['start_time','end_time','crosses_midnight','timezone','is_active','source'])
            buyer_ids={}
            for code,name,contact,email in [('BUY-LOTUS','Lotus Home Textiles','Lotus Demo Buyer','buyer.lotus@everest-demo.test'),('BUY-ZENITH','Zenith Apparel','Zenith Demo Buyer','buyer.zenith@everest-demo.test')]:
                buyer_ids[code]=upsert(conn,'buyers',['buyer_code','name','contact_name','email','currency','credit_days','is_active','source'],[code,name,contact,email,'INR',30,True,'DEMO'],'buyer_code',['name','contact_name','email','currency','credit_days','is_active','source'])
            suppliers={}
            for code,name,lead in [('SUP-COTTON','Deccan Cotton Mills',12),('SUP-DYE','Indigo Colourworks',9),('SUP-POLY','Western Fibre Supply',15)]:
                suppliers[code]=upsert(conn,'suppliers',['supplier_code','name','lead_time_days','is_active','source'],[code,name,lead,True,'DEMO'],'supplier_code',['name','lead_time_days','is_active','source'])
            employee_specs=[
                ('EMP-DEMO-001','Demo Factory Manager','Factory manager','ADMIN','manager'),('EMP-DEMO-002','Demo Production Supervisor','Supervisor','PROD','supervisor'),('EMP-DEMO-003','Demo Machine Operator One','Operator','PROD','operator1'),('EMP-DEMO-004','Demo Machine Operator Two','Operator','PROD','operator2'),('EMP-DEMO-005','Demo Storekeeper','Storekeeper','STORE','storekeeper'),('EMP-DEMO-006','Demo Quality Inspector','Inspector','QC','inspector'),('EMP-DEMO-007','Demo Dispatch Officer','Dispatch officer','DISPATCH','dispatch'),('EMP-DEMO-008','Demo HR Payroll Officer','HR officer','HR','hr'),('EMP-DEMO-009','Demo Finance Officer','Finance officer','FIN','finance'),
                ('EMP-DEMO-010','Demo Spinning Technician','Technician','PROD',None),('EMP-DEMO-011','Demo Weaving Operator Three','Operator','PROD',None),('EMP-DEMO-012','Demo Weaving Operator Four','Operator','PROD',None),('EMP-DEMO-013','Demo Dyeing Technician','Technician','DYE',None),('EMP-DEMO-014','Demo Finishing Operator','Operator','PROD',None),('EMP-DEMO-015','Demo QC Inspector Two','Inspector','QC',None),('EMP-DEMO-016','Demo Maintenance Engineer','Engineer','PROD',None),('EMP-DEMO-017','Demo Stores Assistant','Assistant','STORE',None),('EMP-DEMO-018','Demo Production Planner','Planner','PROD',None),('EMP-DEMO-019','Demo Shift Lead B','Shift lead','PROD',None),('EMP-DEMO-020','Demo Shift Lead C','Shift lead','PROD',None),('EMP-DEMO-021','Demo Packing Operator','Operator','DISPATCH',None),('EMP-DEMO-022','Demo Lab Technician','Technician','QC',None),('EMP-DEMO-023','Demo Electrician','Electrician','PROD',None),('EMP-DEMO-024','Demo Warehouse Runner','Runner','STORE',None)]
            employees={}
            for code,name,title,dept,alias in employee_specs:
                shift_name='Shift A' if int(code[-3:])%3==1 else ('Shift B' if int(code[-3:])%3==2 else 'Shift C')
                eid=upsert(conn,'employees',['employee_code','full_name','department_id','designation','employment_status','default_shift_id','joined_on','source'],[code,name,departments[dept],title,'ACTIVE',shifts[shift_name],date.today()-timedelta(days=400),'DEMO'],'employee_code',['full_name','department_id','designation','employment_status','default_shift_id','source'])
                employees[code]=eid
            # Map authentic demo accounts to employees/buyer entities, then activate and assign only their requested role.
            admin_id=authids['admin@everest-demo.test']
            for alias,email,name,role,link in ACCOUNTS:
                uid=authids[email]
                if link and link.startswith('EMP-'): employee_id=employees[link]; buyer_id=None
                elif link and link.startswith('BUY-'): employee_id=None; buyer_id=buyer_ids[link]
                else: employee_id=buyer_id=None
                conn.execute("UPDATE public.profiles SET email=%s,full_name=%s,status='ACTIVE',employee_id=%s,buyer_id=%s,requested_role=%s,approved_by=%s,approved_at=COALESCE(approved_at,now()),is_demo=true WHERE id=%s",(email,name,employee_id,buyer_id,role,admin_id,uid))
                rid=one(conn,'SELECT id FROM public.roles WHERE key=%s',(role,))[0]
                conn.execute('INSERT INTO public.user_roles(user_id,role_id,assigned_by) VALUES(%s,%s,%s) ON CONFLICT(user_id,role_id) DO NOTHING',(uid,rid,admin_id))
            # Remaining demo employees never receive login access by implication.
            products={}
            product_specs=[('FAB-TWILL-INDIGO','Cotton Twill 180 GSM Indigo','Indigo',150,180,'m'),('FAB-POPLIN-WHITE','Poplin 120 GSM White','White',150,120,'m'),('FAB-CANVAS-OLIVE','Canvas 280 GSM Olive','Olive',150,280,'m')]
            for code,desc,colour,width,gsm,unit in product_specs:
                products[code]=upsert(conn,'products',['product_code','description','colour','width_cm','gsm','unit','standard_roll_length','is_active','source'],[code,desc,colour,width,gsm,unit,50,True,'DEMO'],'product_code',['description','colour','width_cm','gsm','unit','standard_roll_length','is_active','source'])
            items={}
            yarn_specs=[('YRN-COT-30S','Cotton yarn 30s','30s','RING_SPUN','Natural',120,500,False,False,suppliers['SUP-COTTON']),('YRN-COT-40S','Cotton yarn 40s','40s','RING_SPUN','Natural',125,250,True,False,suppliers['SUP-COTTON']),('YRN-POLY-30S','Polyester yarn 30s','30s','FILAMENT','White',95,180,False,False,suppliers['SUP-POLY']),('YRN-LINEN-20S','Linen yarn 20s','20s','SPUN','Natural',220,100,True,False,suppliers['SUP-COTTON']),('CHEM-INDIGO','Indigo dye chemical','n/a','DYE_CHEMICAL','Indigo',480,60,True,True,suppliers['SUP-DYE']),('CHEM-REACTIVE','Reactive white dye chemical','n/a','DYE_CHEMICAL','White',360,40,True,True,suppliers['SUP-DYE'])]
            for code,name,count,typ,colour,cost,reorder,inspect,chemical,supplier in yarn_specs:
                items[code]=upsert(conn,'yarn_items',['item_code','name','yarn_count','yarn_type','colour','unit','reorder_point','safety_buffer','preferred_supplier_id','standard_unit_cost','currency','requires_inspection','is_dye_chemical','is_active','source'],[code,name,count,typ,colour,'kg',reorder,0,supplier,cost,'INR',inspect,chemical,True,'DEMO'],'item_code',['name','yarn_count','yarn_type','colour','unit','reorder_point','safety_buffer','preferred_supplier_id','standard_unit_cost','currency','requires_inspection','is_dye_chemical','is_active','source'])
            process_specs=[('SPIN','Spinning','SPINNING',False,1),('WEAVE','Weaving','WEAVING',True,2),('DYE','Dyeing','DYEING',False,3),('FINISH','Finishing','FINISHING',True,4)]
            processes={}
            for code,name,mtype,rolls,seq in process_specs:
                processes[code]=upsert(conn,'process_definitions',['code','name','machine_type','creates_rolls','default_sequence','is_active','source'],[code,name,mtype,rolls,seq,True,'DEMO'],'code',['name','machine_type','creates_rolls','default_sequence','is_active','source'])
            bom=[('FAB-TWILL-INDIGO','YRN-COT-30S',0.32,4),('FAB-POPLIN-WHITE','YRN-COT-40S',0.24,3),('FAB-CANVAS-OLIVE','YRN-LINEN-20S',0.45,5)]
            for product,item,qty,waste in bom:
                conn.execute('INSERT INTO public.product_bom(product_id,yarn_item_id,qty_per_output_unit,wastage_pct,source) VALUES(%s,%s,%s,%s,\'DEMO\') ON CONFLICT(product_id,yarn_item_id) DO UPDATE SET qty_per_output_unit=EXCLUDED.qty_per_output_unit,wastage_pct=EXCLUDED.wastage_pct,source=\'DEMO\'',(products[product],items[item],qty,waste))
            routes={'FAB-TWILL-INDIGO':[('SPIN',True,96,2),('WEAVE',True,98,2),('DYE',True,94,4),('FINISH',True,98,2)],'FAB-POPLIN-WHITE':[('SPIN',True,97,1),('WEAVE',True,98,1),('DYE',False,99,0),('FINISH',True,98,1)],'FAB-CANVAS-OLIVE':[('SPIN',True,95,2),('WEAVE',True,97,2),('DYE',True,94,4),('FINISH',True,97,2)]}
            for pcode,route in routes.items():
                for seq,(pc,app,yieldpct,wastepct) in enumerate(route,1):
                    conn.execute('INSERT INTO public.product_routes(product_id,process_id,sequence,is_applicable,expected_yield_pct,expected_waste_pct,source) VALUES(%s,%s,%s,%s,%s,%s,\'DEMO\') ON CONFLICT(product_id,sequence) DO UPDATE SET process_id=EXCLUDED.process_id,is_applicable=EXCLUDED.is_applicable,expected_yield_pct=EXCLUDED.expected_yield_pct,expected_waste_pct=EXCLUDED.expected_waste_pct,source=\'DEMO\'',(products[pcode],processes[pc],seq,app,yieldpct,wastepct))
            machine_specs=[('SP-01','Ring frame 01','SPIN','SPINNING','A-1',80,'kg'),('WV-01','Loom 01','WEAVE','WEAVING','B-1',60,'m'),('WV-02','Loom 02','WEAVE','WEAVING','B-2',60,'m'),('WV-03','Loom 03','WEAVE','WEAVING','B-3',55,'m'),('WV-04','Loom 04','WEAVE','WEAVING','B-4',55,'m'),('DY-01','Dyeing jet 01','DYE','DYEING','C-1',40,'m'),('FN-01','Finishing line 01','FINISH','FINISHING','C-2',50,'m')]
            machines={}
            for code,name,pc,typ,loc,cap,unit in machine_specs:
                machines[code]=upsert(conn,'machines',['machine_code','name','process_id','machine_type','location','capacity_per_hour','capacity_unit','status','is_active','source'],[code,name,processes[pc],typ,loc,cap,unit,'IDLE',True,'DEMO'],'machine_code',['name','process_id','machine_type','location','capacity_per_hour','capacity_unit','status','is_active','source'])
            warehouses={}
            for code,name,typ in [('RAW','Raw material','RAW'),('WIP','Work in progress','WIP'),('FG','Finished goods','FINISHED'),('QUAR','Quality quarantine','QUARANTINE'),('REWORK','Rework area','REWORK')]:
                warehouses[code]=upsert(conn,'warehouses',['code','name','type','is_active','source'],[code,name,typ,True,'DEMO'],'code',['name','type','is_active','source'])
            locations={}
            for code,name,wh in [('RAW-01','Raw yarn rack 01','RAW'),('WIP-01','Weaving WIP staging','WIP'),('FG-01','Finished goods bay 01','FG'),('QC-01','QC quarantine rack','QUAR'),('RW-01','Rework bay 01','REWORK')]:
                row=one(conn,'SELECT id FROM public.stock_locations WHERE warehouse_id=%s AND code=%s',(warehouses[wh],code))
                if row: lid=row[0];conn.execute("UPDATE public.stock_locations SET description=%s,is_active=true,source='DEMO' WHERE id=%s",(name,lid))
                else: lid=conn.execute("INSERT INTO public.stock_locations(warehouse_id,code,description,is_active,source) VALUES(%s,%s,%s,true,'DEMO') RETURNING id",(warehouses[wh],code,name)).fetchone()[0]
                locations[code]=lid
            # Mark all master-data rows synthetic and seed a visible, deterministic inspection plan per product.
            defect_specs=[('HOLE','Hole','MAJOR','REWORK'),('COLOUR','Colour mismatch','MAJOR','QUARANTINE'),('SLUB','Slub','MEDIUM','REWORK'),('OIL','Oil stain','MAJOR','REWORK'),('WIDTH','Width variation','MEDIUM','REWORK'),('WEIGHT','GSM variation','MEDIUM','REWORK'),('CREASE','Crease','LOW','REWORK'),('CONTAM','Contamination','CRITICAL','QUARANTINE')]
            for code,name,sev,action in defect_specs:
                conn.execute('INSERT INTO public.defect_categories(code,name,default_severity,auto_action,is_active,source) VALUES(%s,%s,%s,%s,true,\'DEMO\') ON CONFLICT(code) DO UPDATE SET name=EXCLUDED.name,default_severity=EXCLUDED.default_severity,auto_action=EXCLUDED.auto_action,is_active=true,source=\'DEMO\'',(code,name,sev,action))
            reasons=[('MECH','Mechanical failure','BREAKDOWN'),('MATERIAL','Waiting for yarn','MATERIAL_WAIT'),('CHANGEOVER','Style changeover','CHANGEOVER'),('OPERATOR','No operator available','NO_OPERATOR'),('POWER','Power interruption','POWER'),('PM','Planned maintenance','PLANNED_MAINT'),('OTHER','Other','OTHER')]
            for code,name,cat in reasons: conn.execute('INSERT INTO public.downtime_reasons(code,name,category,is_active,source) VALUES(%s,%s,%s,true,\'DEMO\') ON CONFLICT(code) DO UPDATE SET name=EXCLUDED.name,category=EXCLUDED.category,is_active=true,source=\'DEMO\'',(code,name,cat))
            costs=[('MATERIAL','Raw materials'),('LABOUR','Labour allocation'),('MACHINE','Machine allocation'),('CHEMICAL','Chemicals'),('MAINTENANCE','Maintenance'),('REWORK','Rework'),('WASTE','Waste'),('PACKAGING','Packaging'),('DISPATCH','Dispatch'),('OTHER','Other')]
            for code,name in costs: conn.execute('INSERT INTO public.cost_categories(code,name,approval_threshold,source) VALUES(%s,%s,10000,\'DEMO\') ON CONFLICT(code) DO UPDATE SET name=EXCLUDED.name,source=\'DEMO\'',(code,name))
            inspections={}
            for pcode,pid in products.items():
                row=one(conn,'SELECT id FROM public.inspection_plans WHERE product_id=%s AND name=%s AND version=1',(pid,'Demo in-process & final check'))
                if row: plan_id=row[0]
                else: plan_id=conn.execute("INSERT INTO public.inspection_plans(product_id,name,version,sampling_rule,is_active,source) VALUES(%s,'Demo in-process & final check',1,'{\"sample\":\"each_roll\"}',true,'DEMO') RETURNING id",(pid,)).fetchone()[0]
                inspections[pcode]=plan_id
                checks=[('Width',145,155,'cm'),('Weight',round({'FAB-TWILL-INDIGO':180,'FAB-POPLIN-WHITE':120,'FAB-CANVAS-OLIVE':280}[pcode]*0.95,1),round({'FAB-TWILL-INDIGO':180,'FAB-POPLIN-WHITE':120,'FAB-CANVAS-OLIVE':280}[pcode]*1.05,1),'gsm'),('Visual defects',0,2,'count')]
                for name,lo,hi,unit in checks:
                    if not one(conn,'SELECT id FROM public.inspection_plan_checks WHERE plan_id=%s AND check_name=%s',(plan_id,name)):
                        conn.execute("INSERT INTO public.inspection_plan_checks(plan_id,check_name,expected_min,expected_max,unit,mandatory,source) VALUES(%s,%s,%s,%s,%s,true,'DEMO')",(plan_id,name,lo,hi,unit))
            part_specs=[('SPARE-BELT','Drive belt',8,2,'each',480),('SPARE-BEAR','Bearing set',6,2,'each',1200),('SPARE-SENSOR','Loom sensor',4,1,'each',2200)]
            for code,name,qty,minimum,unit,cost in part_specs: upsert(conn,'spare_parts',['part_code','name','stock_qty','min_qty','unit','unit_cost','source'],[code,name,qty,minimum,unit,cost,'DEMO'],'part_code',['name','stock_qty','min_qty','unit','unit_cost','source'])
            skill_ids={}
            for code,name in [('SPIN-OP','Spinning operation'),('WEAVE-OP','Weaving operation'),('DYE-OP','Dye house operation'),('QC-INSPECT','Fabric quality inspection'),('FORKLIFT','Forklift certified'),('MAINT','Mechanical maintenance')]:
                skill_ids[code]=upsert(conn,'skills',['code','name','is_active','source'],[code,name,True,'DEMO'],'code',['name','is_active','source'])
            # Deterministic role-skills; additional shop-floor workers receive capabilities by position.
            skillmap={'EMP-DEMO-001':['MAINT'],'EMP-DEMO-002':['WEAVE-OP'],'EMP-DEMO-003':['WEAVE-OP'],'EMP-DEMO-004':['WEAVE-OP'],'EMP-DEMO-006':['QC-INSPECT'],'EMP-DEMO-010':['SPIN-OP'],'EMP-DEMO-011':['WEAVE-OP'],'EMP-DEMO-012':['WEAVE-OP'],'EMP-DEMO-013':['DYE-OP'],'EMP-DEMO-015':['QC-INSPECT'],'EMP-DEMO-016':['MAINT'],'EMP-DEMO-022':['QC-INSPECT'],'EMP-DEMO-023':['MAINT'],'EMP-DEMO-024':['FORKLIFT']}
            for ecode,ss in skillmap.items():
                for sc in ss: conn.execute('INSERT INTO public.employee_skills(employee_id,skill_id,certified_until,is_demo) VALUES(%s,%s,%s,true) ON CONFLICT(employee_id,skill_id) DO UPDATE SET certified_until=EXCLUDED.certified_until,is_demo=true',(employees[ecode],skill_ids[sc],date.today()+timedelta(days=365)))
            for ecode,eid in employees.items():
                # Example compensation data only; not statutory. It is protected by compensation RLS.
                conn.execute("INSERT INTO public.employee_compensation(employee_id,wage_basis,wage_rate,currency,updated_by) VALUES(%s,'MONTHLY',25000,'INR',%s) ON CONFLICT(employee_id) DO NOTHING",(eid,admin_id))
            if conn.execute('SELECT count(*) FROM public.attendance_records WHERE is_demo').fetchone()[0] < len(employees)*14:
                for ecode,eid in employees.items():
                    for idx,sname in enumerate(['Shift A','Shift B','Shift C']):
                        if idx!=int(ecode[-3:])%3: continue
                        for dayoffset in range(14):
                            workday=date.today()-timedelta(days=dayoffset)
                            conn.execute('INSERT INTO public.shift_roster(employee_id,shift_id,work_date,is_demo) VALUES(%s,%s,%s,true) ON CONFLICT(employee_id,shift_id,work_date) DO UPDATE SET is_demo=true',(eid,shifts[sname],workday))
                            si=one(conn,'SELECT id FROM public.shift_instances WHERE shift_id=%s AND work_date=%s',(shifts[sname],workday))
                            if si: shift_instance=si[0]
                            else: shift_instance=conn.execute('INSERT INTO public.shift_instances(shift_id,work_date,is_demo) VALUES(%s,%s,true) RETURNING id',(shifts[sname],workday)).fetchone()[0]
                            # Attendance is synthetic, mostly present, and explicitly pending review.
                            status='PRESENT' if (dayoffset+int(ecode[-3:]))%11 else 'LATE'
                            shift=conn.execute('SELECT start_time FROM public.shifts WHERE id=%s',(shifts[sname],)).fetchone()[0]
                            checkin=datetime.combine(workday,shift).replace(tzinfo=timezone.utc)+timedelta(minutes=10 if status=='LATE' else 0)
                            checkout=checkin+timedelta(hours=8)
                            conn.execute('INSERT INTO public.attendance_records(employee_id,shift_id,work_date,status,check_in,check_out,overtime_minutes,approval_status,source,is_demo) VALUES(%s,%s,%s,%s,%s,%s,0,\'PENDING\',\'MANUAL\',true) ON CONFLICT(employee_id,shift_id,work_date) DO UPDATE SET is_demo=true',(eid,shifts[sname],workday,status,checkin,checkout))
            conn.execute("INSERT INTO public.payroll_rules(name,version,config,effective_from,is_active,disclaimer_ack,is_demo) VALUES('Example monthly payroll — not statutory',1,'{\"basis\":\"monthly\",\"overtime_multiplier\":1.5,\"currency\":\"INR\"}',current_date,true,false,true) ON CONFLICT(name,version) DO NOTHING")
            # Idempotent opening stock only for the cotton-twill yarn item; quantity equals spec opening balance.
            batch=one(conn,"SELECT id FROM public.yarn_batches WHERE batch_code='DEMO-OPENING-COTTON-400' ")[0] if one(conn,"SELECT id FROM public.yarn_batches WHERE batch_code='DEMO-OPENING-COTTON-400'") else None
            if not batch:
                batch=conn.execute("INSERT INTO public.yarn_batches(batch_code,yarn_item_id,supplier_lot,received_qty,accepted_qty,damaged_qty,quarantined_qty,unit,unit_cost,currency,colour,received_date,status,is_demo) VALUES('DEMO-OPENING-COTTON-400',%s,'DEMO-OPENING',400,400,0,0,'kg',120,'INR','Natural',current_date,'AVAILABLE',true) RETURNING id",(items['YRN-COT-30S'],)).fetchone()[0]
                conn.execute("INSERT INTO public.inventory_movements(movement_no,item_kind,yarn_batch_id,movement_type,qty,unit,to_location_id,source_type,reason,idempotency_key,created_by,is_demo) VALUES('MV-DEMO-OPEN-0001','YARN_BATCH',%s,'RECEIPT',400,'kg',%s,'OPENING_STOCK','Synthetic opening stock for deterministic demo',%s,%s,true)",(batch,locations['RAW-01'],key('opening-cotton-400'),admin_id))
            # Integration configuration defaults are honest and fail closed.
            for provider,status,is_sim in [('email','NOT CONFIGURED',False),('whatsapp','NOT CONFIGURED',False),('sms','NOT CONFIGURED',False),('telemetry','SIMULATED',True),('accounting_csv','OK',False),('carrier_tracking','MANUAL ONLY',False),('storage','OK',False),('qr','OK',False),('in_app_alerts','OK',False),('assistant','NOT CONFIGURED',False)]:
                conn.execute('INSERT INTO public.integration_events(provider,event_key,status,payload,is_simulated) VALUES(%s,%s,%s,%s,%s) ON CONFLICT(event_key) DO NOTHING',(provider,f'demo-status:{provider}',status,json.dumps({'status':status,'detail':'Synthetic status record; no provider credentials configured.'}),is_sim))
            # A01-A30 all exist; only lower-risk rules default enabled and never EXECUTE on high-impact paths.
            automation=[('A01','Order confirmation feasibility','factory_manager','NOTIFY'),('A02','Material replenishment suggestion','storekeeper','DRAFT'),('A03','Receipt discrepancy task','storekeeper','NOTIFY'),('A04','Quarantine uncertain receipt','quality_inspector','SUGGEST'),('A05','Plan material reservation','storekeeper','DRAFT'),('A06','Machine availability exception','production_supervisor','NOTIFY'),('A07','Operation delay exception','production_supervisor','NOTIFY'),('A08','Shift handover compile','production_supervisor','DRAFT'),('A09','Output roll creation','production_supervisor','DRAFT'),('A10','Inspection fail containment','quality_inspector','NOTIFY'),('A11','Defect threshold incident','quality_inspector','DRY_RUN'),('A12','Accepted roll stock update','dispatch_officer','DRAFT'),('A13','Dispatch suggestion','dispatch_officer','SUGGEST'),('A14','Shipment post-commit actions','dispatch_officer','DRAFT'),('A15','At-risk delivery notice','factory_manager','NOTIFY'),('A16','Invoice reminder draft','finance_officer','DRAFT'),('A17','Maintenance due work order','production_supervisor','SUGGEST'),('A18','Breakdown downtime event','production_supervisor','NOTIFY'),('A19','Spare below minimum suggestion','storekeeper','SUGGEST'),('A20','Attendance correction approval','hr_payroll_officer','DRAFT'),('A21','Cost variance case','finance_officer','DRY_RUN'),('A22','Milestone notifications','factory_manager','NOTIFY'),('A23','External notification retry','system_admin','DRY_RUN'),('A24','Ledger reconciliation','system_admin','DRY_RUN'),('A25','Override approval workflow','system_admin','DRAFT'),('A26','Buyer change request impact','factory_manager','DRAFT'),('A27','Batch hold trace preview','quality_inspector','SUGGEST'),('A28','Live QR passport state','quality_inspector','NOTIFY'),('A29','Worker skill assignment validation','production_supervisor','NOTIFY'),('A30','Demo/integration state change audit','system_admin','NOTIFY')]
            for code,name,owner,mode in automation:
                conn.execute('INSERT INTO public.automation_rules(code,name,mode,enabled,owner_role,config) VALUES(%s,%s,%s,true,%s,%s) ON CONFLICT(code) DO UPDATE SET name=EXCLUDED.name,mode=EXCLUDED.mode,enabled=true,owner_role=EXCLUDED.owner_role,config=EXCLUDED.config',(code,name,mode,owner,json.dumps({'tier':1 if int(code[1:]) in [1,2,3,4,5,6,7,8,9,10,12,13,14,15,18,23,24,25,27,28] else 2,'demo_seeded':True})))
            # Two long-lived buyer invite codes, created only if absent; actual buyer portals are already demo-approved.
            existing=conn.execute('SELECT buyer_id FROM public.buyer_invites WHERE code LIKE ' + "'BUYER-%-DEMO-%'").fetchall()
            existing_ids={r[0] for r in existing}
            for bcode in ['BUY-LOTUS','BUY-ZENITH']:
                if buyer_ids[bcode] not in existing_ids:
                    prefix='LOTUS' if bcode=='BUY-LOTUS' else 'ZENITH'
                    inv='BUYER-'+prefix+'-DEMO-'+secrets.token_hex(6).upper()
                    conn.execute('INSERT INTO public.buyer_invites(code,buyer_id,expires_at,created_by) VALUES(%s,%s,now()+interval \'365 days\',%s)',(inv,buyer_ids[bcode],admin_id))
        print('Demo seed complete: 12 accounts, 24 employees, 3 buyers/products, 6 yarn items, 7 machines, 5 warehouses, 30 rules, 14-day attendance, 400 kg synthetic opening cotton stock.')
        print('Synthetic passwords stored in private ignored file; none were printed or committed.')

if __name__=='__main__': main()
