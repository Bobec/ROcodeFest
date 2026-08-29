#requires -Version 5.1
<#
=====================================================================
 ROcodeFest  migration runner
=====================================================================
 A database with data in it cannot be rebuilt, and until now rebuilding
 was the only way this project had to change a schema: 01_oltp_schema.sql
 is CREATE-only and db/run_qa.ps1 drops the database on every run. That
 is fine for CI and for development, and it is the reason a deploy would
 have been destructive.

 So there are two paths to the current schema and both stay supported:

   from scratch   psql -f 00_ 01_ 02_ 03_
                  Fast, readable, and the canonical description of the
                  schema. What CI and development use.

   by migration   pwsh db/migrate.ps1
                  Applies whatever db/migrations/ holds that this
                  database has not had yet. What a database with real
                  data uses.

 They must end up identical, and that is not left to discipline:
 db/qa_migrations.sql fails the build if the migration files and the
 stamps in 00_app_schema.sql disagree, and the CI job rebuilds a
 database from the PREVIOUS commit's schema, migrates it forward, and
 diffs the structure against the current one.

 USAGE
   pwsh db/migrate.ps1                     apply everything pending
   pwsh db/migrate.ps1 -DryRun             say what would run, run nothing
   pwsh db/migrate.ps1 -Stamp 0002_x       record as applied WITHOUT running
   pwsh db/migrate.ps1 -Database rocodefest_test

 Connection comes from the usual PG* environment variables, or the
 parameters below.
=====================================================================
#>
param(
  [string] $DbHost   = $(if ($env:PGHOST)     { $env:PGHOST }     else { 'localhost' }),
  [int]    $Port     = $(if ($env:PGPORT)     { [int]$env:PGPORT } else { 5432 }),
  [string] $User     = $(if ($env:PGUSER)     { $env:PGUSER }     else { 'postgres' }),
  [string] $Database = $(if ($env:PGDATABASE) { $env:PGDATABASE } else { 'rocodefest' }),
  [string] $PsqlPath = $(if ($env:PSQL_PATH)  { $env:PSQL_PATH }  else { 'psql' }),
  [switch] $DryRun,
  [string] $Stamp
)

# Deliberately NOT 'Stop'. Every psql call below is a native
# executable, and PowerShell 5.1 turns each of its stderr lines into an
# ErrorRecord -- so with Stop, a NOTICE ("schema app already exists,
# skipping") terminates the script as though the migration had failed.
# Every call checks $LASTEXITCODE explicitly instead, which is the only
# thing that actually says whether psql succeeded.
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$migrationsDir = Join-Path $here 'migrations'
$conn = @('-h', $DbHost, '-p', $Port, '-U', $User, '-d', $Database, '-v', 'ON_ERROR_STOP=1')

# stderr goes to a file rather than through 2>&1. PowerShell 5.1 wraps
# every stderr line from a native executable in an ErrorRecord, and psql
# writes NOTICE to stderr -- so "schema app already exists, skipping"
# was being reported as a failed migration.
$script:ErrFile = Join-Path ([System.IO.Path]::GetTempPath()) "rocodefest_migrate_err.txt"

function Psql-Err { if (Test-Path $script:ErrFile) { (Get-Content $script:ErrFile -Raw) } else { "" } }

function Psql-Scalar([string] $sql) {
  $out = & $PsqlPath @conn -tA -c $sql 2>$script:ErrFile
  if ($LASTEXITCODE -ne 0) { throw "psql: $(Psql-Err)" }
  return ($out | Out-String).Trim()
}

