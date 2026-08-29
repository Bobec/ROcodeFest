# =====================================================================
# QA runner — every suite, one aggregated verdict
# =====================================================================
# Before this existed, only 99_tests.sql was ever re-run. The qa_* suites
# were one-shot artefacts: a schema change tomorrow would not have been
# caught by any of them, because nobody would have thought to run them.
#
#   .\db\run_qa.ps1                     # all suites
#   .\db\run_qa.ps1 -Only reviews       # one suite by name
#   .\db\run_qa.ps1 -KeepDatabases      # leave the throwaway DBs behind
#
# Exit code: 0 only if every suite exits 0. Each suite decides its own
# exit; gaps and PENDING items are findings, not failures.
# =====================================================================
param(
  [string] $Only = "",
  [switch] $KeepDatabases,
  [string] $PsqlPath = "C:\Program Files\PostgreSQL\18\bin\psql.exe",
  [string] $DbHost   = "localhost",
  [int]    $Port     = 5432,
  [string] $User     = "postgres"
)

$ErrorActionPreference = "Continue"
if (-not $env:PGPASSWORD) {
  Write-Host "PGPASSWORD is not set; psql will prompt or fail." -ForegroundColor Yellow
}
$db = Split-Path -Parent $MyInvocation.MyCommand.Path
$conn = @("-U", $User, "-h", $DbHost, "-p", "$Port")

# name        : suite identifier
# file        : script to run
# schemas     : which of 01/02/03 it needs loaded first
$suites = @(
  @{ name="oltp_full";     file="99_tests.sql";                   schemas=@("01","02","03") },
  @{ name="reviews";       file="qa_submission_reviews.sql";      schemas=@("01","02","03") },
  @{ name="judge_feedback";file="qa_judge_feedback.sql";          schemas=@("01","02","03") },
  @{ name="resubmission";  file="qa_resubmission.sql";            schemas=@("01") },
  @{ name="search_path";   file="qa_search_path_regression.sql";  schemas=@("01","02","03") },
  @{ name="misresolution"; file="qa_r4_search_path_probe.sql";    schemas=@("01") },
  @{ name="gate_blocks";   file="qa_r4_blocks_t1_t5.sql";         schemas=@("01") },
  # needs a SECOND backend via dblink; the runner hands it a conninfo
  # below. Without one the suite records SKIPPED, never PASS.
  @{ name="concurrency";   file="qa_concurrency.sql";             schemas=@("01"); needsConninfo=$true },
  @{ name="notifications"; file="qa_notifications.sql";           schemas=@("01") },
  @{ name="rule_refs";     file="qa_rule_references.sql";         schemas=@("01") },
  @{ name="forum";         file="qa_forum.sql";                   schemas=@("01") },
  # the only suite that CALLS analytics.run_etl(). The others load 03_
  # without running it, which installs the functions and leaves the
  # warehouse empty -- so a view could return nothing at all and every
  # other suite would still be green.
  @{ name="analytics";     file="qa_analytics.sql";               schemas=@("01","02","03") },
  # asks whether a row agrees with ITSELF -- decided-by-nobody verdicts,
  # intervals that end before they begin, statuses with no transition
  # rule. Every other suite asks whether a row may exist at all.
  @{ name="lifecycle";     file="qa_lifecycle.sql";               schemas=@("01") },
  # the domain that had ONE case in the whole ledger before this suite,
  # and that one was about a view's provenance rather than about partners
  @{ name="partners";      file="qa_partners.sql";                schemas=@("01") },
  # The bookkeeping behind the two ways of building this database. It is
  # the only suite that loads 00_: every other one tests the
  # competition, and this one tests the plumbing underneath it.
  @{ name="migrations";    file="qa_migrations.sql";              schemas=@("00","01") }
)

$schemaFiles = @{ "00"="00_app_schema.sql"; "01"="01_oltp_schema.sql"; "02"="02_analytics_schema.sql"; "03"="03_etl.sql" }
$results = @()
$started = Get-Date

