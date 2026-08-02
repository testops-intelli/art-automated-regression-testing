#!/usr/bin/env python3
"""
create_env.py — ART demo environment builder.

Reads connection + database-name config from .env (see .env.example),
drops and recreates the pre/post databases, then loads sql/*.sql into
them by filename convention:

    0i_create*.sql   -> both DBs, in numeric order (ref/data layer, FK order matters)
    *_pre.sql        -> pre DB only
    *_post.sql       -> post DB only
    anything else    -> both DBs (no _pre/_post suffix means "no drift",
                        e.g. create_transactions_listing.sql)

Engine support is modular: DB_TYPE in .env selects an adapter from the
ADAPTERS registry below. Only "postgresql" is implemented today; adding
another engine (e.g. sql server) means writing one SqlAdapter subclass
and registering it — no changes to the orchestration logic in main().
"""

import os
import re
import sys
from pathlib import Path

from dotenv import load_dotenv

# --------------------------------------------------------------------
# Config — loaded from .env in this file's directory
# --------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).parent.parent   # .env lives at project root, shared with art_setup_config.py
SCRIPT_DIR = Path(__file__).parent            # create_env/
SQL_DIR = SCRIPT_DIR / "sql"

load_dotenv(PROJECT_ROOT / ".env")

DB_TYPE = os.environ.get("DB_TYPE", "postgresql").strip().lower()
DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_USER = os.environ.get("DB_USER")
DB_PASSWORD = os.environ.get("DB_PASSWORD")
PRE_DB = os.environ.get("PRE_DB_NAME", "art_pre")
POST_DB = os.environ.get("POST_DB_NAME", "art_post")
ART_SCHEMA = os.environ.get("ART_SCHEMA", "art")

NUMBERED_RE = re.compile(r"^(\d+)_.*\.sql$")


def require_config():
    missing = [k for k, v in {"DB_USER": DB_USER, "DB_PASSWORD": DB_PASSWORD}.items() if not v]
    if missing:
        sys.exit(
            f"Missing required .env value(s): {', '.join(missing)}. "
            f"Copy .env.example to .env and fill it in."
        )
    if not re.fullmatch(r"[a-z_][a-z0-9_]*", ART_SCHEMA):
        sys.exit(
            f"ART_SCHEMA '{ART_SCHEMA}' is not a plain lowercase identifier "
            f"(letters/digits/underscore, not starting with a digit). It is substituted "
            f"into DDL as an identifier, so it must be one."
        )


# --------------------------------------------------------------------
# Engine adapters
#
# Each adapter owns exactly two operations: dropping/recreating a named
# database on the server, and running one .sql file's full text against
# a named database. Everything else (file discovery, classification,
# run order) is engine-agnostic and lives in main().
# --------------------------------------------------------------------
class SqlAdapter:
    def recreate_database(self, dbname: str) -> None:
        raise NotImplementedError

    def run_file(self, dbname: str, path: Path) -> None:
        raise NotImplementedError

    def run_sql(self, dbname: str, sql_text: str) -> None:
        raise NotImplementedError


