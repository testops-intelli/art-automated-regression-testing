#!/usr/bin/env python3
"""
art_setup_config.py — ART report onboarding wizard.

Flow:
  1. Confirm core .env is ready (server type, creds, pre/post db names) —
     loops, re-reading .env each time, until you answer y.
  2. Report name + target (function/proc name) + type.
  3. Introspect IN params from the catalog. For each: enum-typed params
     auto-resolve from pg_enum (no prompt). Everything else: business key
     or bool/enum (with hand-declared values, since the type doesn't
     enforce them). Business keys additionally get a mandatory/optional
     pairing question — see note below.
  4. Primary key, validated against the report's actual return columns
     (introspected via information_schema.parameters, parameter_mode='OUT'
     — reads the compiled catalog signature, not the SQL text). Not
     inferred, by design — you said you don't want that guessed.
  5. Writes metadata to the ART tables on the PRE database
     (art.reports_metadata + art.params_metadata) — re-onboarding a
     report name replaces its previous metadata after a confirm prompt.
     A human-readable YAML export of the same config is also written to
     yaml/<report_name>.yaml so the repo shows config at a glance; the
     runner reads only the tables.
  6. If the report has any business keys, creates art.candidates_<report>
     on PRE — wide form: candidate_id + one column per business key —
     and seeds it with FILL_ME placeholder rows (one per candidate).
     The wizard then loops until you've replaced the placeholders with
     real values (edit via SQL or any client), re-checking the table
     each time. Enum values are never stored in candidates: the runner
     expands enum branches itself.

Mandatory/optional pairing, first-pass design:
  A business-key param can be declared "optional, paired with X" (exactly
  one of the pair is supplied per run — e.g. entity_id vs group_id). You
  only declare this once, on whichever of the two you reach first; the
  partner is auto-marked optional+paired when the script gets to it, with
  a note explaining why, rather than asking twice for the same fact.

Deliberately still open, per report_name_candidates.yaml being a rough
first pass: real candidate VALUES are hand-filled, not pulled from actual
data. Auto-suggesting real values from the pre DB is a reasonable next
step but wasn't asked for here.
"""

import os
import re
import sys
from datetime import datetime
from pathlib import Path

import yaml
from dotenv import load_dotenv

PROJECT_DIR = Path(__file__).parent
YAML_DIR = PROJECT_DIR / "yaml"   # all generated report configs live here

SUPPORTED_TYPES = {"sql_function"}
SUPPORTED_DB_TYPES = {"postgresql", "postgres", "pg"}


# --------------------------------------------------------------------
# Step 1 — core env gate
# --------------------------------------------------------------------
def load_core_env():
    load_dotenv(PROJECT_DIR / ".env", override=True)
    return {
        "db_type": os.environ.get("DB_TYPE", "postgresql").strip().lower(),
        "host": os.environ.get("DB_HOST", "localhost"),
        "port": os.environ.get("DB_PORT", "5432"),
        "user": os.environ.get("DB_USER"),
        "password": os.environ.get("DB_PASSWORD"),
        "pre_db": os.environ.get("PRE_DB_NAME", "art_pre"),
        "post_db": os.environ.get("POST_DB_NAME", "art_post"),
    }


def confirm_env_ready():
    while True:
        cfg = load_core_env()
        print(f"\nCore .env: type={cfg['db_type']}  host={cfg['host']}:{cfg['port']}  "
              f"user={cfg['user']}  pre_db={cfg['pre_db']}  post_db={cfg['post_db']}")
        problems = []
        if not cfg["user"] or not cfg["password"]:
            problems.append("DB_USER / DB_PASSWORD missing")
        if cfg["db_type"] not in SUPPORTED_DB_TYPES:
            problems.append(f"DB_TYPE '{cfg['db_type']}' not supported yet (postgresql only)")
        if problems:
            print("  " + "; ".join(problems))

        ans = input("Ready to continue with these values? [y/n]: ").strip().lower()
        if ans in ("y", "yes"):
            if problems:
                print("  can't continue until the above is fixed in .env.")
                continue
            return cfg
        print("  edit .env and save, then answer y.")


def get_connection(cfg):
    import psycopg2
    return psycopg2.connect(host=cfg["host"], port=int(cfg["port"]), user=cfg["user"],
                             password=cfg["password"], dbname=cfg["pre_db"])
    # introspection reads PRE only — schema is identical pre/post by
    # design (only report bodies differ), so PRE is the "ground truth"