# ---------------------------------------------------------------------
# Known open findings. A suite listed here may exit non-zero without
# failing the run -- otherwise the runner is permanently red and stops
# being a regression gate. The list is self-cleaning: a listed suite that
# starts passing FAILS the run, forcing the entry to be removed.
#
# Each entry also carries HOW MANY findings it is excusing. Without that
# number the baseline is keyed on red-vs-green and cannot see partial
# progress: a suite holding three findings that drops to one still exits
# non-zero, stays KNOWN, and keeps a reason line naming a finding that is
# already closed. The count makes both directions trip --
#   fewer than expected  a finding was closed; the entry is now overstated
#   more than expected   a NEW finding is hiding behind the excuse
# -- which is what the "nothing may be added here to silence a new
# failure" rule below needs in order to be enforceable rather than
# merely stated.
#
# Format:  suite | proposal | findings | reason
# ---------------------------------------------------------------------
$knownFile = Join-Path $db "qa_known_issues.txt"
$known = @{}
if (Test-Path $knownFile) {
  foreach ($line in Get-Content $knownFile) {
    $t = $line.Trim()
    if ($t -eq "" -or $t.StartsWith("#")) { continue }
    $parts = $t -split '\|', 4
    if ($parts.Count -ge 4) {
      $n = 0
      $countField = $parts[2].Trim()
      $known[$parts[0].Trim()] = @{
        proposal = $parts[1].Trim()
        # a non-numeric count means "not tracked" and falls back to the
        # old red-vs-green behaviour rather than failing the run
        findings = $(if ([int]::TryParse($countField, [ref]$n)) { $n } else { $null })
        reason   = $parts[3].Trim()
      }
    }
    elseif ($parts.Count -ge 2) {
      $known[$parts[0].Trim()] = @{
        proposal = $parts[1].Trim()
        findings = $null
        reason   = ($parts[2..($parts.Count-1)] -join '|').Trim()
      }
    }
  }
}

# How many open findings did a suite report? Two summary shapes exist:
# qa_finish() prints "live-failures=L ... gaps=G", and the misresolution
# probes print "NOT CLEAN: M misresolution(s), C crash(es)". Anything
# else returns $null, meaning "cannot count" -- never 0, because a
# silent 0 would read as "everything got fixed" and fail the run.
function Get-OpenFindingCount($lines) {
  $text = ($lines | ForEach-Object { $_.ToString() }) -join "`n"
  $m = [regex]::Match($text, '(\d+)\s+misresolution\(s\),\s*(\d+)\s+crash\(es\)')
  if ($m.Success) { return [int]$m.Groups[1].Value + [int]$m.Groups[2].Value }
  $m = [regex]::Match($text, 'live-failures=(\d+).*?gaps=(\d+)')
  if ($m.Success) { return [int]$m.Groups[1].Value + [int]$m.Groups[2].Value }
  return $null
}

# ---------------------------------------------------------------------
# Preflight: the migration files and the stamps agree
# ---------------------------------------------------------------------
# qa_migrations.sql checks everything about the bookkeeping that can be
# seen from INSIDE a database. It cannot see db/migrations/, because SQL
# cannot read a directory -- so the one comparison that matters most is
# made here instead.
#
# The failure this prevents: somebody adds a migration file and forgets
# to fold its effect into the schema files (so a fresh build lacks the
# change), or folds a change into the schema files and forgets the
# migration (so an existing database never gets it). Either way the two
# ways of building this database stop agreeing, and the first anyone
# hears of it is a deploy that behaves differently from every test.
#
# Run before the suites, because a repository in that state is not worth
# testing.
$migDir = Join-Path $db 'migrations'
$appFile = Join-Path $db '00_app_schema.sql'
if ((Test-Path $migDir) -and (Test-Path $appFile)) {
  $files = @(Get-ChildItem -Path $migDir -Filter '*.sql' | ForEach-Object { $_.BaseName } | Sort-Object)
  $appText = [System.IO.File]::ReadAllText($appFile)
  $stamps = @([regex]::Matches($appText, "\('([0-9]{4}_[a-z0-9_]+)'\s*,\s*NULL\)") |
              ForEach-Object { $_.Groups[1].Value } | Sort-Object)

  $missingStamp = @($files | Where-Object { $stamps -notcontains $_ })
  $missingFile  = @($stamps | Where-Object { $files  -notcontains $_ })

  if ($missingStamp.Count -gt 0 -or $missingFile.Count -gt 0) {
    Write-Host ""
    Write-Host "=============== MIGRARI: LISTELE NU SE POTRIVESC ===============" -ForegroundColor Red
    if ($missingStamp.Count -gt 0) {
      Write-Host "  Fisier de migrare fara stampila in 00_app_schema.sql:" -ForegroundColor Red
      $missingStamp | ForEach-Object { Write-Host "    $_" }
      Write-Host "  O baza construita de la zero NU va avea aceasta schimbare."
    }
    if ($missingFile.Count -gt 0) {
      Write-Host "  Stampila fara fisier de migrare:" -ForegroundColor Red
      $missingFile | ForEach-Object { Write-Host "    $_" }
      Write-Host "  O baza existenta NU va primi niciodata aceasta schimbare."
    }
    Write-Host ""
    exit 1
  }
  Write-Host ("migrari: {0} fisier(e), {0} stampila(e), listele se potrivesc" -f $files.Count) -ForegroundColor DarkGray
}