class PostgresAdapter(SqlAdapter):
    def __init__(self, host, port, user, password, maintenance_db="postgres"):
        import psycopg2  # deferred import: only required if this adapter is used
        self._psycopg2 = psycopg2
        self._pgsql = __import__("psycopg2.sql", fromlist=["sql"])
        self.host = host
        self.port = int(port)
        self.user = user
        self.password = password
        self.maintenance_db = maintenance_db

    def _conn_params(self, dbname):
        return dict(host=self.host, port=self.port, user=self.user,
                    password=self.password, dbname=dbname)

    def recreate_database(self, dbname):
        # Deliberately NOT using `with psycopg2.connect(...) as conn:` here.
        # That context manager wraps the block in transaction semantics
        # that conflict with autocommit, and DROP DATABASE / CREATE DATABASE
        # must run outside any transaction block or Postgres raises
        # "DROP DATABASE cannot run inside a transaction block" even with
        # autocommit=True set.
        conn = self._psycopg2.connect(**self._conn_params(self.maintenance_db))
        conn.autocommit = True
        try:
            cur = conn.cursor()
            cur.execute(
                """
                SELECT pg_terminate_backend(pid)
                FROM pg_stat_activity
                WHERE datname = %s AND pid <> pg_backend_pid();
                """,
                (dbname,),
            )
            cur.execute(self._pgsql.SQL("DROP DATABASE IF EXISTS {}").format(self._pgsql.Identifier(dbname)))
            cur.execute(self._pgsql.SQL("CREATE DATABASE {}").format(self._pgsql.Identifier(dbname)))
            cur.close()
        finally:
            conn.close()

    def run_file(self, dbname, path: Path):
        self.run_sql(dbname, path.read_text())

    def run_sql(self, dbname, sql_text: str):
        conn = self._psycopg2.connect(**self._conn_params(dbname))
        conn.autocommit = True
        try:
            cur = conn.cursor()
            cur.execute(sql_text)
            cur.close()
        finally:
            conn.close()


# Aliases map onto the same adapter; unregistered DB_TYPE values fail
# with a clear message rather than a bare KeyError.
ADAPTERS = {
    "postgresql": PostgresAdapter,
    "postgres": PostgresAdapter,
    "pg": PostgresAdapter,
}


def get_adapter():
    if DB_TYPE not in ADAPTERS:
        sys.exit(
            f"Unsupported DB_TYPE '{DB_TYPE}'. Supported today: {sorted(set(ADAPTERS))}. "
            f"Only PostgreSQL is implemented — add another engine by writing a new "
            f"SqlAdapter subclass and registering it in ADAPTERS."
        )
    return ADAPTERS[DB_TYPE](host=DB_HOST, port=DB_PORT, user=DB_USER, password=DB_PASSWORD)


# --------------------------------------------------------------------
# ART metadata schema
#
# Created in BOTH databases so pre/post schemas stay identical by
# design, but the wizard writes metadata to PRE only and the runner
# reads from PRE only — same "pre is ground truth" convention as
# art_setup_config.py's introspection.
#
# candidates_<report> tables are per-report (one column per business
# key) and are created by the wizard at onboarding time, not here.
# --------------------------------------------------------------------
ART_METADATA_DDL = """
CREATE SCHEMA IF NOT EXISTS {schema};

DROP TABLE IF EXISTS {schema}.params_metadata;
DROP TABLE IF EXISTS {schema}.reports_metadata;

CREATE TABLE {schema}.reports_metadata
(
    report_id        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    report_name      TEXT NOT NULL UNIQUE,
    report_type      TEXT NOT NULL,          -- 'sql_function' (extensible: proc, api_call)
    target           TEXT NOT NULL,          -- schema-qualified routine, e.g. public.positions
    primary_key      TEXT NOT NULL,          -- comma-separated PK columns of the report output
    pk_nullable      TEXT,                   -- comma-separated PK columns that may be NULL
    candidates_table TEXT,                   -- e.g. candidates_positions; NULL if no business keys
    tolerances       TEXT                    -- optional per-column numeric tolerance for the diff,
                                             -- 'col=eps;col=eps' (hand-set; NULL = exact everywhere)
);

CREATE TABLE {schema}.params_metadata
(
    report_id     INTEGER NOT NULL REFERENCES {schema}.reports_metadata(report_id),
    param_id      INTEGER NOT NULL,          -- ordinal position in the routine signature
    param_name    TEXT NOT NULL,
    param_kind    TEXT NOT NULL,             -- 'business_key' | 'enum'
    enum_inferred BOOLEAN,                   -- enum only: TRUE = resolved from pg_enum
    enum_values   TEXT,                      -- enum only: comma-separated ('NULL' = SQL NULL)
    optional_pair TEXT,                      -- business_key only: partner param (XOR pairing)
    nullable      BOOLEAN NOT NULL DEFAULT FALSE,  -- business_key only: NULL is a valid branch
                                             -- (modeled for completeness; no demo report uses it)
    CONSTRAINT pk_params_metadata PRIMARY KEY (report_id, param_id)
);
"""