# --------------------------------------------------------------------
# Introspection — all native catalog queries, no .sql text parsing
# --------------------------------------------------------------------
def find_routines(conn, target: str, schema: str = "public"):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT specific_name FROM information_schema.routines "
            "WHERE routine_name = %s AND routine_schema = %s",
            (target, schema),
        )
        return [r[0] for r in cur.fetchall()]


def get_params(conn, specific_name: str, mode: str, schema: str = "public"):
    """mode: 'IN' or 'OUT'. Returns [(name, data_type, udt_name)] for IN,
    or [name, ...] for OUT (name only needed there)."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT parameter_name, data_type, udt_name FROM information_schema.parameters "
            "WHERE specific_name = %s AND specific_schema = %s AND parameter_mode = %s "
            "ORDER BY ordinal_position",
            (specific_name, schema, mode),
        )
        rows = cur.fetchall()
    if mode == "OUT":
        return [r[0] for r in rows]
    return rows


def get_enum_values(conn, udt_name: str):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT e.enumlabel FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid "
            "WHERE t.typname = %s ORDER BY e.enumsortorder",
            (udt_name,),
        )
        rows = [r[0] for r in cur.fetchall()]
        return rows or None


# --------------------------------------------------------------------
# Step 3 — param classification, incl. mandatory/optional pairing
# --------------------------------------------------------------------
def classify_param(name, data_type, udt_name, enum_values, all_param_names, pending_pairs):
    if enum_values is not None:
        if name in pending_pairs:
            print(f"    note: '{name}' was set as pair partner for '{pending_pairs[name]}', "
                  f"but it's a catalog enum, not a business key — ignoring that pairing.")
        print(f"  {name} ({udt_name}) — enum, resolved from catalog: {enum_values}")
        return {"kind": "enum", "infer": True, "values": enum_values}

    print(f"  {name} ({data_type})")

    if name in pending_pairs:
        partner = pending_pairs[name]
        print(f"    auto-paired with '{partner}' (declared when '{partner}' was classified) "
              f"— marking optional business key, no questions asked twice")
        return {"kind": "business_key", "optional": True, "pairs_with": partner}

    while True:
        choice = input("    business key or bool/enum? [b/e]: ").strip().lower()
        if choice in ("e", "enum", "bool/enum", "bool"):
            # inner loop: a bad value list re-asks for values only, rather
            # than bouncing back to the business-key/enum question
            while True:
                raw = input("    allowed values (comma-separated): ").strip()
                values = [v.strip() for v in raw.split(",") if v.strip()]
                if not values:
                    print("    need at least one value — try again.")
                    continue
                bad = invalid_for_type(values, data_type)
                if bad:
                    # caught here rather than at execution time, where it
                    # surfaces as a cast error on every branch using the value
                    print(f"    {', '.join(repr(b) for b in bad)} not valid for a "
                          f"{data_type} parameter — try again.")
                    continue
                return {"kind": "enum", "infer": False, "values": values}
        if choice in ("b", "business_key", "business key"):
            break
        print("    please answer 'b' (business key) or 'e' (bool/enum)")

    while True:
        pair_choice = input(
            "    mandatory, or optional as one of a pair with another business key "
            "(exactly one of the pair is supplied per run)? [m/o]: "
        ).strip().lower()
        if pair_choice in ("m", "mandatory"):
            return {"kind": "business_key", "optional": False}
        if pair_choice in ("o", "optional"):
            while True:
                partner = input("      pair partner param name: ").strip()
                if partner == name:
                    print("      can't pair a param with itself.")
                elif partner not in all_param_names:
                    print(f"      '{partner}' isn't one of this report's params: {all_param_names}")
                else:
                    break
            pending_pairs[partner] = name
            return {"kind": "business_key", "optional": True, "pairs_with": partner}
        print("    please answer 'm' (mandatory) or 'o' (optional/paired)")


# --------------------------------------------------------------------
# Step 4 — primary key (shown, never inferred)
# --------------------------------------------------------------------
def prompt_primary_key(out_columns):
    print(f"\nReturn columns: {out_columns}")
    while True:
        raw = input("Primary key column(s) (comma-separated): ").strip()
        pk = [v.strip() for v in raw.split(",") if v.strip()]
        bad = [c for c in pk if c not in out_columns]
        if not pk:
            print("  need at least one PK column — try again.")
        elif bad:
            print(f"  not in return columns: {bad} — try again.")
        else:
            return pk


def prompt_pk_nullable(pk):
    raw = input(f"Any of {pk} that can be NULL for some param values? "
                f"(comma-separated, blank if none): ").strip()
    if not raw:
        return []
    nullable = [v.strip() for v in raw.split(",") if v.strip()]
    bad = [c for c in nullable if c not in pk]
    if bad:
        print(f"  ignoring {bad} — not in the declared primary key {pk}")
    return [c for c in nullable if c in pk]


# --------------------------------------------------------------------
# Step 5/6 — metadata written to the ART tables (PRE db) + yaml export
# --------------------------------------------------------------------
IDENT_RE = re.compile(r"^[a-z_][a-z0-9_]*$")


def invalid_for_type(values, data_type):
    """Which of these hand-declared enum values can't be passed to a
    parameter of this catalog type. 'NULL' is always allowed — it's the
    runner's notation for calling with SQL NULL, not a literal value.
    Only types with a cheap, unambiguous check are validated; anything
    else is left alone rather than guessing."""
    checkers = {
        "integer": lambda v: v.lstrip("+-").isdigit(),
        "smallint": lambda v: v.lstrip("+-").isdigit(),
        "bigint": lambda v: v.lstrip("+-").isdigit(),
        "boolean": lambda v: v.lower() in ("true", "false", "t", "f", "1", "0"),
        "character": lambda v: len(v) == 1,
        '"char"': lambda v: len(v) == 1,
    }
    check = checkers.get(data_type)
    if not check:
        return []
    return [v for v in values if v != "NULL" and not check(v)]


def load_art_schema():
    schema = os.environ.get("ART_SCHEMA", "art").strip().lower()
    if not IDENT_RE.fullmatch(schema):
        sys.exit(f"ART_SCHEMA '{schema}' is not a plain lowercase identifier.")
    return schema


def require_identifier(value: str, what: str) -> str:
    """Values interpolated into DDL/queries as identifiers (report name →
    candidates table name, param names → column names) must be plain
    identifiers. Param names always are (they come from the catalog),
    but the report name is user-typed."""
    v = value.strip().lower()
    if not IDENT_RE.fullmatch(v):
        sys.exit(f"{what} '{value}' must be a plain lowercase identifier "
                 f"(letters/digits/underscore, not starting with a digit) — it is "
                 f"used as part of a table name.")
    return v


def write_yaml(path: Path, data, header: str = ""):
    """Human-readable export of what was written to the ART tables. The
    runner reads only the tables; this file exists so the repo shows the
    onboarded config at a glance. Always overwritten — the tables are
    the source of truth, so a stale export is worse than a replaced one."""
    YAML_DIR.mkdir(exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        if header:
            f.write(header.rstrip() + "\n\n")
        yaml.safe_dump(data, f, sort_keys=False, default_flow_style=False, allow_unicode=True)
    print(f"Wrote {path.name} (export of the ART metadata tables)")


def confirm_replace_if_onboarded(conn, schema, report_name):
    """If this report name is already registered, confirm replacement up
    front — before any further prompting — so the user isn't asked to
    answer questions for a run they're about to abort. Returns the
    existing (report_id, candidates_table) or None."""
    with conn.cursor() as cur:
        cur.execute(
            f"SELECT report_id, candidates_table FROM {schema}.reports_metadata "
            f"WHERE report_name = %s", (report_name,))
        existing = cur.fetchone()
    if existing:
        ans = input(f"Report '{report_name}' is already onboarded. Replace its "
                    f"metadata (and drop its candidates table)? [y/n]: ").strip().lower()
        if ans not in ("y", "yes"):
            sys.exit("Aborting — existing metadata left untouched.")
    return existing


def replace_report_metadata(conn, schema, report_name, report_type, target,
                            primary_key, pk_nullable, candidates_table, params_config,
                            business_keys=None, existing=None):
    """Insert the report + its params into the ART tables, and create its
    (empty) candidates table in the SAME transaction. Replacement of an
    existing report is confirmed earlier by confirm_replace_if_onboarded.

    Creating the table here rather than afterwards matters: if the process
    dies between the two writes, the metadata row would outlive the table
    it points at and the runner would hit a missing relation. One
    transaction means the report is either fully registered or not at all."""
    with conn.cursor() as cur:
        if existing:
            old_id, old_cand = existing
            cur.execute(f"DELETE FROM {schema}.params_metadata WHERE report_id = %s", (old_id,))
            cur.execute(f"DELETE FROM {schema}.reports_metadata WHERE report_id = %s", (old_id,))
            if old_cand:
                cur.execute(f"DROP TABLE IF EXISTS {schema}.{old_cand}")

        cur.execute(
            f"INSERT INTO {schema}.reports_metadata "
            f"(report_name, report_type, target, primary_key, pk_nullable, candidates_table) "
            f"VALUES (%s, %s, %s, %s, %s, %s) RETURNING report_id",
            (report_name, report_type, target,
             ",".join(primary_key),
             ",".join(pk_nullable) if pk_nullable else None,
             candidates_table),
        )
        report_id = cur.fetchone()[0]

        for ordinal, (pname, pcfg) in enumerate(params_config.items(), start=1):
            is_enum = pcfg["kind"] == "enum"
            cur.execute(
                f"INSERT INTO {schema}.params_metadata "
                f"(report_id, param_id, param_name, param_kind, enum_inferred, "
                f" enum_values, optional_pair, nullable) "
                f"VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
                (report_id, ordinal, pname, pcfg["kind"],
                 pcfg.get("infer") if is_enum else None,
                 ",".join(str(v) for v in pcfg["values"]) if is_enum else None,
                 pcfg.get("pairs_with"),
                 False),
            )

        if candidates_table:
            cols = ", ".join(f"{name} {cfg['data_type']}"
                             for name, cfg in business_keys.items())
            cur.execute(f"DROP TABLE IF EXISTS {schema}.{candidates_table}")
            cur.execute(
                f"CREATE TABLE {schema}.{candidates_table} "
                f"(candidate_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, {cols})")

    conn.commit()
    print(f"Metadata written to {schema}.reports_metadata / {schema}.params_metadata "
          f"(report_id={report_id}).")
    if candidates_table:
        print(f"Created {schema}.{candidates_table} "
              f"(columns: candidate_id, {', '.join(business_keys)}).")
    return report_id


def prompt_candidate_count():
    while True:
        raw = input("How many candidate rows? (default 3): ").strip()
        if not raw:
            return 3
        if raw.isdigit() and int(raw) > 0:
            return int(raw)
        print("  need a positive integer.")


def coerce_value(raw, data_type):
    """Validate + convert one typed cell entry -> (ok, value_or_message).
    Deliberately narrow: types with a cheap unambiguous parse are checked
    here, anything else passes through as text for Postgres to accept or
    reject on insert."""
    if data_type in ("integer", "smallint", "bigint"):
        try:
            return True, int(raw)
        except ValueError:
            return False, f"not a valid {data_type}"
    if data_type in ("numeric", "double precision", "real"):
        try:
            return True, float(raw)
        except ValueError:
            return False, f"not a valid {data_type}"
    if data_type in ("date", "timestamp without time zone", "timestamp with time zone"):
        for fmt in ("%Y-%m-%d", "%Y-%m-%d %H:%M:%S"):
            try:
                dt = datetime.strptime(raw, fmt)
                return True, dt.date() if data_type == "date" else dt
            except ValueError:
                continue
        return False, "expected YYYY-MM-DD (or YYYY-MM-DD HH:MM:SS)"
    if data_type == "boolean":
        if raw.lower() in ("true", "t", "yes", "y", "1"):
            return True, True
        if raw.lower() in ("false", "f", "no", "n", "0"):
            return True, False
        return False, "expected true/false"
    return True, raw


def prompt_and_insert_candidates(conn, schema, cand_table, business_keys, n_rows):
    """Prompt for every business-key value of every candidate inline, then
    insert. Replaces the old 'go UPDATE the table yourself' step: values
    are type-checked at the prompt against the routine's catalog types,
    inserts are parameterized, and the table is never half-filled. Blank
    input re-prompts — every business key needs a value, since one side of
    every XOR pair is supplied on each branch."""
    print(f"\nEnter candidate values ({n_rows} candidate(s), "
          f"{len(business_keys)} value(s) each):")
    paired = [n for n, c in business_keys.items() if c.get("pairs_with")]
    if paired:
        print(f"  note: {' and '.join(paired)} are a mutually exclusive pair, but fill in "
              f"both — each\n  candidate is run once per branch (one side supplied, the "
              f"other NULL), never both\n  at once.")
    rows = []
    for i in range(1, n_rows + 1):
        print(f"\n  candidate_{i}")
        row = {}
        for name, cfg in business_keys.items():
            dtype = cfg["data_type"]
            while True:
                raw = input(f"    {name} ({dtype}): ").strip()
                if not raw:
                    print("      value required — every business key needs one.")
                    continue
                ok, result = coerce_value(raw, dtype)
                if not ok:
                    print(f"      {result} — try again.")
                    continue
                row[name] = result
                break
        rows.append(row)

    cols = list(business_keys)
    placeholders = ", ".join(["%s"] * len(cols))
    with conn.cursor() as cur:
        for row in rows:
            cur.execute(
                f"INSERT INTO {schema}.{cand_table} ({', '.join(cols)}) "
                f"VALUES ({placeholders})",
                [row[c] for c in cols])
    conn.commit()

    with conn.cursor() as cur:
        cur.execute(f"SELECT candidate_id, {', '.join(cols)} FROM {schema}.{cand_table} "
                    f"ORDER BY candidate_id")
        inserted = cur.fetchall()
    print(f"\nInserted {len(inserted)} candidate(s) into {schema}.{cand_table}:")
    print(f"    candidate_id | {' | '.join(cols)}")
    for r in inserted:
        print(f"    {' | '.join(str(v) for v in r)}")


# --------------------------------------------------------------------
# Main
# --------------------------------------------------------------------
def main():
    cfg = confirm_env_ready()
    art_schema = load_art_schema()

    report_name = require_identifier(input("\nReport name: "), "Report name")

    target = input("Target (function/proc name, e.g. public.positions): ").strip()
    type_ = input(f"Type [{'/'.join(SUPPORTED_TYPES)}] (default sql_function): ").strip() or "sql_function"
    if type_ not in SUPPORTED_TYPES:
        sys.exit(f"Type '{type_}' not supported yet. Supported today: {sorted(SUPPORTED_TYPES)}.")

    schema, _, bare_name = target.rpartition(".") if "." in target else ("public", "", target)
    schema = schema or "public"

    conn = get_connection(cfg)
    try:
        matches = find_routines(conn, bare_name, schema)
        if not matches:
            sys.exit(f"No routine named '{bare_name}' found in schema '{schema}' on {cfg['pre_db']}.")
        if len(matches) > 1:
            sys.exit(f"Multiple overloads of '{bare_name}' found — not handled by this wizard yet.")
        specific_name = matches[0]

        in_params = get_params(conn, specific_name, "IN", schema)
        if not in_params:
            sys.exit(f"'{bare_name}' has no IN parameters — nothing to onboard.")
        all_param_names = [p[0] for p in in_params]

        print(f"\n{len(in_params)} parameter(s) found for {schema}.{bare_name}:\n")

        params_config, pending_pairs = {}, {}
        for name, data_type, udt_name in in_params:
            enum_values = get_enum_values(conn, udt_name) if data_type == "USER-DEFINED" else None
            cfg_entry = classify_param(
                name, data_type, udt_name, enum_values, all_param_names, pending_pairs
            )
            # remember the catalog type: business-key columns in the
            # candidates table are typed to match the routine signature
            cfg_entry["data_type"] = udt_name if data_type == "USER-DEFINED" else data_type
            params_config[name] = cfg_entry

        out_columns = get_params(conn, specific_name, "OUT", schema)
        if not out_columns:
            sys.exit(f"'{bare_name}' has no return columns — can't declare a primary key.")
        primary_key = prompt_primary_key(out_columns)
        pk_nullable = prompt_pk_nullable(primary_key)

        business_keys = {n: c for n, c in params_config.items()
                         if c.get("kind") == "business_key"}
        cand_table = f"candidates_{report_name}" if business_keys else None

        # asked before the write so the whole registration (metadata +
        # candidates table) happens in one uninterruptible step
        existing = confirm_replace_if_onboarded(conn, art_schema, report_name)
        n_rows = prompt_candidate_count() if business_keys else 0

        replace_report_metadata(
            conn, art_schema, report_name, type_, f"{schema}.{bare_name}",
            primary_key, pk_nullable, cand_table, params_config, business_keys,
            existing,
        )

        # yaml export mirrors the tables, minus DB-internal ids
        report_entry = {
            "type": type_,
            "target": f"{schema}.{bare_name}",
            "primary_key": primary_key,
            "params": params_config,
        }
        if pk_nullable:
            report_entry["pk_nullable"] = pk_nullable
        if cand_table:
            report_entry["candidates_table"] = f"{art_schema}.{cand_table}"
        write_yaml(YAML_DIR / f"{report_name}.yaml", report_entry)

        if business_keys:
            prompt_and_insert_candidates(conn, art_schema, cand_table,
                                         business_keys, n_rows)
        else:
            print("No business keys on this report — no candidates table needed.")
    finally:
        conn.close()

    print(f"\n'{report_name}' onboarded — metadata and candidates are in the "
          f"{art_schema} schema on {cfg['pre_db']}. Run the report with "
          f"art_runner.py.")


if __name__ == "__main__":
    main()
