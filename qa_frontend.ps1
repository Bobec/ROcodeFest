# =====================================================================
# QA — the static pages
# =====================================================================
# The 29 pages had no tests of any kind. They are interactive mockups:
# every one carries inline JavaScript, every one uses localStorage, and
# NONE of them makes a network request. So there is no server to check
# against -- the contract they have to keep is with each other, through
# the keys they share in localStorage and the links they point at.
#
# That is what this file tests. It is static analysis, not a browser: it
# runs anywhere pwsh runs, needs no dependencies, and takes under a
# second. Testing the BEHAVIOUR of the page scripts would need a headless
# browser and is deliberately out of scope here -- see the note at the
# bottom.
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
$navLists = @{}
foreach ($name in $src.Keys) {
    foreach ($m in [regex]::Matches($src[$name], "\[\s*((?:'rocodefest_[a-z_]*session'\s*,?\s*)+)\]")) {
        $list = ($m.Groups[1].Value -replace "['\s]", "")
        if (-not $navLists.ContainsKey($list)) { $navLists[$list] = @() }
        $navLists[$list] += $name
    }
}
$pagesWithNav = ($src.Keys | Where-Object { $src[$_] -match 'nav-login-link' }).Count

Pre "S" "S1 the pages carry a session check at all" ($pagesWithNav -gt 0) `
    "$pagesWithNav of $($pages.Count) pages read a session list to decide the nav"

Check "S" "S1 every page agrees on which keys mean 'logged in'" `
    "one page disagreeing would show a different nav for the same visitor" `
    ($navLists.Count -eq 1) `
    $(if ($navLists.Count -eq 1) { "one list, used by $pagesWithNav pages: [" + ($navLists.Keys | Select-Object -First 1) + "]" }
      else { "$($navLists.Count) DIFFERENT lists: " + (($navLists.Keys) -join "  |  ") })

# --- every session key that exists, and what happens to it ------------
$sessionKeys = @{}
foreach ($name in $src.Keys) {
    foreach ($m in [regex]::Matches($src[$name], "localStorage\.(getItem|setItem|removeItem)\s*\(\s*['""](rocodefest_[a-z_]*session)['""]")) {
        $k = $m.Groups[2].Value
        if (-not $sessionKeys.ContainsKey($k)) { $sessionKeys[$k] = @{ get = @(); set = @(); rm = @() } }
        switch ($m.Groups[1].Value) {
            "getItem"    { $sessionKeys[$k].get += $name }
            "setItem"    { $sessionKeys[$k].set += $name }
            "removeItem" { $sessionKeys[$k].rm  += $name }
        }
    }
}
$navList = ($navLists.Keys | Select-Object -First 1)
$created = $sessionKeys.Keys | Where-Object { $sessionKeys[$_].set.Count -gt 0 }
$unseen  = $created | Where-Object { $navList -notlike "*$_*" }

Pre "S" "S2 more than one kind of session is created" ($created.Count -gt 1) `
    "$($created.Count) session keys are written somewhere: $($created -join ', ')"

if ($unseen.Count -eq 0) {
    Check "S" "S2 every session that can be created is recognised by the nav" `
        "a session the nav cannot see leaves a signed-in visitor looking signed out" $true `
        "all $($created.Count) created sessions appear in the nav list"
} else {
    Gap "S" "S2-GAP a session the nav never checks" `
        "which sessions count as being logged in?" `
        ("created but absent from the nav list: " + ($unseen -join ", ") +
         " -- the list is [$navList], used by $pagesWithNav pages") `
        ("Signing in through that route sets a key no page reads, so the visitor stays signed in as far " +
         "as the feature is concerned and signed OUT as far as every navigation bar is concerned. The " +
         "two answers come from different keys, and nothing keeps them in step.")
}

# --- can a session be ended? ------------------------------------------
$noLogout = $created | Where-Object { $sessionKeys[$_].rm.Count -eq 0 }
if ($noLogout.Count -eq 0) {
    Check "S" "S3 every session that can be created can also be ended" `
        "a session with no way out is a session that never ends" $true `
        "all $($created.Count) sessions have a removeItem somewhere"
} else {
    Gap "S" "S3-GAP a session that cannot be ended" `
        "how does this visitor sign out?" `
        ("written but never removed anywhere: " + ($noLogout -join ", ")) `
        ("No page clears it, so it survives until the browser's storage is cleared by hand. Every other " +
         "session key in the site has a page that removes it.")
}

# --- can two sessions exist at once? ----------------------------------
# Reachability matters more than possibility here: if the two sign-in
# forms live on ONE page and neither clears the other, an ordinary
# visitor can hold both without doing anything unusual.
$loginPage = $src.Keys | Where-Object { $src[$_] -match 'club-login-btn' -and $src[$_] -match 'member-login-btn' }
if ($loginPage) {
    $lp = $loginPage | Select-Object -First 1
    $clearsOther = $src[$lp] -match "removeItem\s*\(\s*['""]rocodefest_"
    Pre "S" "S4 two sign-in forms share one page" ($null -ne $lp) `
        "$lp carries both the club and the member sign-in"

    if (-not $clearsOther) {
        $logoutPages = @()
        foreach ($k in $created) { foreach ($pg in ($sessionKeys[$k].rm | Select-Object -Unique)) { $logoutPages += "$pg clears $k" } }
        Gap "S" "S4-GAP signing out of one role leaves the other signed in" `
            "what does signing out actually end?" `
            ("$lp writes a session without clearing any other, and each sign-out page clears exactly one key: " +
             ($logoutPages -join "; ")) `
            ("Signing in as a club and then as a member -- both forms are on the same page -- leaves two " +
             "session keys set. The nav reads the list as an OR, so clearing one still leaves the visitor " +
             "shown as signed in, on all $pagesWithNav pages. Nothing here is contrived: it takes two " +
             "ordinary sign-ins and one ordinary sign-out.")
    } else {
        Check "S" "S4 signing in clears any other role's session" `
            "otherwise two sessions coexist and one sign-out ends neither" $true `
            "$lp removes other session keys before writing its own"
    }
}


# =====================================================================
# K — the localStorage contract
# =====================================================================
# Pages share state only through localStorage, so a key that one page
# reads and no page writes is a feature wired to nothing. Keys built by
# concatenation are counted too: an early version of this check missed
# them and reported three false findings.
# ---------------------------------------------------------------------
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

Pre "K" "K1 the pages share state through localStorage at all" ($keys.Count -gt 5) `
    "$($keys.Count) distinct keys, and $($dynamicWrites.Count) writes with a computed key"

if ($deadReads.Count -eq 0) {
    Check "K" "K1 every key that is read is written by some page" `
        "a key nothing writes is a feature wired to nothing" $true `
        "all $($keys.Count) keys have a writer"
} else {
    Gap "K" "K1-GAP a key that is read and never written" `
        "where would this data come from?" `
        ("read but never written, by any page, literally or by prefix: " + ($deadReads -join ", ")) `
        ("The reading page falls back to its empty default forever, so the feature it drives silently " +
         "shows nothing. This is not the same as a key written by a computed name -- those were checked " +
         "separately and excluded, because an earlier version of this check reported three of them as " +
         "findings and all three were wrong.")
}


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
