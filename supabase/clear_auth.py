import psycopg, os
from pathlib import Path
ROOT = Path(__file__).resolve().parent
for raw in (ROOT / ".env.local").read_text().splitlines():
    if '=' in raw and not raw.startswith('#'):
        k, v = raw.split('=', 1)
        os.environ[k.strip()] = v.strip().strip("'").strip('"')
with psycopg.connect(os.environ['SUPABASE_DB_URL']) as conn:
    conn.execute("TRUNCATE auth.users CASCADE")
    conn.commit()
print("Cleared existing demo users")
