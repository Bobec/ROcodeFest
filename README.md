# ROcodeFest

A robotics and programming festival platform: a PostgreSQL database with an
OLTP schema and an analytics star schema, plus the festival's static web pages.

Built and tested against **PostgreSQL 18.6**. Some constraints require 15 or
newer (`ON DELETE SET NULL (column)`), so an older server will not load the
schema.

---

## What is here

```
db/                      the database — schema, ETL, and the QA suites
db/proposals/            the reasoning behind each schema change (see below)
*.html                   29 static pages: index, login, forum, leaderboard,
                         judge-scoring, partner-dashboard, submissions, …
rocodefest-rules.pdf     the competition rulebook
```

There is **no application layer** — no server, no API, no build step. The pages
are static HTML and cannot currently reach the database. This is why several
recorded findings are marked as needing an application before they can be
closed: authorisation, in particular, is unowned at the database layer.

---

## The pipeline

Three files, in order. The order is a dependency order, not a preference:

```bash
psql -d rocodefest -f db/01_oltp_schema.sql      # tables, constraints, triggers
psql -d rocodefest -f db/02_analytics_schema.sql # star schema + reporting views
psql -d rocodefest -f db/03_etl.sql              # installs the loader functions
psql -d rocodefest -c "SELECT analytics.run_etl();"   # runs a load
```

`03_etl.sql` only **installs** the ETL functions. Nothing is loaded until
`run_etl()` is called — a distinction worth knowing, because a suite that loads
the file and forgets the call is looking at an empty warehouse.

The loader is idempotent: running it three times leaves the warehouse
bit-identical to running it once, and that claim is asserted rather than
assumed.

---

## Running the tests

```powershell
$env:PGPASSWORD = "…"
./db/run_qa.ps1                 # every suite
./db/run_qa.ps1 -Only forum     # one of them
```

Each suite builds its own throwaway database, runs, and is dropped again — so
the tests never touch a real one. The full run takes about 20 seconds.

**The runner is a gate, not a report.** It exits non-zero on a regression, and
also when a known issue starts passing or reports fewer findings than the
baseline says it should. A baseline that only ever gets longer stops meaning
anything, so fixing something is required to force an edit to
`db/qa_known_issues.txt`.

### How the assertions are written

Every negative case is paired with a positive control that must actually take
effect. A rejection only counts if the same statement, differing in exactly the
respect under test, goes through — otherwise a passing test proves only that
*something* failed. Three further guards back this up:

- a statement that succeeds while touching **zero rows** is a failure, never a pass
- rejections declare their expected SQLSTATE, so "refused for the wrong reason"
  is caught rather than credited
- a `qa_lint()` pass reports unpaired negatives and suites that prove no premises

Findings the schema does not yet answer are recorded as **GAP** rather than
failure. They stay visible on every run without turning the runner permanently
red.

---

## `db/proposals/`

Each file is a schema change with the evidence that motivated it, the reasoning
for the shape chosen, and a verification script. All are **adopted** — their
contents live in `01_`/`02_` and the pipeline builds from there.

They are kept as records, not migrations: running one against a current
database would fail on objects that already exist. The pipeline carries the
short form of each decision; these files carry the long one.

| | |
|---|---|
| **R2** | match ↔ judge assignment, so only an assigned judge can score |
| **R3** | the resubmission gate: a new version needs the previous one to have asked |
| **R4** | `SET search_path` pinned on every trigger function |
| **R5** | rule citations pin the revision they cited |
| **R6** | forum attachments, quotas, thread integrity, comment cycles |
| **R7** | closing a decision: who, when, and under which rule |
| **R8** | agreements that needed no decision from anyone |
