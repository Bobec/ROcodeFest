# =====================================================================
# QA — the static pages
# =====================================================================
# When these checks were first written the 29 pages made no network
# request at all: they kept four session keys in localStorage, and the
# contract they had to keep was with each other. Three findings came out
# of that -- a role whose key no navigation bar read, a session nothing
# could end, and two sessions where one sign-out ended one.
#
# There is a server now, so the questions changed with it. The checks
# below no longer ask whether the pages AGREE about localStorage; they
# ask whether any of them still decides anything from it. A session the
# page can write is a session the page can forge.
#
# It is still static analysis, not a browser: it runs anywhere pwsh runs,
# needs no dependencies, and takes under a second. Testing the BEHAVIOUR
# of the page scripts would need a headless browser and is deliberately
# out of scope -- see the note at the bottom.
#
# Same vocabulary as the database suites:
#   PASS   verified
#   FAIL   verified and wrong                -> exit 1
#   GAP    a real finding, recorded not fixed -> does not fail the run
#   NOTE   context worth keeping
#
# A check that examined ZERO things is a FAIL, never a PASS. A green
# result has to mean something was looked at.
#
#   ./qa_frontend.ps1
# =====================================================================

param([switch] $Quiet)

$ErrorActionPreference = "Stop"
$root  = $PSScriptRoot
$pages = Get-ChildItem -Path $root -File -Filter *.html | Sort-Object Name
$results = @()

function Rec($grp, $tc, $status, $detail) {
    $script:results += [pscustomobject]@{ Grp=$grp; TC=$tc; Status=$status; Detail=$detail }
}
function Check($grp, $tc, $intent, $ok, $detail) {
    Rec $grp $tc $(if ($ok) { "PASS" } else { "FAIL" }) "$detail   [$intent]"
}
# A premise the findings below rest on. If it fails, they prove nothing,
# and the report says so instead of showing a passed test beside them.
function Pre($grp, $tc, $ok, $detail) {
    Rec $grp "PRE $tc" $(if ($ok) { "PASS" } else { "FAIL" }) $(if ($ok) { $detail } else { "PRECONDITION NOT MET -- $detail" })
}
function Gap($grp, $tc, $question, $evidence, $why) {
    Rec $grp $tc "GAP" "$evidence`n           $why"
}
function Note($grp, $tc, $text) { Rec $grp $tc "NOTE" $text }

# ---------------------------------------------------------------------
# Index every file in the repository once, so a link can be resolved
# without touching the disk again.
# ---------------------------------------------------------------------
$onDisk = @{}
Get-ChildItem -Path $root -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($root.Length + 1).Replace("\", "/").ToLower()
    $onDisk[$rel] = $true
}

$src = @{}
foreach ($p in $pages) { $src[$p.Name] = [System.IO.File]::ReadAllText($p.FullName) }


# =====================================================================
# L — links and assets
# =====================================================================
$broken = @(); $localRefs = 0; $totalRefs = 0
foreach ($name in $src.Keys) {
    foreach ($m in [regex]::Matches($src[$name], '(?:href|src)\s*=\s*["'']([^"'']+)["'']')) {
        $u = $m.Groups[1].Value.Trim(); $totalRefs++
        if ($u -match '^(https?:|mailto:|tel:|data:|javascript:|//|#)') { continue }
        $clean = ($u -split '[?#]')[0]
        if ($clean -eq '') { continue }
        $localRefs++
        if (-not $onDisk.ContainsKey($clean.ToLower())) { $broken += "$name -> $clean" }
    }
}

# The vacuity guard. "No broken links" is trivially true of a page with
# no links, so the count of what was actually examined is asserted first.
Pre "L" "L1 there are local references to check" ($localRefs -gt 100) `
    "$localRefs local href/src across $($pages.Count) pages (of $totalRefs total)"

Check "L" "L1 every local link and asset resolves to a file that exists" `
    "a dead link is the characteristic defect of a hand-maintained static site" `
    ($broken.Count -eq 0) `
    $(if ($broken.Count -eq 0) { "all $localRefs local references resolve" }
      else { "BROKEN: " + ($broken -join "; ") })