# --------------------------------------------------------------------
# File classification (engine-agnostic)
# --------------------------------------------------------------------
def classify(path: Path) -> str:
    name = path.name
    if NUMBERED_RE.match(name):
        return "both_numbered"
    if name.endswith("_pre.sql"):
        return "pre_only"
    if name.endswith("_post.sql"):
        return "post_only"
    return "both_other"


def collect_buckets():
    files = sorted(SQL_DIR.glob("*.sql"))
    if not files:
        sys.exit(f"No .sql files found in {SQL_DIR}")

    buckets = {"both_numbered": [], "pre_only": [], "post_only": [], "both_other": []}
    for f in files:
        buckets[classify(f)].append(f)

    buckets["both_numbered"].sort(key=lambda f: int(NUMBERED_RE.match(f.name).group(1)))
    for key in ("pre_only", "post_only", "both_other"):
        buckets[key].sort(key=lambda f: f.name)

    return buckets


# --------------------------------------------------------------------
# Main
# --------------------------------------------------------------------
def main():
    require_config()

    if not SQL_DIR.is_dir():
        sys.exit(f"SQL directory not found: {SQL_DIR}")

    adapter = get_adapter()
    buckets = collect_buckets()

    print(f"Engine: {DB_TYPE}  |  pre={PRE_DB}  post={POST_DB}  host={DB_HOST}:{DB_PORT}")
    print("Files discovered:")
    for key in ("both_numbered", "both_other", "pre_only", "post_only"):
        for f in buckets[key]:
            print(f"  [{key:>13}] {f.name}")

    print("\nRecreating databases...")
    adapter.recreate_database(PRE_DB)
    print(f"  recreated {PRE_DB}")
    adapter.recreate_database(POST_DB)
    print(f"  recreated {POST_DB}")

    print("\nLoading numbered scripts (both DBs, numeric order)...")
    for f in buckets["both_numbered"]:
        adapter.run_file(PRE_DB, f)
        print(f"    [{PRE_DB}] {f.name}")
        adapter.run_file(POST_DB, f)
        print(f"    [{POST_DB}] {f.name}")

    print("\nLoading identical (no-drift) scripts into both DBs...")
    for f in buckets["both_other"]:
        adapter.run_file(PRE_DB, f)
        print(f"    [{PRE_DB}] {f.name}")
        adapter.run_file(POST_DB, f)
        print(f"    [{POST_DB}] {f.name}")

    print(f"\nLoading {PRE_DB}-only scripts...")
    for f in buckets["pre_only"]:
        adapter.run_file(PRE_DB, f)
        print(f"    [{PRE_DB}] {f.name}")

    print(f"\nLoading {POST_DB}-only scripts...")
    for f in buckets["post_only"]:
        adapter.run_file(POST_DB, f)
        print(f"    [{POST_DB}] {f.name}")

    print(f"\nCreating ART metadata schema '{ART_SCHEMA}' in both DBs...")
    ddl = ART_METADATA_DDL.format(schema=ART_SCHEMA)
    adapter.run_sql(PRE_DB, ddl)
    print(f"    [{PRE_DB}] schema {ART_SCHEMA}: reports_metadata, params_metadata")
    adapter.run_sql(POST_DB, ddl)
    print(f"    [{POST_DB}] schema {ART_SCHEMA}: reports_metadata, params_metadata")

    n_pre = len(buckets["both_numbered"]) + len(buckets["both_other"]) + len(buckets["pre_only"])
    n_post = len(buckets["both_numbered"]) + len(buckets["both_other"]) + len(buckets["post_only"])
    print(f"\nDone. {PRE_DB}: {n_pre} scripts | {POST_DB}: {n_post} scripts")


if __name__ == "__main__":
    main()
