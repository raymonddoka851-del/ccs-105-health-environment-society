# ============================================================================
#  _check.ps1 - audits every generated .html file in docs/.
#
#  It is deliberately independent of the build script: it reads the OUTPUT
#  the way a browser would, and it re-counts the list markers in the SOURCE
#  Markdown so the two can be compared.
#
#  Usage:
#      powershell -ExecutionPolicy Bypass -File ".\docs\_check.ps1"
#      powershell -ExecutionPolicy Bypass -File ".\docs\_check.ps1" -Quiet
#
#  Exit code is 0 when every check passes, 1 otherwise.
# ============================================================================

[CmdletBinding()]
param(
    [switch]$Quiet,
    [string]$DocsRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $DocsRoot) { $DocsRoot = $PSScriptRoot }
$DocsRoot = (Resolve-Path -LiteralPath $DocsRoot).Path
$PackRoot = Split-Path -Parent $DocsRoot

function Read-Utf8([string]$path) {
    return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}

# Text the reader actually sees: drop script/style, code blocks and tags.
function Get-VisibleText([string]$html) {
    $s = $html
    $s = [regex]::Replace($s, '(?is)<script\b.*?</script>', ' ')
    $s = [regex]::Replace($s, '(?is)<style\b.*?</style>', ' ')
    $s = [regex]::Replace($s, '(?is)<pre\b.*?</pre>', ' ')
    $s = [regex]::Replace($s, '(?is)<code\b.*?</code>', ' ')
    $s = [regex]::Replace($s, '(?s)<[^>]+>', ' ')
    $s = [System.Net.WebUtility]::HtmlDecode($s)
    return $s
}

# Visible text with every <a>...</a> removed, for the bare-URL check.
function Get-TextWithoutLinks([string]$html) {
    $s = [regex]::Replace($html, '(?is)<script\b.*?</script>', ' ')
    $s = [regex]::Replace($s, '(?is)<style\b.*?</style>', ' ')
    $s = [regex]::Replace($s, '(?is)<a\b[^>]*>.*?</a>', ' ')
    $s = [regex]::Replace($s, '(?is)<pre\b.*?</pre>', ' ')
    $s = [regex]::Replace($s, '(?is)<code\b.*?</code>', ' ')
    $s = [regex]::Replace($s, '(?s)<[^>]+>', ' ')
    $s = [System.Net.WebUtility]::HtmlDecode($s)
    return $s
}

# How many list markers the source Markdown has (fenced code and blockquotes
# excluded, because the converter renders those differently).
function Count-MarkdownItems([string]$md) {
    $count = 0
    $inFence = $false
    foreach ($line in ($md -split "\r?\n")) {
        if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        if ($line -match '^\s*>') { continue }
        if ($line -match '^(\s*)([-*+]|\d{1,3}[.)])\s+') { $count++ }
    }
    return $count
}