# =====================================================================
# S — the session contract
# =====================================================================
# Every page decides whether to show the "Login" link by reading a list
# of session keys and treating the result as an OR. That list is the
# closest thing this site has to an authentication contract, so the
# questions worth asking are: do all the pages agree on it, and does
# everything that creates a session appear in it?
# ---------------------------------------------------------------------
$pagesWithNav  = ($src.Keys | Where-Object { $src[$_] -match 'nav-login-link' }).Count
$pagesAskingApi = ($src.Keys | Where-Object { $src[$_] -match "fetch\(\s*'/auth/me'" }).Count

# The pages used to read three localStorage keys as an OR. Every finding
# in this group came from that: a fourth key nobody read, a key nothing
# cleared, and two keys where one sign-out cleared one. They now ask the
# server, which answers once and includes the role.
Pre "S" "S1 the pages carry a session check at all" ($pagesWithNav -gt 0) `
    "$pagesWithNav of $($pages.Count) pages decide whether to show the sign-in link"

Check "S" "S1 every page asks the SERVER who is signed in" `
    "one page deciding for itself would show a different nav for the same visitor" `
    ($pagesAskingApi -eq $pagesWithNav) `
    "$pagesAskingApi of $pagesWithNav pages call /auth/me"

# The check above asks whether a page calls /auth/me AT ALL, and a page
# passes it on its first call. Five pages had a SECOND call further down
# with the word "fetch" missing -- ('/auth/me', {...}).then(...) -- which
# is a comma expression yielding an object, so it parses, node --check
# accepts it, S1 passed on the good call above it, and the page threw
# "then is not a function" at runtime and rendered nothing.
#
# So every mention of the endpoint has to be a call, not just one of
# them. This is the shape of vacuity the SQL suites guard against: an
# assertion that is satisfied without the thing it names being true.
#
# The callee is any identifier, not the literal word "fetch": forum.html
# goes through a small api() wrapper of its own, and that is still a
# call. The defect this catches is a paren with NOTHING in front of it,
# which is the only thing the missing word left behind.
$mangled  = @()
$allRefs  = 0
$realCalls = 0
foreach ($p in ($src.Keys | Sort-Object)) {
    # Only QUOTED occurrences: the endpoint is named in prose in a few
    # comments, and a comment is not a broken call.
    $all  = ([regex]::Matches($src[$p], "'/auth/me'")).Count
    $real = ([regex]::Matches($src[$p], "[A-Za-z_\$][A-Za-z0-9_\$]*\(\s*'/auth/me'")).Count
    $allRefs   += $all
    $realCalls += $real
    if ($all -gt $real) { $mangled += ("{0} ({1})" -f $p, ($all - $real)) }
}
$mangledDetail = if ($mangled.Count -eq 0) { "all $realCalls references are calls" }
                 else { "not a call: " + ($mangled -join ', ') }
Check "S" "S1 every mention of /auth/me is an actual call" `
    "a call missing its callee still parses, and still passes the check above on a sibling call" `
    ($mangled.Count -eq 0) `
    $mangledDetail

# Reading a session key in the browser is now the defect, not the norm:
# there is one session, it is httpOnly, and page script cannot see it.
$stillReadingKeys = $src.Keys | Where-Object {
    $src[$_] -match "localStorage\.getItem\s*\(\s*'rocodefest_[a-z_]*session'"
} | Sort-Object
Check "S" "S1 no page decides sign-in state from localStorage" `
    "a page that still reads a session key is deciding from something the server does not control" `
    ($stillReadingKeys.Count -eq 0) `
    $(if ($stillReadingKeys.Count -eq 0) { "no page reads a session key" }
      else { "still reading: " + ($stillReadingKeys -join ", ") })

# --- sessions are the server's, not the browser's ---------------------
# Every one of these used to be a localStorage key. The findings that
# came out of that -- a role the nav could not see, a session nothing
# could end, two sessions where one sign-out ended one -- are not
# possible against a session the page cannot touch. So the question is
# no longer "do the keys agree"; it is "is there a key at all".
$writesSession = $src.Keys | Where-Object {
    $src[$_] -match "localStorage\.(setItem|removeItem)\s*\(\s*'rocodefest_[a-z_]*session'"
} | Sort-Object

Check "S" "S2 no page creates or clears a session in the browser" `
    "a session page script can write is a session page script can forge" `
    ($writesSession.Count -eq 0) `
    $(if ($writesSession.Count -eq 0) { "no page writes a session key; the cookie is httpOnly and set by the server" }
      else { "still writing: " + ($writesSession -join ", ") })

# --- signing out ------------------------------------------------------
$signOutPages = $src.Keys | Where-Object { $src[$_] -match "logout-link" } | Sort-Object
$callLogout   = @($signOutPages | Where-Object { $src[$_] -match "/auth/logout" })

Pre "S" "S3 some pages offer a way to sign out" ($signOutPages.Count -gt 0) `
    "$($signOutPages.Count) page(s) carry a sign-out control"