foreach ($s in $suites) {
  if ($Only -and $s.name -ne $Only) { continue }
  $path = Join-Path $db $s.file
  if (-not (Test-Path $path)) {
    $results += [pscustomobject]@{ Suite=$s.name; Exit="MISSING"; Verdict="file not found"; Seconds=0 }
    continue
  }

  $dbname = "qa_run_$($s.name)"
  $t0 = Get-Date
  & $PsqlPath @conn -c "DROP DATABASE IF EXISTS $dbname WITH (FORCE);" 2>&1 | Out-Null
  & $PsqlPath @conn -c "CREATE DATABASE $dbname;" 2>&1 | Out-Null

  $loadFailed = $false
  foreach ($k in $s.schemas) {
    & $PsqlPath @conn -d $dbname -q -v ON_ERROR_STOP=1 -f (Join-Path $db $schemaFiles[$k]) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $loadFailed = $true; break }
  }
  if ($loadFailed) {
    $results += [pscustomobject]@{ Suite=$s.name; Exit="LOAD"; Verdict="schema load failed"; Seconds=0 }
    continue
  }

  # A suite that opens a second backend needs a connection string the
  # SERVER can use to reach itself. It is set on the throwaway database
  # rather than written into the suite, so no credential lives in a
  # committed .sql file.
  if ($s.needsConninfo) {
    $ci = "host=$DbHost port=$Port dbname=$dbname user=$User password=$($env:PGPASSWORD)"
    & $PsqlPath @conn -d $dbname -q -c "ALTER DATABASE $dbname SET qa.conninfo = '$ci';" 2>&1 | Out-Null
  }

  $out  = & $PsqlPath @conn -d $dbname -q -f $path 2>&1
  $code = $LASTEXITCODE
  $secs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)

  # every suite prints one NOTICE summary line via qa_finish() or its own
  $verdict = ($out | Select-String -Pattern "NOTICE:\s+\[" | Select-Object -First 1)
  if (-not $verdict) { $verdict = ($out | Select-String -Pattern "READY|NOT READY" | Select-Object -First 1) }
  if (-not $verdict) { $verdict = ($out | Select-String -Pattern "ERROR:" | Select-Object -First 1) }
  $vtext = if ($verdict) { ($verdict.ToString() -replace '^.*NOTICE:\s+','' -replace '\s+',' ').Trim() } else { "(no summary line)" }

  $isKnown  = $known.ContainsKey($s.name)
  $expected = if ($isKnown) { $known[$s.name].findings } else { $null }
  $actual   = Get-OpenFindingCount $out

  $state =
    if     ($code -eq 0 -and -not $isKnown) { "OK" }
    elseif ($code -eq 0 -and $isKnown)      { "FIXED?" }   # baseline is stale
    elseif (-not $isKnown)                  { "FAIL" }
    elseif ($null -eq $expected -or $null -eq $actual) { "KNOWN" }
    elseif ($actual -lt $expected)          { "NARROWED" } # part of it closed
    elseif ($actual -gt $expected)          { "WIDENED" }  # something new hid here
    else                                    { "KNOWN" }

  $countText = if ($null -ne $actual -and $null -ne $expected) { "$actual/$expected" }
               elseif ($null -ne $actual)                      { "$actual/-" }
               else                                            { "-" }

  $results += [pscustomobject]@{ Suite=$s.name; State=$state; Exit=$code; Findings=$countText; Verdict=$vtext; Seconds=$secs }

  if ($state -eq "FAIL") {
    Write-Host "`n--- $($s.name): REGRESSION, first errors ---" -ForegroundColor Red
    $out | Select-String "ERROR:" | Select-Object -First 3 | ForEach-Object { Write-Host "    $_" }
  }
  elseif ($state -eq "KNOWN") {
    Write-Host "  $($s.name): known open finding ($countText) -> $($known[$s.name].proposal)" -ForegroundColor DarkYellow
  }
  elseif ($state -eq "NARROWED") {
    Write-Host "`n--- $($s.name): PART of the known issue is now closed ---" -ForegroundColor Yellow
    Write-Host "    baseline excuses $expected finding(s); the suite reports $actual."
    Write-Host "    Update the count AND the reason line in qa_known_issues.txt --"
    Write-Host "    the reason still names something that no longer happens, which is"
    Write-Host "    exactly how a baseline turns into a permanent excuse."
  }
  elseif ($state -eq "WIDENED") {
    Write-Host "`n--- $($s.name): the known issue GREW ---" -ForegroundColor Red
    Write-Host "    baseline excuses $expected finding(s); the suite reports $actual."
    Write-Host "    A new finding is hiding behind an existing excuse. Nothing may be"
    Write-Host "    added to the baseline to silence a new failure -- fix it, or give"
    Write-Host "    it a proposal of its own first."
    $out | Select-String "MISRESOLUTION|GAP" | Select-Object -First 3 | ForEach-Object { Write-Host "    $_" }
  }
  elseif ($state -eq "FIXED?") {
    Write-Host "`n--- $($s.name): listed as a known issue but it PASSED ---" -ForegroundColor Yellow
    Write-Host "    Remove it from qa_known_issues.txt. A baseline that keeps"
    Write-Host "    entries for fixed things is how the list stops meaning anything."
  }

  if (-not $KeepDatabases) {
    & $PsqlPath @conn -c "DROP DATABASE IF EXISTS $dbname WITH (FORCE);" 2>&1 | Out-Null
  }
}