# Map an .md path from the Docs table to its generated .html path.
function Get-HtmlForMd([string]$md) {
    $guess = Join-Path $DocsRoot ($md -replace '\.md$', '.html')
    if (Test-Path -LiteralPath $guess) { return $guess }
    $leaf = Split-Path -Leaf $md
    $found = Get-ChildItem -LiteralPath $DocsRoot -Recurse -Filter ($leaf -replace '\.md$', '.html') -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

# How many list markers the source Markdown has, for the source-vs-output
# comparison. This mirrors the builder's ::: block semantics exactly:
#   - :::flipcards / :::mcq / :::steps  -> items become buttons/divs, skipped
#   - :::mistakes                        -> items go through ConvertMarkdown,
#                                           so they DO become <li> and count
#   - :::trace / :::tf / :::progress     -> single-line blocks, no content
function Count-MarkdownItemsFixed([string]$md) {
    $count = 0
    $inFence = $false
    $mode = 'normal'   # normal | skip | mistakes
    foreach ($line in ($md -split "\r?\n")) {
        if ($line -match '^\s*```') {
            if ($mode -ne 'skip') { $inFence = -not $inFence }
            continue
        }
        if ($inFence) { continue }
        if ($line -match '^:::\s*$') {
            if ($mode -ne 'normal') { $mode = 'normal' }
            continue
        }
        if ($mode -eq 'normal') {
            if ($line -match '^:::(flipcards|mcq|steps)\b') { $mode = 'skip'; continue }
            if ($line -match '^:::mistakes\b')              { $mode = 'mistakes'; continue }
            if ($line -match '^:::') { continue }
            if ($line -match '^\s*>') { continue }
            if ($line -match '^(\s*)([-*+]|\d{1,3}[.)])\s+') { $count++ }
        } elseif ($mode -eq 'mistakes') {
            if ($line -match '^(\s*)([-*+]|\d{1,3}[.)])\s+') { $count++ }
        }
    }
    return $count
}

$results = New-Object 'System.Collections.Generic.List[object]'
function Add-Issue([string]$Type, [string]$Page, [string]$Detail) {
    $results.Add([pscustomobject]@{ Type = $Type; Page = $Page; Detail = $Detail })
}

$pages = Get-ChildItem -LiteralPath $DocsRoot -Recurse -Filter *.html |
         Sort-Object FullName

if (-not $Quiet) {
    Write-Host ''
    Write-Host "Auditing $($pages.Count) generated pages in $DocsRoot" -ForegroundColor Cyan
    Write-Host ''
}

$listRows = New-Object 'System.Collections.Generic.List[object]'

foreach ($page in $pages) {
    $rel  = $page.FullName.Substring($DocsRoot.Length).TrimStart('\', '/') -replace '\\', '/'
    $html = Read-Utf8 $page.FullName
    $text = Get-VisibleText $html

    # (a) empty or near-empty list items -----------------------------------
    # A short answer wrapped in <strong>/<code>, or a fill-in <input>, is
    # deliberate content. Only flag items with no visible text AND no
    # meaningful child element (those are the ones the parser dropped).
    foreach ($m in [regex]::Matches($html, '(?is)<li\b[^>]*>(.*?)</li>')) {
        $inner  = $m.Groups[1].Value
        $liText = [System.Net.WebUtility]::HtmlDecode(
                    [regex]::Replace($inner, '(?s)<[^>]+>', ' ')).Trim()
        $liText = [regex]::Replace($liText, '\s+', ' ')
        $hasChild = $inner -match '(?i)<(input|img|svg|video|audio|details|a|code|strong|em|button|br)\b'
        if ($liText.Length -lt 3 -and -not $hasChild) {
            Add-Issue 'empty-li' $rel ("<li> with " + $liText.Length + " chars: '" + $liText + "'")
        }
    }

    # (b) empty lists -------------------------------------------------------
    foreach ($m in [regex]::Matches($html, '(?is)<(ol|ul)\b[^>]*>(.*?)</\1>')) {
        if (-not [regex]::IsMatch($m.Groups[2].Value, '(?i)<li\b')) {
            Add-Issue 'empty-list' $rel ("<" + $m.Groups[1].Value + "> with no <li>")
        }
    }

    # (c) leftover blanks / checkboxes in visible text ----------------------
    foreach ($m in [regex]::Matches($text, '_{4,}')) {
        Add-Issue 'leftover-blank' $rel ($m.Value.Substring(0, [Math]::Min(12, $m.Value.Length)) + '...')
    }
    if ($text -match '(?m)(^|\s)\[\s?\](\s|$)') {
        Add-Issue 'leftover-checkbox' $rel '[ ] shown as text'
    }
    if ($text -match '(?m)(^|\s)\[[xX]\](\s|$)') {
        Add-Issue 'leftover-checkbox' $rel '[x] shown as text'
    }

    # (d) raw Markdown leaking through --------------------------------------
    # Only block-level text counts: <th>#</th> is legitimate, a paragraph
    # beginning with "#" is a converter failure.
    foreach ($m in [regex]::Matches($html, '(?is)<(p|li|td|h[1-6])\b[^>]*>(.*?)</\1>')) {
        $inner = $m.Groups[2].Value
        $inner = [regex]::Replace($inner, '(?is)<(code|pre)\b.*?</\1>', ' ')
        $inner = [regex]::Replace($inner, '(?s)<[^>]+>', ' ')
        $inner = [System.Net.WebUtility]::HtmlDecode($inner)
        if ($inner -match '(?m)^\s*#{1,6}\s') {
            Add-Issue 'md-leak' $rel 'line starting with #'
        }
        if ($inner -match '\*\*') {
            Add-Issue 'md-leak' $rel 'literal **'
        }
        if ($inner -match '\|\s*:?-{3,}') {
            Add-Issue 'md-leak' $rel 'table separator row'
        }
        if ($inner -match '```') {
            Add-Issue 'md-leak' $rel 'literal code fence'
        }
    }

    # (e) links that go nowhere --------------------------------------------
    $pageDir = Split-Path -Parent $page.FullName
    foreach ($m in [regex]::Matches($html, '(?i)href\s*=\s*"([^"]*)"')) {
        $href = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value).Trim()
        if (-not $href) { continue }
        if ($href -match '^(https?:|mailto:|tel:|javascript:|data:)') { continue }

        $hashAt = $href.IndexOf('#')
        $pathPart = if ($hashAt -ge 0) { $href.Substring(0, $hashAt) } else { $href }
        $frag     = if ($hashAt -ge 0) { $href.Substring($hashAt + 1) } else { '' }
        $pathPart = [uri]::UnescapeDataString($pathPart)

        if (-not $pathPart) {
            if ($frag -and -not ($html -match ('id\s*=\s*"' + [regex]::Escape($frag) + '"'))) {
                Add-Issue 'bad-anchor' $rel ("#" + $frag + ' does not exist on this page')
            }
            continue
        }

        $target = [System.IO.Path]::GetFullPath((Join-Path $pageDir $pathPart))
        if ((Test-Path -LiteralPath $target -PathType Container)) {
            $target = Join-Path $target 'index.html'
        }
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            Add-Issue 'missing-file' $rel ("href='" + $href + "' -> no such file")
            continue
        }
        if ($frag -and $target -like '*.html') {
            $targetHtml = Read-Utf8 $target
            if (-not ($targetHtml -match ('id\s*=\s*"' + [regex]::Escape($frag) + '"'))) {
                Add-Issue 'bad-anchor' $rel ("href='" + $href + "' -> anchor missing in " + (Split-Path -Leaf $target))
            }
        }
    }

    # (f) bare URLs outside an <a> -----------------------------------------
    $noLinks = Get-TextWithoutLinks $html
    foreach ($m in [regex]::Matches($noLinks, 'https?://[^\s<>"'']+')) {
        Add-Issue 'bare-url' $rel $m.Value
    }

    # (g) leftover build placeholders ---------------------------------------
    foreach ($m in [regex]::Matches($html, '__[A-Z][A-Z0-9_]{2,}__')) {
        Add-Issue 'placeholder' $rel $m.Value
    }

    # (h) search wiring ------------------------------------------------------
    if (-not ($html -match 'assets/search-index\.js')) {
        Add-Issue 'no-search' $rel 'search-index.js not referenced'
    }
    if ($rel -eq 'index.html') {
        if (-not ($html -match 'id="q"')) {
            Add-Issue 'no-search' $rel 'homepage search box missing'
        }
    } elseif (-not ($html -match 'id="searchOverlay"')) {
        Add-Issue 'no-search' $rel 'search overlay missing'
    }
}