Check "S" "S3 every sign-out ends the session on the server" `
    "clearing something in the browser would leave the real session standing" `
    ($callLogout.Count -eq $signOutPages.Count) `
    "$($callLogout.Count) of $($signOutPages.Count) call /auth/logout"

# --- signing in -------------------------------------------------------
# This list used to name three form ids, and there are five forms that
# create an account: join.html registers a member, partner.html and
# speaker.html each register a partner. So S4 and S5 -- the checks that
# say every registration goes through the server and every one asks for
# a password -- were passing while looking at three fifths of the
# subject. Two of the pages they skipped had no password field at all
# when this work started.
#
# Found by adding a password field to speaker.html and noticing the
# count did not move. Detection is by what the page DOES now (a form
# element plus a post to /auth) rather than by a list of ids, so a sixth
# registration form is covered the day it is written.
$signInPages = $src.Keys | Where-Object {
    $src[$_] -match "login-btn|register-form|judge-form" -or
    ($src[$_] -match "<form" -and $src[$_] -match "/auth/(login|register)")
} | Sort-Object
$viaApi = @($signInPages | Where-Object { $src[$_] -match "/auth/(login|register)" })

Pre "S" "S4 the pages carry sign-in and registration forms" ($signInPages.Count -gt 0) `
    "$($signInPages.Count) page(s): $($signInPages -join ', ')"

Check "S" "S4 every sign-in and registration goes through the server" `
    "matching an email against a list in the browser is what let any registered address in" `
    ($viaApi.Count -eq $signInPages.Count) `
    "$($viaApi.Count) of $($signInPages.Count) post to /auth"

$noPassword = @($signInPages | Where-Object { $src[$_] -notmatch 'type\s*=\s*"password"' }) | Sort-Object
Check "S" "S5 every sign-in and registration form asks for a password" `
    "there was no password field anywhere on this site, while accounts.password_hash has always been NOT NULL" `
    ($noPassword.Count -eq 0) `
    $(if ($noPassword.Count -eq 0) { "all $($signInPages.Count) forms take a password" }
      else { "missing a password field: " + ($noPassword -join ", ") })

# =====================================================================
# K — the localStorage contract
# =====================================================================
# This group used to ask "do the keys the pages share agree with each
# other", and its precondition was "there are more than five keys". Both
# have been overtaken: pages do not share state through localStorage any
# more. Teams, clubs, join requests, memberships, submissions, appeals
# and scores are rows, and the browser reads them from the server.
#
# So the question is now the opposite one -- what is LEFT -- and there is
# exactly one answer that is allowed. The dead-read check below is kept
# because it is still the right check for whatever remains, and because
# it caught two real keys during this migration.
#
# Keys built by concatenation are counted too: an early version of this
# missed them and reported three false findings.
# ---------------------------------------------------------------------

# The one key that stays in the browser, and why.
#
# rocodefest_rules_seen records whether this visitor has seen the
# current regulations, which drives a dot on the nav. It is a per-browser
# preference, not festival data: it is worth nothing to anyone else, it
# should not follow an account onto a shared computer, and the rules are
# public -- so signed-out visitors need the badge too, and they have no
# account to hang it on.
$ALLOWED_KEYS = @('rocodefest_rules_seen')
$keys = @{}
foreach ($name in $src.Keys) {
    foreach ($m in [regex]::Matches($src[$name], "localStorage\.(getItem|setItem|removeItem)\s*\(\s*['""](rocodefest_[a-z_]*)['""]")) {
        $k = $m.Groups[2].Value
        if (-not $keys.ContainsKey($k)) { $keys[$k] = @{ get = 0; set = 0 } }
        if ($m.Groups[1].Value -eq "getItem") { $keys[$k].get++ } elseif ($m.Groups[1].Value -eq "setItem") { $keys[$k].set++ }
    }
}
# writes whose key is a variable or an expression -- the literal scan
# above cannot see these, and treating them as absent produces findings
# that are simply wrong
$dynamicWrites = @()
foreach ($name in $src.Keys) {
    foreach ($m in [regex]::Matches($src[$name], "localStorage\.setItem\s*\(\s*([^'""\s\)][^,]*),")) {
        $dynamicWrites += $m.Groups[1].Value.Trim()
    }
}
$prefixesWritten = @()
foreach ($name in $src.Keys) {
    foreach ($m in [regex]::Matches($src[$name], "['""](rocodefest_[a-z_]*)['""]\s*\+")) { $prefixesWritten += $m.Groups[1].Value }
}
$deadReads = $keys.Keys | Where-Object {
    $keys[$_].get -gt 0 -and $keys[$_].set -eq 0 -and $prefixesWritten -notcontains $_
} | Sort-Object

