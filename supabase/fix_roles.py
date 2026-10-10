import psycopg, os
from pathlib import Path

ROOT = Path(r"E:\everest-textile")
for raw in (ROOT / "supabase" / ".env.local").read_text().splitlines():
    if '=' in raw and not raw.startswith('#'):
        k, v = raw.split('=', 1)
        os.environ[k.strip()] = v.strip().strip("'").strip('"')

ACCOUNTS=[
 ('admin','admin@everest-demo.test','Demo System Administrator','system_admin'),
 ('manager','manager@everest-demo.test','Demo Factory Manager','factory_manager'),
 ('supervisor','supervisor@everest-demo.test','Demo Production Supervisor','production_supervisor'),
 ('operator1','operator1@everest-demo.test','Demo Machine Operator One','machine_operator'),
 ('operator2','operator2@everest-demo.test','Demo Machine Operator Two','machine_operator'),
 ('storekeeper','storekeeper@everest-demo.test','Demo Storekeeper','storekeeper'),
 ('inspector','inspector@everest-demo.test','Demo Quality Inspector','quality_inspector'),
 ('dispatch','dispatch@everest-demo.test','Demo Dispatch Officer','dispatch_officer'),
 ('hr','hr@everest-demo.test','Demo HR Payroll Officer','hr_payroll_officer'),
 ('finance','finance@everest-demo.test','Demo Finance Officer','finance_officer'),
 ('buyer.lotus','buyer.lotus@everest-demo.test','Demo Lotus Buyer','buyer'),
 ('buyer.zenith','buyer.zenith@everest-demo.test','Demo Zenith Buyer','buyer'),
]

with psycopg.connect(os.environ['SUPABASE_DB_URL']) as conn:
    # Get admin ID
    admin_row = conn.execute("SELECT id FROM auth.users WHERE email = 'admin@everest-demo.test'").fetchone()
    admin_id = admin_row[0] if admin_row else None

    for alias, email, name, role in ACCOUNTS:
        uid_row = conn.execute("SELECT id FROM auth.users WHERE email = %s", (email,)).fetchone()
        if not uid_row: continue
        uid = uid_row[0]
        
        # Approve user
        conn.execute("UPDATE public.profiles SET status = 'ACTIVE', approved_at = now(), approved_by = %s WHERE id = %s", (admin_id, uid))
        
        # Assign role
        rid_row = conn.execute("SELECT id FROM public.roles WHERE key = %s", (role,)).fetchone()
        if rid_row:
            conn.execute("INSERT INTO public.user_roles(user_id, role_id, assigned_by) VALUES(%s, %s, %s) ON CONFLICT DO NOTHING", (uid, rid_row[0], admin_id))

    conn.commit()
print("All users approved and roles assigned!")
