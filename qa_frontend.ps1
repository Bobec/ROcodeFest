# =====================================================================
# QA — the site's pages
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
# The pages are a Next.js app now (src/app/**/page.tsx). A page is its
# page.tsx plus the PageScript.jsx beside it, if it has one; what every
# page shares -- the navigation bar, the sign-in check -- lives once in
# src/components and src/lib and is checked there.
#
# It is still static analysis, not a browser: it runs anywhere pwsh and
# node run, installs nothing, and takes a few seconds. Whether the pages
# compile is `npm run build`'s job (its own CI job); this file checks the
# contracts the compiler cannot see.
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
$root    = $PSScriptRoot
$appDir  = Join-Path $root "src/app"
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

function Rel($full) { $full.Substring($root.Length + 1).Replace("\", "/") }

# ---------------------------------------------------------------------
# The pages, and the route each one answers on. Route groups -- folder
# names in parentheses -- are not part of the URL.
# ---------------------------------------------------------------------
$pageFiles = @(Get-ChildItem -Path $appDir -Recurse -File -Filter page.tsx | Sort-Object FullName)
$routes = @{}      # "/forum" -> "src/app/(site)/forum/page.tsx"
$src    = @{}      # route    -> page.tsx + PageScript.jsx, as one text
foreach ($f in $pageFiles) {
    $parts = (Rel $f.DirectoryName).Substring("src/app".Length).Split("/") |
             Where-Object { $_ -ne "" -and $_ -notmatch '^\(.*\)$' }
    $route = "/" + ($parts -join "/")
    $routes[$route] = Rel $f.FullName
    $text = [System.IO.File]::ReadAllText($f.FullName)
    $script = Join-Path $f.DirectoryName "PageScript.jsx"
    if (Test-Path $script) { $text += "`n" + [System.IO.File]::ReadAllText($script) }
    $src[$route] = $text
}

# Everything under src/, for the checks that are about the site as a
# whole rather than one page (the session endpoint, localStorage keys).
$allSrc = @{}
Get-ChildItem -Path (Join-Path $root "src") -Recurse -File -Include *.ts, *.tsx, *.js, *.jsx | ForEach-Object {
    $allSrc[(Rel $_.FullName)] = [System.IO.File]::ReadAllText($_.FullName)
}

# Index every file under public/ once, so an asset link can be resolved
# without touching the disk again.
$public = @{}
$publicDir = Join-Path $root "public"
if (Test-Path $publicDir) {
    Get-ChildItem -Path $publicDir -Recurse -File | ForEach-Object {
        $public["/" + $_.FullName.Substring($publicDir.Length + 1).Replace("\", "/").ToLower()] = $true
    }
}

Pre "-" "there are pages to check" ($pageFiles.Count -gt 20) `
    "$($pageFiles.Count) pages under src/app"


# =====================================================================
# L — links and assets
# =====================================================================
# A link resolves if it names a route (a page.tsx exists for it) or a
# file under public/. Links are written as JSX attributes (href="/x"),
# and PageScript files build some of them in strings ('/team?id=' + id),
# so both are read.
$broken = @(); $localRefs = 0; $totalRefs = 0; $stale = @()
foreach ($file in ($allSrc.Keys | Sort-Object)) {
    $text = $allSrc[$file]
    $refs = @()
    foreach ($m in [regex]::Matches($text, '(?:href|src|action)\s*=\s*["'']([^"'']+)["'']')) { $refs += $m.Groups[1].Value }
    foreach ($m in [regex]::Matches($text, '(?:\.href|\bdestination|\bhref:)\s*=?\s*[''"](/[^''"]*)[''"]')) { $refs += $m.Groups[1].Value }
    foreach ($m in [regex]::Matches($text, '\[\s*"(/[a-z-]*)"\s*,')) { $refs += $m.Groups[1].Value }   # SiteFooter's link table
    foreach ($u0 in $refs) {
        $u = $u0.Trim(); $totalRefs++
        if ($u -match '^(https?:|mailto:|tel:|data:|javascript:|//|#)') { continue }
        $clean = ($u -split '[?#]')[0]
        if ($clean -eq '') { continue }
        $localRefs++
        if ($clean -match '\.html$') { $stale += "$file -> $clean"; continue }
        if (-not $clean.StartsWith("/")) { $broken += "$file -> $clean (relative)"; continue }
        $path = $clean.TrimEnd("/"); if ($path -eq "") { $path = "/" }
        if (-not $routes.ContainsKey($path) -and -not $public.ContainsKey($clean.ToLower())) { $broken += "$file -> $clean" }
    }
}

# The vacuity guard. "No broken links" is trivially true of a site with
# no links, so the count of what was actually examined is asserted first.
# (The bar was 100 when each of the 29 pages carried its own copy of the
# navigation and footer links; those are written once now, and the site
# has a little under a hundred distinct local references.)
Pre "L" "L1 there are local references to check" ($localRefs -gt 60) `
    "$localRefs local links and assets across $($allSrc.Count) source files (of $totalRefs total)"

Check "L" "L1 every local link and asset resolves to a page or a public file" `
    "a dead link is the characteristic defect of a hand-maintained site" `
    ($broken.Count -eq 0) `
    $(if ($broken.Count -eq 0) { "all $localRefs local references resolve" }
      else { "BROKEN: " + ($broken -join "; ") })

# The pages used to link to each other as x.html. next.config.ts
# redirects those for anyone holding an old link, but a page still
# linking that way costs every visitor a redirect.
Check "L" "L2 no page links to an old .html address" `
    "the .html pages are gone; the redirect is for old bookmarks, not for our own links" `
    ($stale.Count -eq 0) `
    $(if ($stale.Count -eq 0) { "no link ends in .html" } else { "still .html: " + ($stale -join "; ") })


# =====================================================================
# S — the session contract
# =====================================================================
# The navigation bar decides whether to show the sign-in link, and it is
# ONE component now (SiteHeader), asking ONE hook (useAccount) that calls
# the server. Thirty copies of that code were how the findings in this
# group happened: a fourth key nobody read, a key nothing cleared, and
# two keys where one sign-out cleared one.
# ---------------------------------------------------------------------
$header   = $allSrc["src/components/SiteHeader.tsx"]
$account  = $allSrc["src/lib/useAccount.ts"]
$withNav  = @($src.Keys | Where-Object { $src[$_] -match '<SiteHeader\b' })

Pre "S" "S1 the pages carry the navigation bar" ($withNav.Count -gt 0) `
    "$($withNav.Count) of $($src.Count) pages render SiteHeader"

Check "S" "S1 every page uses the one shared navigation bar" `
    "a page with a navigation bar of its own would decide sign-in state by its own rules" `
    ($withNav.Count -eq $src.Count) `
    "$($withNav.Count) of $($src.Count) pages render SiteHeader"

Check "S" "S1 the navigation bar asks the SERVER who is signed in" `
    "one page deciding for itself would show a different nav for the same visitor" `
    ($null -ne $header -and $header -match 'useAccount\(' -and $null -ne $account -and $account -match 'fetch\(\s*"/auth/me"') `
    "SiteHeader -> useAccount() -> fetch('/auth/me')"

# Every mention of the endpoint has to be a call, not just one of them.
# Five pages once had a SECOND call with the word "fetch" missing --
# ('/auth/me', {...}).then(...) -- which is a comma expression yielding an
# object: it parses, it passed the check above on a sibling call, and the
# page threw "then is not a function" at runtime and rendered nothing.
#
# The callee is any identifier, not the literal word "fetch": some pages
# go through a small api() wrapper of their own, and that is still a
# call. The defect this catches is a paren with NOTHING in front of it.
$mangled = @(); $allRefs = 0; $realCalls = 0
foreach ($p in ($allSrc.Keys | Sort-Object)) {
    # Only QUOTED occurrences: the endpoint is named in prose in comments.
    $all  = ([regex]::Matches($allSrc[$p], "['""]/auth/me['""]")).Count
    $real = ([regex]::Matches($allSrc[$p], "[A-Za-z_\$][A-Za-z0-9_\$]*\(\s*['""]/auth/me['""]")).Count
    $allRefs += $all; $realCalls += $real
    if ($all -gt $real) { $mangled += ("{0} ({1})" -f $p, ($all - $real)) }
}
Pre "S" "S1 there are calls to /auth/me to examine" ($allRefs -gt 0) "$allRefs quoted reference(s)"
Check "S" "S1 every mention of /auth/me is an actual call" `
    "a call missing its callee still parses, and still passes the check above on a sibling call" `
    ($mangled.Count -eq 0) `
    $(if ($mangled.Count -eq 0) { "all $realCalls references are calls" } else { "not a call: " + ($mangled -join ', ') })

# Reading a session key in the browser is the defect, not the norm: there
# is one session, it is httpOnly, and page script cannot see it.
$stillReadingKeys = @($allSrc.Keys | Where-Object {
    $allSrc[$_] -match "localStorage\.getItem\s*\(\s*['""]rocodefest_[a-z_]*session['""]"
} | Sort-Object)
Check "S" "S1 nothing decides sign-in state from localStorage" `
    "code that still reads a session key is deciding from something the server does not control" `
    ($stillReadingKeys.Count -eq 0) `
    $(if ($stillReadingKeys.Count -eq 0) { "no file reads a session key" } else { "still reading: " + ($stillReadingKeys -join ", ") })

# --- sessions are the server's, not the browser's ---------------------
$writesSession = @($allSrc.Keys | Where-Object {
    $allSrc[$_] -match "localStorage\.(setItem|removeItem)\s*\(\s*['""]rocodefest_[a-z_]*session['""]"
} | Sort-Object)
Check "S" "S2 nothing creates or clears a session in the browser" `
    "a session page script can write is a session page script can forge" `
    ($writesSession.Count -eq 0) `
    $(if ($writesSession.Count -eq 0) { "no file writes a session key; the cookie is httpOnly and set by the server" }
      else { "still writing: " + ($writesSession -join ", ") })

# --- signing out ------------------------------------------------------
$signOutPages = @($src.Keys | Where-Object { $src[$_] -match "logout-link" } | Sort-Object)
$callLogout   = @($signOutPages | Where-Object { $src[$_] -match "/auth/logout" })

Pre "S" "S3 some pages offer a way to sign out" ($signOutPages.Count -gt 0) `
    "$($signOutPages.Count) page(s) carry a sign-out control"

Check "S" "S3 every sign-out ends the session on the server" `
    "clearing something in the browser would leave the real session standing" `
    ($callLogout.Count -eq $signOutPages.Count) `
    "$($callLogout.Count) of $($signOutPages.Count) call /auth/logout"

# --- signing in -------------------------------------------------------
# Detection is by what the page DOES (a form plus a post to /auth) rather
# than by a list of ids: a list of three ids once had S4 and S5 passing
# while looking at three of the five forms that create an account.
$signInPages = @($src.Keys | Where-Object {
    $src[$_] -match "login-btn|register-form|judge-form" -or
    ($src[$_] -match "<form" -and $src[$_] -match "/auth/(login|register)")
} | Sort-Object)
$viaApi = @($signInPages | Where-Object { $src[$_] -match "/auth/(login|register)" })

Pre "S" "S4 the pages carry sign-in and registration forms" ($signInPages.Count -gt 0) `
    "$($signInPages.Count) page(s): $($signInPages -join ', ')"

Check "S" "S4 every sign-in and registration goes through the server" `
    "matching an email against a list in the browser is what let any registered address in" `
    ($viaApi.Count -eq $signInPages.Count) `
    "$($viaApi.Count) of $($signInPages.Count) post to /auth"

$noPassword = @($signInPages | Where-Object { $src[$_] -notmatch 'type\s*=\s*"password"' } | Sort-Object)
Check "S" "S5 every sign-in and registration form asks for a password" `
    "there was no password field anywhere on this site, while accounts.password_hash has always been NOT NULL" `
    ($noPassword.Count -eq 0) `
    $(if ($noPassword.Count -eq 0) { "all $($signInPages.Count) forms take a password" }
      else { "missing a password field: " + ($noPassword -join ", ") })


# =====================================================================
# K — the localStorage contract
# =====================================================================
# Teams, clubs, join requests, memberships, submissions, appeals and
# scores are rows, and the browser reads them from the server. So the
# question is what is LEFT in localStorage -- and exactly one answer is
# allowed.
#
# Keys are found written literally, through a named constant
# (const KEY = "rocodefest_..."), or built by concatenation: an early
# version of this check missed the last kind and reported three false
# findings.
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
$consts = @{}
foreach ($name in $allSrc.Keys) {
    foreach ($m in [regex]::Matches($allSrc[$name], "\bconst\s+([A-Za-z_\$][A-Za-z0-9_\$]*)\s*=\s*['""](rocodefest_[a-z_]*)['""]")) {
        $consts[$m.Groups[1].Value] = $m.Groups[2].Value
    }
}
$keys = @{}
function CountKey($k, $op) {
    if (-not $script:keys.ContainsKey($k)) { $script:keys[$k] = @{ get = 0; set = 0 } }
    if ($op -eq "getItem") { $script:keys[$k].get++ } elseif ($op -eq "setItem") { $script:keys[$k].set++ }
}
foreach ($name in $allSrc.Keys) {
    foreach ($m in [regex]::Matches($allSrc[$name], "localStorage\.(getItem|setItem|removeItem)\s*\(\s*['""](rocodefest_[a-z_]*)['""]")) {
        CountKey $m.Groups[2].Value $m.Groups[1].Value
    }
    foreach ($m in [regex]::Matches($allSrc[$name], "localStorage\.(getItem|setItem|removeItem)\s*\(\s*([A-Za-z_\$][A-Za-z0-9_\$]*)\s*[,\)]")) {
        if ($consts.ContainsKey($m.Groups[2].Value)) { CountKey $consts[$m.Groups[2].Value] $m.Groups[1].Value }
    }
}
$prefixesWritten = @()
foreach ($name in $allSrc.Keys) {
    foreach ($m in [regex]::Matches($allSrc[$name], "['""](rocodefest_[a-z_]*)['""]\s*\+")) { $prefixesWritten += $m.Groups[1].Value }
}
$deadReads = @($keys.Keys | Where-Object {
    $keys[$_].get -gt 0 -and $keys[$_].set -eq 0 -and $prefixesWritten -notcontains $_
} | Sort-Object)

Pre "K" "K1 there is any localStorage use left to check" ($keys.Count -gt 0) `
    "$($keys.Count) distinct key(s)"

if ($deadReads.Count -eq 0) {
    Check "K" "K1 every key that is read is written somewhere" `
        "a key nothing writes is a feature wired to nothing" $true `
        "all $($keys.Count) key(s) have a writer"
} else {
    Gap "K" "K1-GAP a key that is read and never written" `
        "where would this data come from?" `
        ("read but never written, literally, by constant or by prefix: " + ($deadReads -join ", ")) `
        ("The reading code falls back to its empty default forever, so the feature it drives silently shows nothing.")
}

# The point of the migration, stated as a check rather than left to a
# commit message. A new key is a page deciding to keep festival data
# where only one browser can see it.
$unexpected = @($keys.Keys | Where-Object { $ALLOWED_KEYS -notcontains $_ } | Sort-Object)
$prefixLeft = @($prefixesWritten | Where-Object { $ALLOWED_KEYS -notcontains $_ } | Sort-Object -Unique)

Check "K" "K2 only the documented exception is kept in the browser" `
    "festival data in localStorage is data only one browser can see, which is where this group's findings all came from" `
    ($unexpected.Count -eq 0 -and $prefixLeft.Count -eq 0) `
    $(if ($unexpected.Count -eq 0 -and $prefixLeft.Count -eq 0) {
        "only " + ($ALLOWED_KEYS -join ", ") + " -- a per-browser preference, and the rules are public so signed-out visitors need it too"
      } else {
        "not on the allowed list: " + (($unexpected + $prefixLeft) -join ", ")
      })


# =====================================================================
# J — the page scripts actually parse
# =====================================================================
# The behaviour the pages carried as inline <script> blocks is in a
# PageScript.jsx beside each page.tsx, waiting to be rewritten as React
# state. `next build` compiles them too, but this runs without installing
# anything, and a script that does not parse would leave its page inert
# while every text check here still passed.
#
# Behind a precondition that counts what was looked at: an earlier
# version of this check took a list of files, was always invoked with
# none, and passed 29 pages by checking zero of them.
$scripts = @(Get-ChildItem -Path $appDir -Recurse -File -Filter PageScript.jsx)
$unparseable = @()
# GetTempPath, not $env:TEMP: TEMP is unset on the Linux CI runner.
$tmpJs = Join-Path ([System.IO.Path]::GetTempPath()) "rocodefest_qa_pagescript.mjs"
foreach ($s in $scripts) {
    # The files are plain modules apart from the extension, so node can
    # check them as .mjs; a JSX tag would fail here, and none belongs in them.
    [System.IO.File]::WriteAllText($tmpJs, [System.IO.File]::ReadAllText($s.FullName), (New-Object System.Text.UTF8Encoding $false))
    # Windows PowerShell turns a native command's stderr into an error
    # record, and under "Stop" that ends the script instead of recording
    # the page -- so the exit code is read with errors relaxed.
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & node --check $tmpJs 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) { $unparseable += (Rel $s.FullName) }
}
if (Test-Path $tmpJs) { Remove-Item $tmpJs -Force }

Pre "J" "J1 there are page scripts to parse" ($scripts.Count -gt 0) `
    "$($scripts.Count) PageScript.jsx file(s)"

Check "J" "J1 every page script parses" `
    "a script that does not parse does not run, and every other check here reads the source as text" `
    ($unparseable.Count -eq 0) `
    $(if ($unparseable.Count -eq 0) { "all $($scripts.Count) parse" } else { "does not parse: " + ($unparseable -join ", ") })


# =====================================================================
# P — page structure
# =====================================================================
# Next.js writes the <head>: the charset always, the viewport and the
# title from what the layouts and pages export. So the questions are
# whether they export them.
$noTitle = @($routes.Keys | Where-Object {
    [System.IO.File]::ReadAllText((Join-Path $root $routes[$_])) -notmatch 'metadata[^=]*=\s*\{\s*title:\s*"[^"]*\S'
} | Sort-Object)
$layouts = @(Get-ChildItem -Path $appDir -Recurse -File -Filter layout.tsx)
$noViewport = @($layouts | Where-Object { [System.IO.File]::ReadAllText($_.FullName) -notmatch 'export const viewport' } | ForEach-Object { Rel $_.FullName })
$doc = $allSrc["src/components/Document.tsx"]
$layoutsUsingDoc = @($layouts | Where-Object { [System.IO.File]::ReadAllText($_.FullName) -match '<Document\b' })

Check "P" "P1 every page has a non-empty title" `
    "the title is the tab, the bookmark and the search result" `
    ($noTitle.Count -eq 0) $(if ($noTitle.Count -eq 0) { "$($routes.Count) pages titled" } else { "missing: " + ($noTitle -join ", ") })

Pre "P" "P2 there are root layouts" ($layouts.Count -gt 0) "$($layouts.Count) layout(s)"

Check "P" "P2 every layout declares a viewport" `
    "without it a phone renders the desktop layout scaled down" `
    ($noViewport.Count -eq 0) $(if ($noViewport.Count -eq 0) { "$($layouts.Count) layouts export one" } else { "missing: " + ($noViewport -join ", ") })

Check "P" "P3 every page declares a document language" `
    "screen readers and translation both key off it" `
    ($null -ne $doc -and $doc -match '<html\s+lang="ro"' -and $layoutsUsingDoc.Count -eq $layouts.Count) `
    "$($layoutsUsingDoc.Count) of $($layouts.Count) layouts render <Document>, which sets <html lang=""ro"">"

Note "P" "P4-NOTE what this file does not test" `
    ("These are static checks over the source text. Whether the pages compile is checked by 'npm run build', " +
     "and their behaviour needs a browser -- a dependency and a decision, not an oversight. What is checked " +
     "here is the contract the pages keep with each other and with the server: the links between them, " +
     "who decides sign-in, and what is still kept in the browser.")


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
    Write-Host ("[frontend] pages=$($pageFiles.Count) pass=$pass failures=$fail gaps=$gap notes=$note") -ForegroundColor Cyan
    Write-Host ""
}

if ($fail -gt 0) {
    Write-Host "FRONTEND QA: $fail failure(s)" -ForegroundColor Red
    exit 1
}
Write-Host "FRONTEND QA: no failures ($gap finding(s) recorded)" -ForegroundColor Green
exit 0