Pre "K" "K1 there is any localStorage use left to check" ($keys.Count -gt 0) `
    "$($keys.Count) distinct key(s), and $($dynamicWrites.Count) write(s) with a computed key"

if ($deadReads.Count -eq 0) {
    Check "K" "K1 every key that is read is written by some page" `
        "a key nothing writes is a feature wired to nothing" $true `
        "all $($keys.Count) key(s) have a writer"
} else {
    Gap "K" "K1-GAP a key that is read and never written" `
        "where would this data come from?" `
        ("read but never written, by any page, literally or by prefix: " + ($deadReads -join ", ")) `
        ("The reading page falls back to its empty default forever, so the feature it drives silently " +
         "shows nothing. This is not the same as a key written by a computed name -- those were checked " +
         "separately and excluded, because an earlier version of this check reported three of them as " +
         "findings and all three were wrong.")
}

# --- K2: nothing but the documented exception lives in the browser ----
# The point of the migration, stated as a check rather than left to a
# commit message. A new key added by a later page is a page deciding to
# keep festival data where only one browser can see it -- which is what
# every finding in this group came from: a club that could not see its
# members' submissions, a judge whose scores nobody could read, a join
# request no club ever received.
$unexpected = @($keys.Keys | Where-Object { $ALLOWED_KEYS -notcontains $_ }) | Sort-Object
$prefixLeft = @($prefixesWritten + @()) | Where-Object { $ALLOWED_KEYS -notcontains $_ } | Sort-Object -Unique

Check "K" "K2 only the documented exception is kept in the browser" `
    "festival data in localStorage is data only one browser can see, which is where this group's findings all came from" `
    ($unexpected.Count -eq 0 -and $prefixLeft.Count -eq 0) `
    $(if ($unexpected.Count -eq 0 -and $prefixLeft.Count -eq 0) {
        "only " + ($ALLOWED_KEYS -join ", ") + " -- a per-browser preference, and the rules are public so signed-out visitors need it too"
      } else {
        "not on the allowed list: " + (($unexpected + $prefixLeft) -join ", ")
      })


# =====================================================================
# J — the inline scripts actually parse
# =====================================================================
# Every page carries its logic in inline <script> blocks, and a block
# that does not parse does not run: the browser reports it to a console
# nobody has open and renders the page as though the script were absent.
# Nothing else in this file would notice, because every other check
# reads the source as TEXT -- a page can satisfy all of them while being
# completely inert.
#
# This lived in a scratchpad script for a while and reported "syntax OK"
# on every run. It took a parameter listing the files to check, it was
# always invoked with none, and an empty list means an empty loop means
# no failures -- so it passed 29 pages by checking zero of them. That is
# the vacuity trap the SQL suites are built around, in the tool meant to
# catch it, which is why it now lives here behind a precondition that
# counts what it looked at.
#
# It found 13 broken pages the first time it ran for real: a scripted
# removal of the "Reset demo data" block stopped at the first line that
# was only a closing brace, leaving two orphaned ones behind.
$scriptBlocks = 0
$unparseable  = @()
# GetTempPath, not $env:TEMP: TEMP is a Windows variable. On the Linux CI
# runner it is unset, Join-Path refuses a null path, and with
# ErrorActionPreference=Stop that ended the whole script -- every run of
# this job failed from the day J1 was added, while it passed locally.
$tmpJs = Join-Path ([System.IO.Path]::GetTempPath()) "rocodefest_qa_block.js"

foreach ($name in ($src.Keys | Sort-Object)) {
    # Inline blocks only -- a <script src=...> has no body to parse here.
    $blocks = [regex]::Matches($src[$name], '(?s)<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>')
    for ($i = 0; $i -lt $blocks.Count; $i++) {
        $scriptBlocks++
        [System.IO.File]::WriteAllText($tmpJs, $blocks[$i].Groups[1].Value, (New-Object System.Text.UTF8Encoding $false))
        & node --check $tmpJs 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $unparseable += ("{0} (blocul {1})" -f $name, ($i + 1)) }
    }
}
if (Test-Path $tmpJs) { Remove-Item $tmpJs -Force }

Pre "J" "J1 there are inline scripts to parse" ($scriptBlocks -gt 0) `
    "$scriptBlocks inline script block(s) across $($pages.Count) pages"