# ---- source vs output list counts ----------------------------------------

$docMap = New-Object 'System.Collections.Generic.List[object]'
$siteFile = Join-Path $PackRoot 'site.json'
if (Test-Path -LiteralPath $siteFile) {
    try {
        $SiteCfg = Get-Content -LiteralPath $siteFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($d in $SiteCfg.docset) {
            $docMap.Add([pscustomobject]@{
                Md   = ([string]$d.md -replace '/', '\')
                Html = ([string]$d.out -replace '/', '\')
            })
        }
    } catch {
        Add-Issue 'site-json' 'site.json' $_.Exception.Message
    }
} else {
    Add-Issue 'site-json' 'site.json' 'file missing'
}

foreach ($entry in $docMap) {
    $mdPath = Join-Path $PackRoot $entry.Md
    if (-not (Test-Path -LiteralPath $mdPath)) {
        $listRows.Add([pscustomobject]@{ Source = $entry.Md; Md = 0; Html = 0; Diff = 0; Note = 'source missing' })
        continue
    }
    $htmlPath = Join-Path $DocsRoot $entry.Html
    if (-not (Test-Path -LiteralPath $htmlPath)) {
        $listRows.Add([pscustomobject]@{ Source = $entry.Md; Md = 0; Html = 0; Diff = 0; Note = 'no html' })
        Add-Issue 'missing-page' $entry.Html 'declared in site.json but not built'
        continue
    }
    $mdCount   = Count-MarkdownItemsFixed (Read-Utf8 $mdPath)
    $htmlCount = ([regex]::Matches((Read-Utf8 $htmlPath), '(?i)<li\b')).Count
    $listRows.Add([pscustomobject]@{
        Source = $entry.Md; Md = $mdCount; Html = $htmlCount; Diff = ($htmlCount - $mdCount); Note = ''
    })
    if ($mdCount -ne $htmlCount) {
        Add-Issue 'list-count' ($entry.Md -replace '\\', '/') ("source $mdCount items, output $htmlCount <li>")
    }
}

# ---- search index ----------------------------------------------------------

$siPath = Join-Path $DocsRoot 'assets\search-index.js'
if (Test-Path -LiteralPath $siPath) {
    $si = Read-Utf8 $siPath
    if (-not $si.StartsWith('window.SEARCH_INDEX=[')) {
        Add-Issue 'search-index' 'assets/search-index.js' 'unexpected header'
    } else {
        $json = $si.Substring('window.SEARCH_INDEX='.Length).TrimEnd()
        if ($json.EndsWith(';')) { $json = $json.Substring(0, $json.Length - 1) }
        try {
            $parsed = ConvertFrom-Json -InputObject $json
            $entryCount = $parsed.Count
            if (-not $Quiet) {
                Write-Host ("Search index entries: {0}" -f $entryCount) -ForegroundColor Cyan
            }
            if ($entryCount -eq 0) {
                Add-Issue 'search-index' 'assets/search-index.js' 'no entries'
            }
        } catch {
            Add-Issue 'search-index' 'assets/search-index.js' ("unparseable JSON: " + $_.Exception.Message)
        }
    }
} else {
    Add-Issue 'search-index' 'assets/search-index.js' 'file missing'
}

# ---- source blanks (kept as inputs, never invented) -----------------------

$sourceBlanks = New-Object 'System.Collections.Generic.List[object]'
foreach ($entry in $docMap) {
    $mdPath = Join-Path $PackRoot $entry.Md
    if (-not (Test-Path -LiteralPath $mdPath)) { continue }
    $ln = 0
    foreach ($line in [System.IO.File]::ReadAllLines($mdPath, [System.Text.Encoding]::UTF8)) {
        $ln++
        if ($line -match '^\s*(?:[-*+]|\d{1,3}[.)])\s+_{3,}\s*$') {
            $sourceBlanks.Add([pscustomobject]@{ Source = $entry.Md; Line = $ln })
        }
    }
}

# ---- report ---------------------------------------------------------------

$byType = $results | Group-Object Type | Sort-Object Name
$total  = $results.Count

if (-not $Quiet) {
    foreach ($g in $byType) {
        Write-Host ("  {0,-18} {1,4}  {2}" -f $g.Name, $g.Count, ($g.Group[0].Detail -replace '\s+', ' '))
        $g.Group | Select-Object -First 4 | ForEach-Object {
            Write-Host ("      {0}  {1}" -f $_.Page, ($_.Detail -replace '\s+', ' ')) -ForegroundColor DarkGray
        }
        if ($g.Count -gt 4) {
            Write-Host ("      ... and {0} more" -f ($g.Count - 4)) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
}

$badCounts = $listRows | Where-Object { $_.Diff -ne 0 }

if (-not $Quiet) {
    if ($sourceBlanks.Count -gt 0) {
        Write-Host 'Source items that were blank in the Markdown (now real inputs):' -ForegroundColor Cyan
        foreach ($b in $sourceBlanks) {
            Write-Host ("  {0}:{1}" -f $b.Source, $b.Line) -ForegroundColor DarkGray
        }
        Write-Host ''
    }
    Write-Host 'List items, source vs output:' -ForegroundColor Cyan
    foreach ($r in $listRows) {
        $colour = if ($r.Diff -eq 0) { 'DarkGray' } else { 'Red' }
        Write-Host ("  {0,-52} md {1,4}  html {2,4}  diff {3,3}" -f $r.Source, $r.Md, $r.Html, $r.Diff) -ForegroundColor $colour
    }
    Write-Host ''
    Write-Host ("TOTAL PROBLEMS: {0}" -f $total) -ForegroundColor $(if ($total -eq 0) { 'Green' } else { 'Red' })
    foreach ($g in $byType) {
        Write-Host ("  {0,-18} {1}" -f $g.Name, $g.Count) -ForegroundColor $(if ($g.Count -eq 0) { 'Green' } else { 'Yellow' })
    }
    Write-Host ''
}

if ($total -eq 0) { exit 0 } else { exit 1 }
