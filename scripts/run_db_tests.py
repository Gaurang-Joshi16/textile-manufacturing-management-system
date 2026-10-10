#!/usr/bin/env python3
"""Run SQL database tests against the Supabase project."""
from pathlib import Path
import os
import psycopg
ROOT=Path(__file__).resolve().parents[1]
for raw in (ROOT/'supabase'/'.env.local').read_text().splitlines():
 line=raw.strip()
 if line and not line.startswith('#') and '=' in line:
  k,v=line.split('=',1);os.environ[k]=v.strip().strip('"').strip("'")
files=sorted((ROOT/'supabase'/'tests').glob('*.sql'))
with psycopg.connect(os.environ['SUPABASE_DB_URL'],connect_timeout=20) as conn:
 for path in files:
  conn.execute(path.read_text())
  print(f'{path.name}: PASS')
print(f'Database test suite: PASS ({len(files)} file(s))')
