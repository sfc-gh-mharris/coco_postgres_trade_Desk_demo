"""Run SQL files against the desk Postgres instance from SPCS and print every result set.

Postgres only admits clients on its network policy (Snowflake egress ranges), so the installer
applies DDL and runs the governance tests from a job service with this script.

Env:
  PGHOST        Postgres host
  SQL_FILES     space-separated list of <file>@<login>; each file runs as the login whose
                credentials are mounted at /secrets/<login>/{username,password}
  PG_CA         root CA file (default: the mounted GENERIC_STRING secret)

Tokens {{SECRET_PASSWORD:<login>}} are replaced with the SQL-quoted password mounted at
/secrets/<login>/password. Substituted SQL is never printed.
"""
import json
import os
import re
import sys

import psycopg
from psycopg import sql as pgsql

HOST = os.environ["PGHOST"]
DB = os.environ.get("PGDATABASE", "postgres")
CA = os.environ.get("PG_CA", "/secrets/pg_ca/secret_string")
TOKEN = re.compile(r"\{\{SECRET_PASSWORD:([a-z_]+)\}\}")


def read(path: str) -> str:
    with open(path) as f:
        return f.read().strip()


def run_file(path: str, login: str) -> None:
    info = psycopg.conninfo.make_conninfo(
        host=HOST, port=5432, dbname=DB,
        user=read(f"/secrets/{login}/username"), password=read(f"/secrets/{login}/password"),
        sslmode="verify-full", sslrootcert=CA, connect_timeout=15, application_name="desk_sqlrunner",
    )
    print(f"SQLRUN_FILE {os.path.basename(path)} as {login}", flush=True)
    with psycopg.connect(info, autocommit=True) as conn:
        text = TOKEN.sub(
            lambda m: pgsql.Literal(read(f"/secrets/{m.group(1)}/password")).as_string(conn), read(path))
        cur = conn.execute(text)
        n = 0
        while True:
            n += 1
            if cur.description:
                cols = [d.name for d in cur.description]
                rows = [dict(zip(cols, r)) for r in cur.fetchall()]
                print(f"SQLRUN_RESULT {n} " + json.dumps(rows, default=str), flush=True)
            else:
                print(f"SQLRUN_STATUS {n} {cur.statusmessage}", flush=True)
            if not cur.nextset():
                break


def main() -> int:
    for item in os.environ["SQL_FILES"].split():
        path, login = item.rsplit("@", 1)
        try:
            run_file(path, login)
        except Exception as e:
            # print only the primary message line; later context lines can echo statement text
            print(f"SQLRUN_ERROR {os.path.basename(path)} {type(e).__name__}: {str(e).splitlines()[0][:400]}",
                  flush=True)
            return 2
    print("SQLRUN_DONE", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