Check "J" "J1 every inline script parses" `
    "a block that does not parse does not run, and every other check here reads the source as text" `
    ($unparseable.Count -eq 0) `
    $(if ($unparseable.Count -eq 0) { "all $scriptBlocks blocks parse" }
      else { "nu se parseaza: " + ($unparseable -join ", ") })

# =====================================================================
# P — page structure
# =====================================================================
$noTitle    = $src.Keys | Where-Object { $src[$_] -notmatch '<title[^>]*>\s*\S' }
$noCharset  = $src.Keys | Where-Object { $src[$_] -notmatch '<meta[^>]+charset' }
$noViewport = $src.Keys | Where-Object { $src[$_] -notmatch '<meta[^>]+name\s*=\s*["'']viewport' }
$noLang     = $src.Keys | Where-Object { $src[$_] -notmatch '<html[^>]+lang\s*=' }

Check "P" "P1 every page has a non-empty title" `
    "the title is the tab, the bookmark and the search result" `
    ($noTitle.Count -eq 0) $(if ($noTitle.Count -eq 0) { "$($pages.Count) pages titled" } else { "missing: " + ($noTitle -join ", ") })

Check "P" "P2 every page declares a charset" `
    "Romanian diacritics render as mojibake without it" `
    ($noCharset.Count -eq 0) $(if ($noCharset.Count -eq 0) { "$($pages.Count) pages declare one" } else { "missing: " + ($noCharset -join ", ") })

Check "P" "P3 every page declares a viewport" `
    "without it a phone renders the desktop layout scaled down" `
    ($noViewport.Count -eq 0) $(if ($noViewport.Count -eq 0) { "$($pages.Count) pages declare one" } else { "missing: " + ($noViewport -join ", ") })

Check "P" "P4 every page declares a document language" `
    "screen readers and translation both key off it" `
    ($noLang.Count -eq 0) $(if ($noLang.Count -eq 0) { "$($pages.Count) pages declare one" } else { "missing: " + ($noLang -join ", ") })

Note "P" "P5-NOTE what this file does not test" `
    ("Every page carries inline JavaScript with event handlers and localStorage, and none of it is " +
     "executed here -- these are static checks over the source text. Testing the behaviour needs a " +
     "headless browser, which is a dependency and a decision, not an oversight. What is checked here is " +
     "the contract the pages keep with EACH OTHER: the links between them, the session keys they agree " +
     "on, and the storage keys they share.")


# =====================================================================
# Report
# =====================================================================
$pass = @($results | Where-Object { $_.Status -eq "PASS" }).Count
$fail = @($results | Where-Object { $_.Status -eq "FAIL" }).Count
$gap  = @($results | Where-Object { $_.Status -eq "GAP"  }).Count
$note = @($results | Where-Object { $_.Status -eq "NOTE" }).Count

if (-not $Quiet) {
    Write-Host ""
    Write-Host "===================== FRONTEND QA =====================" -ForegroundColor Cyan
    foreach ($r in $results) {
        $c = switch ($r.Status) { "PASS" { "Green" } "FAIL" { "Red" } "GAP" { "Yellow" } default { "DarkGray" } }
        Write-Host ("  {0,-5} {1,-3} {2}" -f $r.Status, $r.Grp, $r.TC) -ForegroundColor $c
        Write-Host ("           {0}" -f $r.Detail) -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host ("[frontend] pages=$($pages.Count) pass=$pass failures=$fail gaps=$gap notes=$note") -ForegroundColor Cyan
    Write-Host ""
}

if ($fail -gt 0) {
    Write-Host "FRONTEND QA: $fail failure(s)" -ForegroundColor Red
    exit 1
}
Write-Host "FRONTEND QA: no failures ($gap finding(s) recorded)" -ForegroundColor Green
exit 0
