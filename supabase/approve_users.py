import psycopg, os
from pathlib import Path
ROOT = Path(__file__).resolve().parent
for raw in (ROOT / ".env.local").read_text().splitlines():
    if '=' in raw and not raw.startswith('#'):
        k, v = raw.split('=', 1)
        os.environ[k.strip()] = v.strip().strip("'").strip('"')

with psycopg.connect(os.environ['SUPABASE_DB_URL']) as conn:
    conn.execute("UPDATE public.profiles SET status = 'ACTIVE', approved_at = now()")
    conn.commit()
print("All users approved successfully")