Write-Host ""
Write-Host "==================== QA RUN ====================" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$regressions = @($results | Where-Object { $_.State -eq "FAIL" -or $_.State -eq "WIDENED" })
$stale       = @($results | Where-Object { $_.State -eq "FIXED?" -or $_.State -eq "NARROWED" })
$knownOpen   = @($results | Where-Object { $_.State -eq "KNOWN" })
$total       = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)

Write-Host ("suites: {0}   ok: {1}   known-open: {2}   regressions: {3}   stale-baseline: {4}   elapsed: {5}s" -f `
  $results.Count, @($results | Where-Object { $_.State -eq "OK" }).Count, `
  $knownOpen.Count, $regressions.Count, $stale.Count, $total)

if ($knownOpen.Count -gt 0) {
  Write-Host ""
  Write-Host "Known open findings (not regressions):" -ForegroundColor DarkYellow
  foreach ($k in $knownOpen) {
    Write-Host ("  {0,-16} {1,-6} {2}" -f $k.Suite, $k.Findings, $known[$k.Suite].reason)
  }
}

if ($regressions.Count -gt 0) {
  Write-Host ""
  Write-Host "REGRESSIONS: $(($regressions | ForEach-Object { $_.Suite }) -join ', ')" -ForegroundColor Red
  exit 1
}
if ($stale.Count -gt 0) {
  Write-Host ""
  Write-Host "STALE BASELINE: $(($stale | ForEach-Object { "$($_.Suite) ($($_.Findings))" }) -join ', ')" -ForegroundColor Yellow
  Write-Host "  A suite that passed, or that now reports fewer findings than the" -ForegroundColor Yellow
  Write-Host "  baseline excuses. Update qa_known_issues.txt -- both the count and" -ForegroundColor Yellow
  Write-Host "  the reason line, which no longer describes what the suite reports." -ForegroundColor Yellow
  exit 1
}
Write-Host ""
Write-Host "No regressions." -ForegroundColor Green
exit 0
