ART — Automated Regression Testing for Financial Report SQL
ART detects pre/post upgrade drift in database report functions. Point it
at two copies of the same database — one running the pre-upgrade report code,
one running the post-upgrade code — and it executes every report across an
automatically derived parameter space, diffs the outputs row-by-row, and
produces an evidence workbook a developer can debug from directly.
The repo ships a self-contained demo: a financial reporting schema (entities,
securities, prices, FX rates, transactions, income) with three report
functions, two of which carry deliberately injected code drift:
Report	Drift	Where
`positions`	FX rate cutoff `<=` became `<`	`create_positions_pre.sql` vs `_post.sql` (1 line)
`pnl`	income cutoff `pay_date - 1` became `pay_date`	`create_pnl_pre.sql` vs `_post.sql` (1 line)
`transactions_listing`	none — control case	single shared script
Both drifts are boundary-condition bugs: they only fire for parameter values
that land on the boundary, which is exactly what makes them realistic and
what makes parameter-space coverage matter.
How it works
Metadata-driven. Report definitions live in relational metadata tables in
the `art` schema (`reports_metadata`, `params_metadata`, plus one wide-form
`candidates_<report>` table per report holding business-key values). The
runner reads only these tables; YAML files under `yaml/` are human-readable
exports of the same config, written by the onboarding wizard for at-a-glance
review.
Automatic parameter-space derivation. The runner builds the unresolved
parameter space itself from the metadata:
each XOR pair of business keys (e.g. `p_entity_id` vs `p_group_id` —
exactly one supplied per call) contributes two branches
each enum parameter contributes one branch per declared value; the
declared value `NULL` means SQL NULL (e.g. `p_active_flag` ∈ {0, 1, NULL})
mandatory business keys appear in every branch
the space is the cartesian product — e.g. `transactions_listing`:
(fund | group) × settled(Y|N) × active_flag(0|1|NULL) = 12 combinations
Each combination is then resolved against the first N candidates
(`--iterations N`, deterministic by `candidate_id`; default all). One
combination × candidate = one execution, run identically on pre and post.
What a candidate row actually is. A row in `candidates_<report>` is not
one call's parameters — it's a pool of business-key values the runner
draws from, holding one value for every business key the report accepts. The
runner decides per branch which ones to use. So a single `positions` candidate
of `p_entity_id=2, p_group_id=1, p_as_of_date=2026-07-31` produces eight
executions:
```
exec 1-4:  p_entity_id=2,    p_group_id=NULL   <- entity branch, x settled/lots
exec 5-8:  p_entity_id=NULL, p_group_id=1      <- group branch,  x settled/lots
```
Both keys are filled in the row, but never both supplied to the same call —
the function's XOR guard is respected on every execution. The two values are
independent test inputs that happen to share a row (entity 2 need not belong
to group 1); the row just answers "if this branch needs an entity, use 2; if it
needs a group, use 1."
The upside is that branch coverage can't be silently skipped — every candidate
exercises both sides of every pair. The cost is that you supply a value for
each key even if you only care about one branch, which is why the wizard asks
for all of them.
Comparison. Per execution, rows are matched on the report's declared
primary key (`pk_nullable` columns join NULL-safely). Findings are
categorized: `row_missing_in_pre` / `row_missing_in_post` (PK on one side
only), `value_mismatch` (any non-PK column differs — exact by default, with
optional per-column numeric tolerance via `reports_metadata.tolerances`,
format `col=eps;col=eps`), and `duplicate_pk` (a PK repeated within one
side — the duplication itself is the finding).
Evidence workbook. Each run writes `outputs/<report>_<timestamp>.xlsx`:
`Pre_output` / `Post_output` — every row from every execution, tagged with
execution id and resolved parameters
`Reports` / `Params` / `Candidates` — the exact metadata that drove the run
`Flagged_Diffs` — one row per finding, including the fully resolved
paste-and-run query (`SELECT * FROM public.positions(2, NULL, 'Y', '2026-07-31', 'Y');`) so a developer can reproduce any diff in one step
`Summary` — pass/fail and diff counts per execution, distinct flagged
columns, totals
Exit code: `0` clean, `1` diffs found, `2` setup error — CI-friendly.
Quickstart
Prereqs: Python 3.10+, a PostgreSQL server you can create databases on.
0. Clone the repo:
```bash
git clone https://github.com/testops-intelli/art-automated-regression-testing.git
cd art-automated-regression-testing
```
```powershell
git clone https://github.com/testops-intelli/art-automated-regression-testing.git
Set-Location art-automated-regression-testing
```
```
pip install -r requirements.txt
```
Then create your `.env` from the template and fill in `DB_USER` / `DB_PASSWORD`:
```bash
cp .env.example .env            # macOS / Linux
```
```powershell
Copy-Item .env.example .env     # Windows PowerShell
```
1. Build the demo environment (drops and recreates both databases,
loads the schema + data + report functions, creates the ART metadata tables):
```
python create_env/create_env.py
```
2. Onboard each report — the wizard introspects the function's signature
from the catalog (enum-typed params like `art_yn` auto-resolve their value
domains from `pg_enum`; everything else is declared interactively, with
hand-declared values type-checked against the parameter's catalog type),
records the primary key, writes the metadata tables, then prompts inline for
each candidate's business-key values and inserts them. Values are validated
as you type — no SQL, no second terminal, nothing left half-filled:
```
python art_setup_config.py
```
3. Run a regression:
```
python art_runner.py positions
python art_runner.py pnl
python art_runner.py transactions_listing
python art_runner.py positions --iterations 1   # first candidate only
```
Expected demo outcome: `positions` and `pnl` FAIL with value mismatches
confined to exactly the drift-affected columns (`fx_rate` /
`market_value_local`, and `income` / `total_pnl` / `pct_return`
respectively); `transactions_listing` passes clean across all 24 executions.
Note the boundary behavior on `positions`: a candidate whose as-of date
lands exactly on an FX rate date flags, while a mid-month as-of date passes
— the two cutoff operators resolve to the same rate there.
Layout
```
create_env/create_env.py    environment builder (drop/recreate DBs, load sql/, ART schema)
create_env/sql/             demo schema + data + report functions (pre/post variants)
art_setup_config.py         report onboarding wizard (catalog introspection -> metadata tables)
art_runner.py               regression runner (param space -> execute -> diff -> xlsx)
yaml/                       human-readable exports of the onboarded metadata
outputs/                    run evidence workbooks (gitignored)
```
Design notes / extension points
Engines. `DB_TYPE` selects an adapter from `ADAPTERS` in
`create_env.py`; only PostgreSQL is implemented. Adding SQL Server means
one `SqlAdapter` subclass (plus T-SQL ports of the demo functions) — the
orchestration doesn't change.
Report types. `reports_metadata.report_type` is `sql_function` today;
the runner rejects anything else explicitly. Stored procedures or API-call
reports slot in as new execution strategies against the same metadata and
comparison layer.
Nullable business keys. `params_metadata.nullable` models
supplied-vs-NULL branching for business keys; the schema supports it, no
demo report exercises it (all three demo functions reject NULL dates by
design).
Metadata lives on the pre database only (both DBs get the schema so
they stay structurally identical; pre is the ground truth the wizard
introspects and the runner reads — only report bodies differ pre/post).