function Sha256([string] $path) {
  return (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower()
}

# ---------------------------------------------------------------------
# The bookkeeping table has to exist before anything can be recorded,
# and it may not: an older database predates it. Creating it here means
# the runner works against a database that has never been migrated,
# which is exactly the case it exists for.
# ---------------------------------------------------------------------
$bootstrap = @'
-- Quiet: every IF NOT EXISTS below emits a NOTICE on a database that
-- already has these, and none of it is news.
SET client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS app;
CREATE TABLE IF NOT EXISTS app.schema_migrations (
  version     TEXT PRIMARY KEY,
  applied_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  checksum    TEXT,
  duration_ms INTEGER
);
'@
& $PsqlPath @conn -q -c $bootstrap 2>$script:ErrFile | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Nu m-am putut conecta la $Database pe $DbHost`:$Port" -ForegroundColor Red
  Write-Host (Psql-Err)
  exit 1
}

# ---------------------------------------------------------------------
# What exists on disk, and what this database has already had
# ---------------------------------------------------------------------
if (-not (Test-Path $migrationsDir)) {
  Write-Host "Nu exista $migrationsDir" -ForegroundColor Red; exit 1
}
$onDisk = Get-ChildItem -Path $migrationsDir -Filter '*.sql' | Sort-Object Name
$applied = @{}
$rows = & $PsqlPath @conn -tA -F '|' -c "SELECT version, COALESCE(checksum,'') FROM app.schema_migrations ORDER BY version;" 2>$script:ErrFile
if ($LASTEXITCODE -ne 0) { throw "psql: $(Psql-Err)" }
foreach ($r in $rows) {
  if ([string]::IsNullOrWhiteSpace($r)) { continue }
  $p = $r -split '\|', 2
  $applied[$p[0]] = $p[1]
}

# --- -Stamp: record without running ----------------------------------
# For a database that already has the change by some other route -- most
# often one built from the schema files. It writes a checksum, so the
# drift report below can still tell whether the file has changed since.
if ($Stamp) {
  $f = $onDisk | Where-Object { $_.BaseName -eq $Stamp }
  if (-not $f) { Write-Host "Nu exista migrarea $Stamp" -ForegroundColor Red; exit 1 }
  $sum = Sha256 $f.FullName
  & $PsqlPath @conn -q -c "INSERT INTO app.schema_migrations(version, checksum) VALUES ('$Stamp', '$sum') ON CONFLICT (version) DO UPDATE SET checksum = EXCLUDED.checksum;" | Out-Null
  Write-Host "STAMPED  $Stamp  (marcata ca aplicata, fara sa ruleze)" -ForegroundColor Yellow
  exit 0
}

# ---------------------------------------------------------------------
# Report before doing anything
# ---------------------------------------------------------------------
Write-Host ""
Write-Host "=============== MIGRARI ===============" -ForegroundColor Cyan
Write-Host "baza: $Database pe $DbHost`:$Port"
Write-Host ""

$pending = @()
foreach ($f in $onDisk) {
  $v = $f.BaseName
  $sum = Sha256 $f.FullName
  if ($applied.ContainsKey($v)) {
    $was = $applied[$v]
    if ([string]::IsNullOrEmpty($was)) {
      # Stamped by the from-scratch build. Not a fault, and saying so
      # beats a blank column that reads like missing data.
      "  {0,-30} {1}" -f $v, "aplicata (din schema de la zero)" | Write-Host -ForegroundColor DarkGray
    } elseif ($was -ne $sum) {
      # An applied migration whose file has since changed. The database
      # did NOT get what the file now says, and re-running is not the
      # fix -- the fix is a new migration.
      "  {0,-30} {1}" -f $v, "APLICATA, DAR FISIERUL S-A SCHIMBAT" | Write-Host -ForegroundColor Red
      Write-Host "      baza a primit $($was.Substring(0,12))..., fisierul este acum $($sum.Substring(0,12))..."
      Write-Host "      O migrare aplicata nu se editeaza. Scrie una noua."
      $driftFound = $true
    } else {
      "  {0,-30} {1}" -f $v, "aplicata" | Write-Host -ForegroundColor DarkGray
    }
  } else {
    "  {0,-30} {1}" -f $v, "IN ASTEPTARE" | Write-Host -ForegroundColor Yellow
    $pending += $f
  }
}

# A version recorded in the database with no file behind it means the
# checkout is older than the database, and applying anything else would
# be applying it out of order.
$orphans = $applied.Keys | Where-Object { $n = $_; -not ($onDisk | Where-Object { $_.BaseName -eq $n }) }
if ($orphans) {
  Write-Host ""
  Write-Host "  Baza cunoaste migrari care nu exista in acest checkout:" -ForegroundColor Red
  $orphans | ForEach-Object { Write-Host "    $_" }
  Write-Host "  Baza este mai noua decat codul. Nu aplic nimic."
  exit 1
}

if ($driftFound) {
  Write-Host ""
  Write-Host "Oprit: o migrare deja aplicata a fost editata." -ForegroundColor Red
  exit 1
}

if ($pending.Count -eq 0) {
  Write-Host ""
  Write-Host "Nimic de aplicat." -ForegroundColor Green
  exit 0
}

if ($DryRun) {
  Write-Host ""
  Write-Host "DryRun: $($pending.Count) migrare/migrari ar rula." -ForegroundColor Cyan
  exit 0
}

# ---------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------
# Each migration runs inside ONE transaction together with the row that
# records it. Half a migration plus no record is the state nobody can
# reason about afterwards: the next run would try it again on a database
# that already has part of it.
#
# An advisory lock, held for the whole run, keeps two deploys landing at
# once from both deciding the same migration is pending. It is released
# when the connection closes, including if this process is killed.
Write-Host ""
$failed = $false
foreach ($f in $pending) {
  $v = $f.BaseName
  $sum = Sha256 $f.FullName
  $t0 = Get-Date

  # The lock number is arbitrary but must be the same everywhere; it is
  # the digits of "rocodefest" on a phone keypad, and nothing else in
  # this database takes advisory locks.
  $wrapper = @"
-- Quiet the NOTICEs. Every CREATE ... IF NOT EXISTS in a migration
-- emits one, they are not news, and on a failure the real message is
-- an ERROR which is unaffected by this.
SET client_min_messages = warning;
SELECT pg_advisory_lock(762633378);
BEGIN;
\i $($f.FullName -replace '\\', '/')
INSERT INTO app.schema_migrations(version, checksum, duration_ms)
VALUES ('$v', '$sum', 0)
ON CONFLICT (version) DO UPDATE SET checksum = EXCLUDED.checksum;
COMMIT;
SELECT pg_advisory_unlock(762633378);
"@
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "rocodefest_migrate_$v.sql"
  [System.IO.File]::WriteAllText($tmp, $wrapper, (New-Object System.Text.UTF8Encoding $false))

  & $PsqlPath @conn -q -f $tmp 2>$script:ErrFile | Out-Null
  $applyFailed = ($LASTEXITCODE -ne 0)
  $out = Psql-Err
  $ms = [int]((Get-Date) - $t0).TotalMilliseconds
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue

  if ($applyFailed) {
    "  {0,-30} {1}" -f $v, "ESUAT" | Write-Host -ForegroundColor Red
    ($out | Out-String).Trim() -split "`n" | Select-Object -First 6 | ForEach-Object { Write-Host "      $_" }
    Write-Host ""
    Write-Host "Tranzactia a dat inapoi. Baza este exact cum era inainte de aceasta migrare." -ForegroundColor Red
    $failed = $true
    break
  }

  & $PsqlPath @conn -q -c "UPDATE app.schema_migrations SET duration_ms = $ms WHERE version = '$v';" | Out-Null
  "  {0,-30} {1}" -f $v, "aplicata in ${ms}ms" | Write-Host -ForegroundColor Green
}

Write-Host ""
if ($failed) {
  Write-Host "MIGRARE OPRITA. Migrarile de dinaintea celei care a esuat raman aplicate." -ForegroundColor Red
  exit 1
}
$total = Psql-Scalar "SELECT count(*) FROM app.schema_migrations;"
Write-Host "Gata. Baza este la zi ($total migrari inregistrate)." -ForegroundColor Green
exit 0
