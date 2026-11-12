# ============================================================================
#  build.ps1 - turns the Markdown study notes into a styled HTML site.
#
#  Usage (from the Revision Pack folder):
#      powershell -ExecutionPolicy Bypass -File ".\docs\_build.ps1"
#
#  It reads site.json (course config + page list), then ../*.md,
#  ../notes/*.md, ../practice/*.md and writes ../docs/**/*.html,
#  ../docs/index.html and ../docs/assets/search-index.js
# ============================================================================

$ErrorActionPreference = 'Stop'

$PackRoot = Split-Path -Parent $PSScriptRoot
$OutRoot  = $PSScriptRoot

# ---------------------------------------------------------------- site.json --

$siteFile = Join-Path $PackRoot 'site.json'
if (-not (Test-Path -LiteralPath $siteFile)) {
    throw "site.json not found next to the pack root: $siteFile"
}
$Site = Get-Content -LiteralPath $siteFile -Raw -Encoding UTF8 | ConvertFrom-Json
$script:Docs = @($Site.docset)

function JEsc([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        switch ([int]$ch) {
            8   { [void]$sb.Append('\b'); continue }
            9   { [void]$sb.Append('\t'); continue }
            10  { [void]$sb.Append('\n'); continue }
            12  { [void]$sb.Append('\f'); continue }
            13  { [void]$sb.Append('\r'); continue }
            34  { [void]$sb.Append('\"'); continue }
            92  { [void]$sb.Append('\\'); continue }
            default {
                if ([int]$ch -lt 32) {
                    [void]$sb.Append('\u{0:x4}' -f [int]$ch)
                } else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------- helpers ---

function HtmlEscape([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    $s = $s.Replace('&', '&amp;')
    $s = $s.Replace('<', '&lt;')
    $s = $s.Replace('>', '&gt;')
    $s = $s.Replace('"', '&quot;')
    return $s
}

function Slug([string]$s) {
    $s = $s.ToLowerInvariant()
    $s = [regex]::Replace($s, '[^a-z0-9\s\-]', '')
    $s = [regex]::Replace($s, '\s+', '-')
    $s = $s.Trim('-')
    if ($s.Length -gt 60) { $s = $s.Substring(0, 60).Trim('-') }
    if (-not $s) { $s = 'section' }
    return $s
}

# ------------------------------------------------------- links and blanks ---

$script:RepoUrl   = [string]$Site.repoUrl
$script:DocMap    = @{}     # source path (lowercase) and leaf name -> output path
$script:CurrentOut = ''
$script:TaskNo    = 0
$script:BlankNo   = 0

# Relative link from the page being built to another generated page.
function Get-RelHref([string]$targetOut) {
    $cur = $script:CurrentOut
    if (-not $cur -or -not $targetOut) { return $targetOut }
    $curDir = ''
    if ($cur.Contains('/')) { $curDir = $cur.Substring(0, $cur.LastIndexOf('/')) }
    if (-not $curDir) { return $targetOut }
    $tgtLeaf = $targetOut
    $tgtDir  = ''
    if ($targetOut.Contains('/')) {
        $tgtDir  = $targetOut.Substring(0, $targetOut.LastIndexOf('/'))
        $tgtLeaf = $targetOut.Substring($targetOut.LastIndexOf('/') + 1)
    }
    if ($tgtDir -eq $curDir) { return $tgtLeaf }
    return '../' + $targetOut
}

# Turn a Markdown reference into a working href: .md -> generated .html,
# repository files -> GitHub blob, everything else left alone.
function MapRef([string]$href) {
    if ([string]::IsNullOrEmpty($href)) { return $href }
    if ($href -match '^(https?:|mailto:|tel:|javascript:|data:|#)') { return $href }

    $hash = ''
    $path = $href
    $h = $href.IndexOf('#')
    if ($h -ge 0) { $hash = $href.Substring($h); $path = $href.Substring(0, $h) }
    if ([string]::IsNullOrEmpty($path)) { return $href }

    $p = $path -replace '\\', '/'
    while ($p.StartsWith('./')) { $p = $p.Substring(2) }
    $p = [uri]::UnescapeDataString($p)

    $out = $null
    if ($script:DocMap.ContainsKey($p.ToLowerInvariant())) {
        $out = $script:DocMap[$p.ToLowerInvariant()]
    } else {
        $leaf = $p.Substring($p.LastIndexOf('/') + 1).ToLowerInvariant()
        if ($script:DocMap.ContainsKey($leaf)) { $out = $script:DocMap[$leaf] }
    }
    if ($out) { return (Get-RelHref $out) + $hash }

    $disk = Join-Path $PackRoot $p
    if (Test-Path -LiteralPath $disk -PathType Leaf) {
        return $script:RepoUrl + ($p -replace ' ', '%20')
    }
    return $href
}

function NewBlankHtml([string]$kind, [string]$label) {
    $script:BlankNo++
    $id  = 'b' + $script:BlankNo
    $tag = 'text'
    $extra = ''
    if ($kind -eq 'date')   { $tag = 'date' }
    if ($kind -eq 'number') { $tag = 'number'; $extra = ' min="0" max="70" inputmode="numeric"' }
    if ($kind -eq 'days')   { $tag = 'text';   $extra = ' readonly' }
    if (-not $label) { $label = 'Your answer' }
    return '<input class="blank" type="' + $tag + '" id="' + $id + '" data-blank="' + $id +
           '" data-kind="' + $kind + '" aria-label="' + (HtmlEscape $label) +
           '" placeholder="' + (HtmlEscape $label) + '"' + $extra + '>'
}

# Replace runs of underscores with real inputs (used outside tables).
function ReplaceBlanks([string]$text, [string]$kind, [string]$label) {
    return [regex]::Replace($text, '_{3,}', {
        param($m)
        NewBlankHtml $kind $label
    })
}

# Inline markdown -> HTML (code spans, bold, italic, links)
function Inline([string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return '' }

    $esc = HtmlEscape $text

    # 1. protect `code spans` with control-character tokens
    $codes = New-Object 'System.Collections.Generic.List[string]'
    $sb = New-Object System.Text.StringBuilder
    $pos = 0
    foreach ($m in [regex]::Matches($esc, '`([^`]+)`')) {
        [void]$sb.Append($esc.Substring($pos, $m.Index - $pos))
        $codes.Add($m.Groups[1].Value)
        [void]$sb.Append([string][char]1 + ($codes.Count - 1) + [string][char]2)
        $pos = $m.Index + $m.Length
    }
    [void]$sb.Append($esc.Substring($pos))
    $t = $sb.ToString()

    # 2. bold, then italic, then links
    $t = [regex]::Replace($t, '\*\*([^*]+?)\*\*', '<strong>$1</strong>')
    $t = [regex]::Replace($t, '(?<![\w*])\*(?!\s)([^*\n]{1,160}?)(?<!\s)\*(?![\w*])', '<em>$1</em>')
    $t = [regex]::Replace($t, '\[([^\]]+)\]\(([^)\s]+)\)', {
        param($m)
        $label = $m.Groups[1].Value
        $raw   = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value)
        $href  = MapRef $raw
        '<a href="' + (HtmlEscape $href) + '">' + $label + '</a>'
    })

    # 2b. underscores in running text become real inputs
    $t = ReplaceBlanks $t 'text' 'Your answer'

    # 3. restore code spans (file names inside `code` become links)
    for ($i = $codes.Count - 1; $i -ge 0; $i--) {
        $tok = [string][char]1 + $i + [string][char]2
        $disp = $codes[$i]
        $raw  = [System.Net.WebUtility]::HtmlDecode($disp)
        $link = $raw
        if ($raw -match '\.(md|bat|cmd|c|h|ps1|html|txt)$' -or $raw -match '^(code|notes|practice)/') {
            $link = MapRef $raw
        }
        if ($link -ne $raw) {
            $t = $t.Replace($tok, '<a class="file-ref" href="' + (HtmlEscape $link) + '"><code>' + $disp + '</code></a>')
        } else {
            $t = $t.Replace($tok, '<code>' + $disp + '</code>')
        }
    }

    # 4. bare URLs -> links (Markdown angle links <https://...> lose the brackets)
    $t = [regex]::Replace($t, '&lt;(https?://[^\s&]+)&gt;', '$1')
    $t = [regex]::Replace($t, "(?<![=<>\`"'])(https?://[^\s<>\`"']+)", {
        param($m)
        $u = $m.Value
        $tail = ''
        while ($u -match '^(.*?)([.,;:)]+)$') {
            $tail = $Matches[2] + $tail
            $u = $Matches[1]
        }
        '<a href="' + $u + '">' + $u + '</a>' + $tail
    })

    # 5. external links open in a new tab (including file links to GitHub)
    $t = [regex]::Replace($t, '(<a\b[^>]*?href="(https?://[^"]+)")(?![^>]*\btarget=)',
             '$1 target="_blank" rel="noopener noreferrer"')
    return $t
}

# ------------------------------------------------------- C syntax colours ---

$script:CKeywords = @(
    'auto','break','case','char','const','continue','default','do','double',
    'else','enum','extern','float','for','goto','if','inline','int','long',
    'register','restrict','return','short','signed','sizeof','static','struct',
    'switch','typedef','union','unsigned','void','volatile','while',
    'bool','true','false','NULL','size_t','FILE','EOF'
)

$script:CPattern = @'
(?<com>//[^\n]*|/\*[\s\S]*?\*/)|(?<str>"(?:[^"\\]|\\.)*")|(?<chr>'(?:[^'\\]|\\.)*')|(?<pre>^[ \t]*#[ \t]*[A-Za-z_]+[^\n]*)|(?<num>\b(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)[fFlLuU]*\b)|(?<kw>\b(?:auto|break|case|char|const|continue|default|do|double|else|enum|extern|float|for|goto|if|inline|int|long|register|restrict|return|short|signed|sizeof|static|struct|switch|typedef|union|unsigned|void|volatile|while|bool|true|false|NULL|size_t|FILE|EOF)\b)|(?<fn>\b[A-Za-z_]\w*(?=\s*\())
'@

function HighlightC([string]$code) {
    $sb  = New-Object System.Text.StringBuilder
    $pos = 0
    $ms  = [regex]::Matches($code, $script:CPattern,
            [System.Text.RegularExpressions.RegexOptions]::Multiline)

    foreach ($m in $ms) {
        if ($m.Index -gt $pos) {
            [void]$sb.Append((HtmlEscape $code.Substring($pos, $m.Index - $pos)))
        }
        $cls = 'txt'
        if ($m.Groups['com'].Success)     { $cls = 'com' }
        elseif ($m.Groups['str'].Success) { $cls = 'str' }
        elseif ($m.Groups['chr'].Success) { $cls = 'chr' }
        elseif ($m.Groups['pre'].Success) { $cls = 'pre' }
        elseif ($m.Groups['num'].Success) { $cls = 'num' }
        elseif ($m.Groups['kw'].Success)  { $cls = 'kw'  }
        elseif ($m.Groups['fn'].Success)  { $cls = 'fn'  }

        if ($cls -eq 'txt') {
            [void]$sb.Append((HtmlEscape $m.Value))
        } else {
            [void]$sb.Append('<span class="tok-' + $cls + '">' + (HtmlEscape $m.Value) + '</span>')
        }
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $code.Length) {
        [void]$sb.Append((HtmlEscape $code.Substring($pos)))
    }
    return $sb.ToString()
}

function RenderCode([string]$code, [string]$lang) {
    $l = $lang.ToLowerInvariant()
    if ($l -eq 'c' -or $l -eq 'cpp' -or $l -eq 'c++') {
        $body = HighlightC $code
    } else {
        $body = HtmlEscape $code
    }
    $attr = ''
    if ($lang) { $attr = ' data-lang="' + (HtmlEscape $lang) + '"' }
    return '<pre class="code"' + $attr + '><code>' + $body + '</code></pre>' + "`n"
}

# -------------------------------------------------------- search indexing ---

function StripTags([string]$s) {
    return [regex]::Replace($s, '(?s)<[^>]+>', ' ')
}

function PlainText([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    $s = [System.Net.WebUtility]::HtmlDecode($s)
    $s = $s -replace '\s+', ' '
    return $s.Trim()
}

$script:SearchEntries = New-Object 'System.Collections.Generic.List[object]'

function Add-SearchEntry([string]$pageUrl, [string]$pageGroup, [string]$pageTitle,
                         [string]$heading, [string]$headingId, [string]$html) {
    $x = PlainText (StripTags $html)
    if (-not $x) { return }
    $h = $heading
    if ($h.Length -gt 120) { $h = $h.Substring(0, 120) }
    $start = 0
    while ($start -lt $x.Length) {
        $length = [math]::Min(1200, $x.Length - $start)
        if (($start + $length) -lt $x.Length) {
            $candidate = $x.Substring($start, $length)
            $space = $candidate.LastIndexOf(' ')
            if ($space -gt 600) { $length = $space }
        }
        $segment = $x.Substring($start, $length).Trim()
        if ($segment) {
            $script:SearchEntries.Add([pscustomobject]@{
                u = $pageUrl; g = $pageGroup; t = $pageTitle; h = $h; i = $headingId; x = $segment
            })
        }
        if (($start + $length) -ge $x.Length) { break }
        $start += [math]::Max(1, $length - 160)
    }
}

# Split a rendered page into per-heading sections for the search index.
function Add-SearchEntries([string]$html, [string]$pageUrl, [string]$pageGroup, [string]$pageTitle) {
    $ms = [regex]::Matches($html, '(?is)<h([1-6])\b[^>]*\bid="([^"]+)"[^>]*>(.*?)</h\1>')
    if ($ms.Count -eq 0) {
        Add-SearchEntry $pageUrl $pageGroup $pageTitle '' '' $html
        return
    }
    $pre = $html.Substring(0, $ms[0].Index)
    if ($pre.Trim().Length -gt 60) {
        Add-SearchEntry $pageUrl $pageGroup $pageTitle '' '' $pre
    }
    for ($k = 0; $k -lt $ms.Count; $k++) {
        $m   = $ms[$k]
        $end = if ($k + 1 -lt $ms.Count) { $ms[$k + 1].Index } else { $html.Length }
        $body = $html.Substring($m.Index, $end - $m.Index)
        $h = PlainText (StripTags $m.Groups[3].Value)
        if ($m.Groups[1].Value -eq '1' -and $h -eq $pageTitle) {
            # page-title heading: fold into the intro chunk
            Add-SearchEntry $pageUrl $pageGroup $pageTitle '' $m.Groups[2].Value $body
            continue
        }
        Add-SearchEntry $pageUrl $pageGroup $pageTitle $h $m.Groups[2].Value $body
    }
}

# ------------------------------------------------------------ table rows ---

function SplitRow([string]$row) {
    $s = $row.Trim()
    if ($s.StartsWith('|')) { $s = $s.Substring(1) }
    if ($s.EndsWith('|'))   { $s = $s.Substring(0, $s.Length - 1) }

    $cells  = New-Object 'System.Collections.Generic.List[string]'
    $cur    = New-Object System.Text.StringBuilder
    $inCode = $false

    for ($k = 0; $k -lt $s.Length; $k++) {
        $ch = $s[$k]
        if ($ch -eq '\' -and ($k + 1) -lt $s.Length -and $s[$k + 1] -eq '|') {
            [void]$cur.Append('|'); $k++; continue
        }
        if ($ch -eq '`') { $inCode = -not $inCode; [void]$cur.Append($ch); continue }
        if ($ch -eq '|' -and -not $inCode) {
            $cells.Add($cur.ToString()); [void]$cur.Clear(); continue
        }
        [void]$cur.Append($ch)
    }
    $cells.Add($cur.ToString())
    return ,$cells.ToArray()
}

function RenderCell([string]$v, [string]$head, [string]$rowLabel) {
    if ($v -notmatch '_{3,}') { return Inline $v }

    $h = (($head + ' ' + $rowLabel) -replace '\*\*|`', '').ToLowerInvariant()
    $kind  = 'text'
    $label = $head.Trim()
    if ($h -match 'exam date')                { $kind = 'date';   $label = 'Exam date' }
    elseif ($h -match 'days left')            { $kind = 'days';   $label = 'Days left' }
    elseif ($h -match 'target score|score')   { $kind = 'number'; $label = 'Target score' }
    elseif ($rowLabel.Trim())                 { $label = $rowLabel.Trim() }
    elseif (-not $label)                      { $label = 'Your answer' }

    $parts = [regex]::Split($v, '_{3,}')
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($i -gt 0) { [void]$sb.Append((NewBlankHtml $kind $label)) }
        [void]$sb.Append((Inline $parts[$i]))
    }
    return $sb.ToString()
}

function RenderTable([string]$headLine, [string]$sepLine, [string[]]$rowLines) {
    $heads = SplitRow $headLine
    $seps  = SplitRow $sepLine

    $align = @()
    for ($c = 0; $c -lt $heads.Count; $c++) {
        $sp = if ($c -lt $seps.Count) { $seps[$c].Trim() } else { '---' }
        if ($sp.StartsWith(':') -and $sp.EndsWith(':')) { $align += 'center' }
        elseif ($sp.EndsWith(':'))                      { $align += 'right' }
        else                                            { $align += 'left' }
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="table-wrap"><table>' + "`n" + '<thead><tr>')
    for ($c = 0; $c -lt $heads.Count; $c++) {
        [void]$sb.Append('<th style="text-align:' + $align[$c] + '">' + (Inline $heads[$c].Trim()) + '</th>')
    }
    [void]$sb.Append('</tr></thead>' + "`n" + '<tbody>' + "`n")

    foreach ($rl in $rowLines) {
        $cells = SplitRow $rl
        $rowLabel = if ($cells.Count -gt 0) { $cells[0].Trim() } else { '' }
        [void]$sb.Append('<tr>')
        for ($c = 0; $c -lt $heads.Count; $c++) {
            $v = if ($c -lt $cells.Count) { $cells[$c].Trim() } else { '' }
            [void]$sb.Append('<td style="text-align:' + $align[$c] + '">' + (RenderCell $v $heads[$c] $rowLabel) + '</td>')
        }
        [void]$sb.Append('</tr>' + "`n")
    }
    [void]$sb.Append('</tbody></table></div>' + "`n")
    return $sb.ToString()
}

# ---------------------------------------------------------------- lists ----

function RenderList($items, [int]$start, [int]$end) {
    $ordered = $items[$start].Ordered
    $tag = if ($ordered) { 'ol' } else { 'ul' }
    $startAttr = ''
    if ($ordered -and $items[$start].Number -gt 1) {
        $startAttr = ' start="' + $items[$start].Number + '"'
    }
    $sb  = New-Object System.Text.StringBuilder
    [void]$sb.Append("<$tag$startAttr>`n")

    $k = $start
    while ($k -lt $end) {
        $it  = $items[$k]
        $txt = [string]$it.Text
        $cb  = ''
        $cbEnd = ''

        if ($txt -match '^\[( |x|X)\]\s+(.*)$') {
            $checked = $Matches[1] -ne ' '
            $txt     = $Matches[2]
            $script:TaskNo++
            $taskId  = 'task' + $script:TaskNo
            $chk     = if ($checked) { ' checked' } else { '' }
            $cb = '<label class="task"><input type="checkbox" class="task-check" id="' + $taskId +
                  '" data-task="' + $taskId + '"' + $chk + '> <span class="task-text">'
            $cbEnd = '</span></label> '
        } else {
            $cbEnd = ''
        }

        [void]$sb.Append('<li>' + $cb + (Inline $txt) + $cbEnd)

        $j = $k + 1
        while ($j -lt $end -and $items[$j].Indent -gt $it.Indent) { $j++ }

        if ($j -gt ($k + 1)) {
            [void]$sb.Append("`n" + (RenderList $items ($k + 1) $j))
        }
        foreach ($block in $it.Blocks) {
            [void]$sb.Append("`n" + $block)
        }
        [void]$sb.Append("</li>`n")
        $k = $j
    }
    [void]$sb.Append("</$tag>`n")
    return $sb.ToString()
}

# ------------------------------------------------------- markdown parser ---

function ConvertMarkdown([string]$md) {
    $lines = $md -split "\r?\n"
    $n     = $lines.Count
    $out   = New-Object System.Text.StringBuilder
    $toc   = New-Object 'System.Collections.Generic.List[object]'
    $usedIds = @{}
    $title = $null
    $i     = 0

    while ($i -lt $n) {
        $line = $lines[$i]

        # blank
        if ($line -match '^\s*$') { $i++; continue }

        # :::trace col1, col2, ... -> blank variable-trace table
        if ($line -match '^:::trace\s*(.*)$') {
            $cols = @($Matches[1] -split '\s*,\s*' | Where-Object { $_ })
            if ($cols.Count -eq 0) { $cols = @('Line / iteration','Variable 1','Variable 2','Output') }
            [void]$out.Append('<div class="trace-card"><div class="trace-title">Variable trace — fill this in</div>' +
                              '<div class="table-wrap"><table class="trace"><thead><tr>')
            foreach ($c in $cols) { [void]$out.Append('<th>' + (HtmlEscape $c.Trim()) + '</th>') }
            [void]$out.Append('</tr></thead><tbody>')
            for ($r = 0; $r -lt 6; $r++) {
                [void]$out.Append('<tr>')
                foreach ($c in $cols) { [void]$out.Append('<td><span class="trace-cell">&nbsp;</span></td>') }
                [void]$out.Append('</tr>')
            }
            [void]$out.Append('</tbody></table></div>' +
                              '<p class="trace-hint">Copy this table into your answer book: one row per iteration, update every variable, and write the output as it appears.</p></div>' + "`n")
            $i++
            continue
        }

        # :::mistakes ... ::: -> styled common-mistakes box
        if ($line -match '^:::mistakes\s*(.*)$') {
            $boxTitle = if ($Matches[1].Trim()) { $Matches[1].Trim() } else { 'Common mistakes' }
            $i++
            $inner = New-Object 'System.Collections.Generic.List[string]'
            while ($i -lt $n -and $lines[$i] -notmatch '^:::\s*$') {
                $inner.Add($lines[$i]); $i++
            }
            if ($i -lt $n) { $i++ }
            $boxHtml = (ConvertMarkdown ($inner -join "`n")).Html
            [void]$out.Append('<div class="mistakes"><div class="box-title">' +
                              (HtmlEscape $boxTitle) + '</div>' + $boxHtml + '</div>' + "`n")
            continue
        }

        # :::flipcards -> clickable term/definition flip cards
        if ($line -match '^:::flipcards\s*$') {
            $i++
            $cards = New-Object 'System.Collections.Generic.List[object]'
            while ($i -lt $n -and $lines[$i] -notmatch '^:::\s*$') {
                $l = $lines[$i]
                if ($l -match '^\s*[-*]\s+(.*)$') {
                    $pairText = $Matches[1]
                    $sep = $pairText.IndexOf(' :: ')
                    if ($sep -ge 0) {
                        $cards.Add([pscustomobject]@{
                            Front = $pairText.Substring(0, $sep).Trim()
                            Back  = $pairText.Substring($sep + 4).Trim()
                        })
                    } else {
                        $cards.Add([pscustomobject]@{ Front = $pairText.Trim(); Back = '' })
                    }
                }
                $i++
            }
            if ($i -lt $n) { $i++ }
            [void]$out.Append('<div class="flipcards">')
            foreach ($c in $cards) {
                [void]$out.Append('<button type="button" class="flipcard"><span class="fc-front">' +
                                  (Inline $c.Front) + '</span>')
                if ($c.Back) {
                    [void]$out.Append('<span class="fc-back">' + (Inline $c.Back) + '</span>')
                }
                [void]$out.Append('</button>')
            }
            [void]$out.Append('</div><p class="io-hint">Click a card to flip it. Flip them all, then try to recall each one without looking.</p>' + "`n")
            continue
        }

        # :::mcq -> inline multiple-choice question with instant feedback
        #   :::mcq
        #   The question stem?
        #   - wrong option :: why it is wrong
        #   - *correct option :: why it is right
        #   :::
        if ($line -match '^:::mcq\s*$') {
            $i++
            $stem = ''
            $opts = New-Object 'System.Collections.Generic.List[object]'
            while ($i -lt $n -and $lines[$i] -notmatch '^:::\s*$') {
                $l = $lines[$i]
                if ($l -match '^\s*[-*]\s+(.*)$') {
                    $body = $Matches[1]
                    $correct = $false
                    if ($body.StartsWith('*')) { $correct = $true; $body = $body.Substring(1) }
                    $sep = $body.IndexOf(' :: ')
                    if ($sep -ge 0) {
                        $opts.Add([pscustomobject]@{
                            Text = $body.Substring(0, $sep).Trim()
                            Why  = $body.Substring($sep + 4).Trim()
                            Correct = $correct
                        })
                    } else {
                        $opts.Add([pscustomobject]@{ Text = $body.Trim(); Why = ''; Correct = $correct })
                    }
                } elseif ($l -match '\S') {
                    if (-not $stem) { $stem = $l.Trim() }
                }
                $i++
            }
            if ($i -lt $n) { $i++ }
            [void]$out.Append('<div class="mcq"><p class="mcq-stem"><span class="tag">Check yourself</span> ' + (Inline $stem) + '</p><div class="mcq-opts">')
            foreach ($o in $opts) {
                $cls = 'mcq-opt'
                if ($o.Correct) { $cls += ' mcq-correct' }
                $corr = if ($o.Correct) { 'true' } else { 'false' }
                [void]$out.Append('<button type="button" class="' + $cls + '" data-correct="' + $corr + '" data-why="' + (HtmlEscape $o.Why) + '">' +
                                  (Inline $o.Text) + '</button>')
            }
            [void]$out.Append('</div><div class="mcq-feedback" hidden></div></div>' + "`n")
            continue
        }

        # :::tf Statement :: true|false :: explanation
        if ($line -match '^:::tf\s+(.*)$') {
            $body = $Matches[1]
            $parts = $body -split ' :: '
            $statement = $parts[0].Trim()
            $answer = 'true'
            if ($parts.Count -gt 1) {
                $a = $parts[1].Trim().ToLowerInvariant()
                if ($a -in @('false','f','no')) { $answer = 'false' }
            }
            $why = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '' }
            [void]$out.Append('<div class="tf" data-answer="' + $answer + '" data-why="' + (HtmlEscape $why) + '"><div class="tf-statement"><span class="tag">True or false?</span> ' +
                              (Inline $statement) + '</div><div class="tf-btns">' +
                              '<button type="button" class="tf-btn" data-pick="true">True</button>' +
                              '<button type="button" class="tf-btn" data-pick="false">False</button></div>' +
                              '<div class="tf-feedback" hidden></div></div>' + "`n")
            $i++
            continue
        }

        # :::steps ... ::: -> progressive worked solution
        #   steps are separated by a line containing only ---
        #   the first heading of each step becomes its title
        if ($line -match '^:::steps\s*(.*)$') {
            $blockTitle = if ($Matches[1].Trim()) { $Matches[1].Trim() } else { 'Worked solution — reveal it step by step' }
            $i++
            $stepLines = New-Object 'System.Collections.Generic.List[string]'
            while ($i -lt $n -and $lines[$i] -notmatch '^:::\s*$') {
                $stepLines.Add($lines[$i]); $i++
            }
            if ($i -lt $n) { $i++ }

            $steps = New-Object 'System.Collections.Generic.List[string]'
            $cur   = New-Object 'System.Collections.Generic.List[string]'
            foreach ($sl in $stepLines) {
                if ($sl -match '^\s*-{3,}\s*$') {
                    $steps.Add(($cur -join "`n")); [void]$cur.Clear()
                } else {
                    [void]$cur.Add($sl)
                }
            }
            if ($cur.Count -gt 0) { $steps.Add(($cur -join "`n")) }

            [void]$out.Append('<div class="steps"><div class="steps-title">' + (HtmlEscape $blockTitle) + '</div>')
            $k = 0
            foreach ($step in $steps) {
                if (-not $step.Trim()) { continue }
                $k++
                $inner = (ConvertMarkdown $step).Html
                $head = "Step $k"
                $headHtml = ''
                $hm = [regex]::Match($inner, '(?is)^\s*<h([1-6])[^>]*>(.*?)</h\1>')
                if ($hm.Success) {
                    $headHtml = $hm.Groups[2].Value
                    $inner = $inner.Substring($hm.Index + $hm.Length).TrimStart()
                }
                $headOut = ''
                if ($headHtml) {
                    $headOut = Inline ([System.Net.WebUtility]::HtmlDecode($headHtml))
                } else {
                    $headOut = HtmlEscape $head
                }
                [void]$out.Append('<div class="step"><button type="button" class="step-head"><span class="step-no">' + $k +
                                  '</span><span class="step-name">' + $headOut +
                                  '</span></button><div class="step-body">' + $inner + '</div></div>')
            }
            [void]$out.Append('<div class="steps-tools"><button type="button" class="steps-all">Reveal all steps</button></div></div>' + "`n")
            continue
        }

        # :::progress -> panel filled from localStorage by the page script
        if ($line -match '^:::progress\s*$') {
            [void]$out.Append('<div id="donePanel" class="done-panel"><p class="muted">Mark pages as done and they will appear here.</p></div>' + "`n")
            $i++
            continue
        }

        # Q> question / A> answer -> click-to-reveal practice
        if ($line -match '^Q>\s?(.*)$') {
            $q = $Matches[1]
            $i++
            $a = ''
            if ($i -lt $n -and $lines[$i] -match '^A>\s?(.*)$') { $a = $Matches[1]; $i++ }
            [void]$out.Append('<div class="predict"><div class="predict-q"><span class="tag">Predict</span> ' +
                              (Inline $q) + '</div><details class="reveal"><summary>Show answer</summary>' +
                              '<div class="reveal-body">' + (Inline $a) + '</div></details></div>' + "`n")
            continue
        }

        # fenced code
        if ($line -match '^\s*```(.*)$') {
            $lang = $Matches[1].Trim()
            $i++
            $buf = New-Object 'System.Collections.Generic.List[string]'
            while ($i -lt $n -and $lines[$i] -notmatch '^\s*```\s*$') {
                $buf.Add($lines[$i]); $i++
            }
            if ($i -lt $n) { $i++ }
            [void]$out.Append((RenderCode ($buf -join "`n") $lang))
            continue
        }

        # heading
        if ($line -match '^(#{1,6})\s+(.*?)\s*#*\s*$') {
            $lvl  = $Matches[1].Length
            $txt  = $Matches[2]
            $plain = [regex]::Replace($txt, '`([^`]*)`', '$1')
            $plain = $plain.Replace('**', '').Replace('*', '')
            $id    = Slug $plain
            if ($usedIds.ContainsKey($id)) {
                $usedIds[$id]++
                $id = $id + '-' + $usedIds[$id]
            } else {
                $usedIds[$id] = 1
            }
            if ($lvl -eq 1 -and -not $title) { $title = $plain }
            if ($lvl -eq 2 -or $lvl -eq 3) {
                $toc.Add([pscustomobject]@{ Level = $lvl; Text = $plain; Id = $id })
            }
            [void]$out.Append("<h$lvl id=`"$id`">" + (Inline $txt) + "</h$lvl>`n")
            $i++
            continue
        }

        # horizontal rule
        if ($line -match '^\s{0,3}(-{3,}|\*{3,}|_{3,})\s*$') {
            [void]$out.Append("<hr>`n"); $i++; continue
        }

        # table
        if ($line -match '^\s*\|' -and ($i + 1) -lt $n -and
            $lines[$i + 1] -match '^\s*\|?[\s:\-\|]+\|?\s*$' -and
            $lines[$i + 1] -match '-') {
            $head = $line
            $sep  = $lines[$i + 1]
            $i += 2
            $rows = New-Object 'System.Collections.Generic.List[string]'
            while ($i -lt $n -and $lines[$i] -match '^\s*\|') {
                $rows.Add($lines[$i]); $i++
            }
            [void]$out.Append((RenderTable $head $sep $rows.ToArray()))
            continue
        }

        # blockquote
        if ($line -match '^\s*>') {
            $buf = New-Object 'System.Collections.Generic.List[string]'
            while ($i -lt $n -and $lines[$i] -match '^\s*>') {
                $buf.Add(($lines[$i] -replace '^\s*>\s?', ''))
                $i++
            }
            $inner = $buf -join "`n"
            $paras = $inner -split "\n\s*\n"
            $html  = ''
            foreach ($p in $paras) {
                $clean = ($p -replace "`n", ' ').Trim()
                if ($clean) { $html += '<p>' + (Inline $clean) + '</p>' }
            }
            [void]$out.Append('<blockquote>' + $html + '</blockquote>' + "`n")
            continue
        }

        # list
        if ($line -match '^(\s*)([-*+]|\d{1,3}[.)])\s+(.*)$') {
            $items = New-Object 'System.Collections.Generic.List[object]'
            while ($i -lt $n) {
                $l = $lines[$i]

                # blank line: only continue the list if the next block belongs to it
                if ($l -match '^\s*$') {
                    $j = $i
                    while ($j -lt $n -and $lines[$j] -match '^\s*$') { $j++ }
                    if ($j -ge $n) { $i = $j; break }

                    $nxt     = $lines[$j]
                    $nIndent = ([regex]::Match($nxt, '^(\s*)')).Groups[1].Length
                    $curInd  = if ($items.Count -gt 0) { $items[$items.Count - 1].Indent } else { 0 }

                    if ($nxt -match '^\s*```') {
                        if ($items.Count -gt 0 -and $nIndent -ge $curInd) { $i = $j; continue }
                        break
                    }
                    if ($nxt -match '^(\s*)([-*+]|\d{1,3}[.)])\s+') {
                        if ($nIndent -ge $curInd) { $i = $j; continue }
                        break
                    }
                    # an indented paragraph or table is a continuation of the item above
                    if ($nIndent -ge 2 -and $items.Count -gt 0) { $i = $j; continue }
                    break
                }

                # fenced code that belongs to the item above
                if ($l -match '^(\s*)```(.*)$') {
                    $fenceIndent = $Matches[1].Length
                    $lang        = $Matches[2].Trim()
                    $i++
                    $buf = New-Object 'System.Collections.Generic.List[string]'
                    while ($i -lt $n -and $lines[$i] -notmatch '^\s*```\s*$') {
                        $body = $lines[$i]
                        if ($body.Length -ge $fenceIndent) { $body = $body.Substring($fenceIndent) }
                        $buf.Add($body)
                        $i++
                    }
                    if ($i -lt $n) { $i++ }
                    if ($items.Count -gt 0) {
                        $items[$items.Count - 1].Blocks.Add((RenderCode ($buf -join "`n") $lang))
                    }
                    continue
                }

                # table that belongs to the item above
                if ($l -match '^\s*\|' -and ($i + 1) -lt $n -and
                    $lines[$i + 1] -match '^\s*\|?[\s:\-\|]+\|?\s*$' -and
                    $lines[$i + 1] -match '-') {
                    $head = $l.Trim()
                    $sep  = $lines[$i + 1].Trim()
                    $i += 2
                    $rows = New-Object 'System.Collections.Generic.List[string]'
                    while ($i -lt $n -and $lines[$i] -match '^\s*\|') {
                        $rows.Add($lines[$i].Trim()); $i++
                    }
                    if ($items.Count -gt 0) {
                        $items[$items.Count - 1].Blocks.Add((RenderTable $head $sep $rows.ToArray()))
                    }
                    continue
                }

                if ($l -match '^(\s*)([-*+]|\d{1,3}[.)])\s+(.*)$') {
                    $mIndent  = $Matches[1].Length
                    $mMarker  = $Matches[2]
                    $mText    = $Matches[3]
                    $mOrdered = $mMarker -match '^\d'
                    $mNumber  = 0
                    if ($mOrdered) {
                        $mNumber = [int]([regex]::Match($mMarker, '\d+').Value)
                    }
                    $items.Add([pscustomobject]@{
                        Indent  = $mIndent
                        Ordered = $mOrdered
                        Number  = $mNumber
                        Text    = $mText
                        Blocks  = (New-Object 'System.Collections.Generic.List[string]')
                    })
                    $i++
                    continue
                }

                if ($l -match '^(\s+)(\S.*)$' -and $items.Count -gt 0) {
                    $items[$items.Count - 1].Text += ' ' + $Matches[2].Trim()
                    $i++
                    continue
                }
                break
            }
            [void]$out.Append((RenderList $items 0 $items.Count))
            continue
        }

        # paragraph
        $buf = New-Object 'System.Collections.Generic.List[string]'
        while ($i -lt $n) {
            $l = $lines[$i]
            if ($l -match '^\s*$') { break }
            if ($l -match '^\s*(```|#{1,6}\s|>|\|[-*+]\s|[-*+]\s|\d{1,3}[.)]\s)') { break }
            if ($l -match '^\s*\|') { break }
            if ($l -match '^(:::|\s*[QA]>)') { break }
            $buf.Add($l.Trim())
            $i++
        }
        if ($buf.Count -gt 0) {
            [void]$out.Append('<p>' + (Inline ($buf -join ' ')) + '</p>' + "`n")
        } else {
            $i++
        }
    }

    return [pscustomobject]@{
        Html   = $out.ToString()
        Toc    = $toc
        Title  = $title
        Words  = ([regex]::Matches($md, '\S+')).Count
        Tasks  = $script:TaskNo
        Blanks = $script:BlankNo
    }
}

# ------------------------------------------------------------- page shell ---

function BuildNav([string]$root, [string]$activeOut) {
    $sb = New-Object System.Text.StringBuilder
    $groups = $script:Docs | Group-Object Group

    foreach ($g in $groups) {
        [void]$sb.Append('<div class="nav-group">')
        [void]$sb.Append('<div class="nav-head">' + (HtmlEscape $g.Name) + '</div>')
        foreach ($d in $g.Group) {
            $cls = ''
            if ($d.Out -eq $activeOut) { $cls = ' class="active"' }
            [void]$sb.Append('<a href="' + $root + $d.Out + '"' + $cls + '>' + (HtmlEscape $d.Label) + '</a>')
        }
        [void]$sb.Append('</div>')
    }
    [void]$sb.Append('<div class="nav-group"><div class="nav-head">Quiz</div>' +
                     '<a href="' + $root + 'quiz/index.html">' + (HtmlEscape ([string]$Site.quizHub)) + '</a></div>')
    return $sb.ToString()
}

function BuildToc($toc) {
    if (-not $toc -or $toc.Count -eq 0) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($t in $toc) {
        $cls = if ($t.Level -eq 3) { ' class="toc-h3"' } else { '' }
        [void]$sb.Append('<a href="#' + $t.Id + '"' + $cls + '>' + (HtmlEscape $t.Text) + '</a>')
    }
    return $sb.ToString()
}

function BuildPager([int]$index, [string]$root) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<nav class="pager">')

    if ($index -gt 0) {
        $p = $script:Docs[$index - 1]
        [void]$sb.Append('<a class="prev" href="' + $root + $p.Out + '"><span class="dir">&larr; Previous</span><span class="name">' +
                         (HtmlEscape $p.Label) + '</span></a>')
    } else {
        [void]$sb.Append('<span class="spacer"></span>')
    }

    if ($index -lt ($script:Docs.Count - 1)) {
        $nx = $script:Docs[$index + 1]
        [void]$sb.Append('<a class="next" href="' + $root + $nx.Out + '"><span class="dir">Next &rarr;</span><span class="name">' +
                         (HtmlEscape $nx.Label) + '</span></a>')
    } else {
        [void]$sb.Append('<span class="spacer"></span>')
    }

    [void]$sb.Append('</nav>')
    return $sb.ToString()
}

$script:PageTemplate = @'
<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__ · __SUFFIX__</title>
<meta name="description" content="__METADESC__">
<link rel="stylesheet" href="__ROOT__assets/notes.css">
<link rel="stylesheet" href="__ROOT__assets/theme.css">
</head>
<body data-page="__PAGEID__" data-pages="__PAGELIST__">
<div class="progress" id="progress"></div>
<div class="layout">
<aside class="sidebar">
  <a class="brand" href="__ROOT__index.html">
    <span class="brand-mark">__BRANDMARK__</span>
    <span class="brand-text"><strong>__BRANDNAME__</strong><span>__BRANDSUB__</span></span>
  </a>
  <details class="nav-details" open>
    <summary>Contents</summary>
    __NAV__
  </details>
</aside>
<main class="main">
  <div class="topbar">
    <span class="crumb">__CRUMB__</span>
    <div class="topbar-actions">
      <button class="icon-btn" id="searchBtn" title="Search all pages (Ctrl+K)" aria-label="Search all pages">
        <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="11" r="7"></circle><path d="M21 21l-4.3-4.3"></path></svg>
      </button>
      <button class="icon-btn" id="findBtn" title="Find on this page (Ctrl+Alt+F)" aria-label="Find on this page">
        <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M4 7V5h16v2M9 20h6M12 5v15"></path></svg>
      </button>
      <button class="theme-btn" id="themeBtn" title="Switch light / dark" aria-label="Switch theme">&#9789;</button>
    </div>
  </div>
  <article class="content">
__TOOLS__
__BODY__
  </article>
__PAGER__
  <footer class="foot">
    __FOOTER__
  </footer>
</main>
<aside class="toc">
  <div class="toc-title">On this page</div>
  __TOC__
</aside>
</div>
<div class="search-overlay" id="searchOverlay" hidden>
  <div class="search-modal" role="dialog" aria-label="Search">
    <div class="search-bar">
      <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="11" r="7"></circle><path d="M21 21l-4.3-4.3"></path></svg>
      <input id="searchInput" type="search" placeholder="Search every page, section and quiz&hellip;" autocomplete="off" aria-label="Search all pages">
      <kbd>Esc</kbd>
    </div>
    <div class="search-results" id="searchResults"></div>
    <div class="search-foot"><span>&uarr;&darr; choose</span><span>Enter open</span><span>Esc close</span></div>
  </div>
</div>
<div class="findbar" id="findBar" hidden>
  <div class="find-inner">
    <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M4 7V5h16v2M9 20h6M12 5v15"></path></svg>
    <input id="findInput" type="search" placeholder="Find on this page&hellip;" autocomplete="off" aria-label="Find on this page">
    <span class="find-count" id="findCount"></span>
    <button class="mini-btn" id="findPrev" title="Previous match" aria-label="Previous match">&uarr;</button>
    <button class="mini-btn" id="findNext" title="Next match" aria-label="Next match">&darr;</button>
    <button class="mini-btn" id="findClose" title="Close (Esc)" aria-label="Close find">&times;</button>
  </div>
</div>
<script src="__ROOT__assets/search-index.js"></script>
<script>
(function () {
  var root = document.documentElement;
  try {
    var saved = localStorage.getItem('__STORE__-theme');
    if (saved) root.setAttribute('data-theme', saved);
  } catch (e) {}

  var btn = document.getElementById('themeBtn');
  if (btn) btn.addEventListener('click', function () {
    var next = root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
    root.setAttribute('data-theme', next);
    btn.textContent = next === 'dark' ? '\u2600' : '\u263D';
    try { localStorage.setItem('__STORE__-theme', next); } catch (e) {}
  });

  var bar = document.getElementById('progress');
  if (bar) window.addEventListener('scroll', function () {
    var h = document.documentElement;
    var max = h.scrollHeight - h.clientHeight;
    bar.style.width = (max > 0 ? (h.scrollTop / max) * 100 : 0) + '%';
  }, { passive: true });

  // highlight the current section in the right-hand table of contents
  var links = [].slice.call(document.querySelectorAll('.toc a'));
  if (links.length) {
    var heads = links.map(function (a) { return document.getElementById(a.getAttribute('href').slice(1)); });
    window.addEventListener('scroll', function () {
      var best = -1;
      for (var i = 0; i < heads.length; i++) {
        if (heads[i] && heads[i].getBoundingClientRect().top < 120) best = i;
      }
      links.forEach(function (a, i) { a.classList.toggle('active', i === best); });
    }, { passive: true });
  }

  // on phones, start with the contents menu collapsed
  var det = document.querySelector('.nav-details');
  if (det && window.innerWidth < 1000) det.removeAttribute('open');

  // ---- interactive checklist -------------------------------------------
  var pageId  = document.body.getAttribute('data-page') || location.pathname;
  var checks  = [].slice.call(document.querySelectorAll('.task-check'));
  var countEl = document.getElementById('checkCount');
  var resetBtn = document.getElementById('resetChecks');

  function checkKey(el) { return '__STORE__:task:' + pageId + ':' + el.getAttribute('data-task'); }
  function updateCount() {
    if (!countEl) return;
    var done = checks.filter(function (c) { return c.checked; }).length;
    countEl.textContent = done + ' / ' + checks.length + ' done';
    countEl.classList.toggle('all', checks.length > 0 && done === checks.length);
  }
  checks.forEach(function (c) {
    try { if (localStorage.getItem(checkKey(c)) === '1') c.checked = true; } catch (e) {}
    c.addEventListener('change', function () {
      try { localStorage.setItem(checkKey(c), c.checked ? '1' : '0'); } catch (e) {}
      updateCount();
    });
  });
  updateCount();
  if (resetBtn) resetBtn.addEventListener('click', function () {
    checks.forEach(function (c) {
      c.checked = false;
      try { localStorage.removeItem(checkKey(c)); } catch (e) {}
    });
    updateCount();
  });

  // ---- fill-in blanks ---------------------------------------------------
  var blanks = [].slice.call(document.querySelectorAll('input.blank'));
  blanks.forEach(function (b) {
    var k = '__STORE__:blank:' + pageId + ':' + b.getAttribute('data-blank');
    try {
      var v = localStorage.getItem(k);
      if (v !== null) b.value = v;
    } catch (e) {}
    b.addEventListener('input', function () {
      try { localStorage.setItem(k, b.value); } catch (e) {}
      if (b.getAttribute('data-kind') === 'date') updateDays();
    });
  });

  function updateDays() {
    var date = document.querySelector('input.blank[data-kind="date"]');
    var days = document.querySelector('input.blank[data-kind="days"]');
    if (!date || !days) return;
    if (!date.value) { days.value = ''; return; }
    var d = new Date(date.value + 'T00:00:00');
    if (isNaN(d.getTime())) { days.value = ''; return; }
    var today = new Date();
    today.setHours(0, 0, 0, 0);
    days.value = String(Math.round((d - today) / 86400000));
  }
  updateDays();

  // ---- mark as done + progress panel -----------------------------------
  var doneBtn = document.getElementById('markDone');
  var doneKey = '__STORE__:done:' + pageId;
  function isDone() { try { return localStorage.getItem(doneKey) === '1'; } catch (e) { return false; } }
  function paintDone() {
    if (!doneBtn) return;
    doneBtn.textContent = isDone() ? '\u2713 Done' : 'Mark as done';
    doneBtn.classList.toggle('is-done', isDone());
  }
  if (doneBtn) doneBtn.addEventListener('click', function () {
    try { localStorage.setItem(doneKey, isDone() ? '0' : '1'); } catch (e) {}
    paintDone();
    renderPanel();
  });
  paintDone();

  var panel = document.getElementById('donePanel');
  var pages = [];
  try { pages = JSON.parse(document.body.getAttribute('data-pages') || '[]'); } catch (e) {}
  function renderPanel() {
    if (!panel || !pages.length) return;
    panel.innerHTML = '';
    var n = 0;
    pages.forEach(function (p) {
      try { if (localStorage.getItem('__STORE__:done:' + p.key) === '1') n++; } catch (e) {}
    });
    var head = document.createElement('p');
    head.className = 'done-summary';
    head.textContent = n + ' / ' + pages.length + ' pages marked done';
    panel.appendChild(head);

    var list = document.createElement('ul');
    list.className = 'done-list';
    pages.forEach(function (p) {
      var li = document.createElement('li');
      var a = document.createElement('a');
      a.href = p.href;
      a.textContent = p.label;
      var s = document.createElement('span');
      var d = false;
      try { d = localStorage.getItem('__STORE__:done:' + p.key) === '1'; } catch (e) {}
      s.className = 'done-flag' + (d ? ' yes' : '');
      s.textContent = d ? '\u2713 done' : 'not done';
      li.appendChild(a);
      li.appendChild(s);
      list.appendChild(li);
    });
    panel.appendChild(list);
  }
  renderPanel();

  // ---- multiple-choice quizzes -----------------------------------------
  var quiz = document.querySelector('.quiz');
  if (quiz) {
    var quizId = quiz.getAttribute('data-quiz');
    var total  = parseInt(quiz.getAttribute('data-total'), 10) || 0;
    var correct = 0;
    var answered = 0;
    var bestKey = '__STORE__:quiz:' + quizId;
    var nowEl = quiz.querySelector('.quiz-now');
    var bestEl = quiz.querySelector('.quiz-best');

    function readBest() {
      try { return parseInt(localStorage.getItem(bestKey) || '0', 10) || 0; } catch (e) { return 0; }
    }
    function paintBest() {
      if (bestEl) bestEl.textContent = 'Best: ' + readBest() + ' / ' + total;
    }
    paintBest();

    [].slice.call(quiz.querySelectorAll('.quiz-q')).forEach(function (q) {
      var answer = parseInt(q.getAttribute('data-answer'), 10);
      var feedback = q.querySelector('.quiz-feedback');
      var why = q.querySelector('.quiz-why');
      var opts = [].slice.call(q.querySelectorAll('.quiz-opt'));
      opts.forEach(function (btn) {
        btn.addEventListener('click', function () {
          if (q.classList.contains('answered')) return;
          q.classList.add('answered');
          var pick = parseInt(btn.getAttribute('data-i'), 10);
          opts.forEach(function (b) {
            b.disabled = true;
            if (parseInt(b.getAttribute('data-i'), 10) === answer) b.classList.add('correct');
          });
          if (pick === answer) {
            correct++;
            feedback.className = 'quiz-feedback good';
          } else {
            btn.classList.add('wrong');
            feedback.className = 'quiz-feedback bad';
          }
          feedback.textContent = (pick === answer ? 'Correct. ' : 'Not quite. ') + (why ? why.textContent : '');
          feedback.hidden = false;
          answered++;
          if (nowEl) nowEl.textContent = correct + ' / ' + total;
          if (answered === total) {
            var best = readBest();
            if (correct > best) {
              try { localStorage.setItem(bestKey, String(correct)); } catch (e) {}
              paintBest();
            }
          }
        });
      });
    });

    var retry = quiz.querySelector('.quiz-retry');
    if (retry) retry.addEventListener('click', function () {
      correct = 0;
      answered = 0;
      if (nowEl) nowEl.textContent = '0 / ' + total;
      [].slice.call(quiz.querySelectorAll('.quiz-q')).forEach(function (q) {
        q.classList.remove('answered');
        var f = q.querySelector('.quiz-feedback');
        f.hidden = true;
        f.textContent = '';
        f.className = 'quiz-feedback';
        [].slice.call(q.querySelectorAll('.quiz-opt')).forEach(function (b) {
          b.disabled = false;
          b.classList.remove('correct', 'wrong');
        });
      });
    });
  }

  // print shows the answers so the PDF is a complete revision sheet
  window.addEventListener('beforeprint', function () {
    [].slice.call(document.querySelectorAll('details.reveal')).forEach(function (d) {
      d.setAttribute('data-was-open', d.open ? '1' : '0');
      d.open = true;
    });
  });
  window.addEventListener('afterprint', function () {
    [].slice.call(document.querySelectorAll('details.reveal')).forEach(function (d) {
      if (d.getAttribute('data-was-open') === '0') d.open = false;
    });
  });
})();
</script>
<script>
(function () {
  var SITE_ROOT = '__ROOT__';

  // ---- flip cards ----------------------------------------------------------
  [].slice.call(document.querySelectorAll('.flipcard')).forEach(function (card) {
    card.addEventListener('click', function () { card.classList.toggle('flipped'); });
  });

  // ---- inline multiple choice ----------------------------------------------
  [].slice.call(document.querySelectorAll('.mcq')).forEach(function (box) {
    var fb = box.querySelector('.mcq-feedback');
    [].slice.call(box.querySelectorAll('.mcq-opt')).forEach(function (btn) {
      btn.addEventListener('click', function () {
        if (box.classList.contains('answered')) return;
        box.classList.add('answered');
        var correct = btn.getAttribute('data-correct') === 'true';
        [].slice.call(box.querySelectorAll('.mcq-opt')).forEach(function (b) {
          b.disabled = true;
          if (b.getAttribute('data-correct') === 'true') b.classList.add('correct');
        });
        if (!correct) btn.classList.add('wrong');
        var why = btn.getAttribute('data-why') || '';
        fb.textContent = (correct ? 'Correct. ' : 'Not quite. ') + why;
        fb.className = 'mcq-feedback ' + (correct ? 'good' : 'bad');
        fb.hidden = false;
      });
    });
  });

  // ---- true / false ----------------------------------------------------------
  [].slice.call(document.querySelectorAll('.tf')).forEach(function (box) {
    var fb = box.querySelector('.tf-feedback');
    var answer = box.getAttribute('data-answer') === 'false' ? 'false' : 'true';
    [].slice.call(box.querySelectorAll('.tf-btn')).forEach(function (btn) {
      btn.addEventListener('click', function () {
        if (box.classList.contains('answered')) return;
        box.classList.add('answered');
        var correct = btn.getAttribute('data-pick') === answer;
        [].slice.call(box.querySelectorAll('.tf-btn')).forEach(function (b) {
          b.disabled = true;
          if (b.getAttribute('data-pick') === answer) b.classList.add('correct');
        });
        if (!correct) btn.classList.add('wrong');
        fb.textContent = (correct ? 'Correct. ' : 'Not quite. ') + (box.getAttribute('data-why') || '');
        fb.className = 'tf-feedback ' + (correct ? 'good' : 'bad');
        fb.hidden = false;
      });
    });
  });

  // ---- step-by-step solutions -------------------------------------------------
  [].slice.call(document.querySelectorAll('.steps')).forEach(function (box) {
    [].slice.call(box.querySelectorAll('.step-head')).forEach(function (h) {
      h.addEventListener('click', function () { h.parentNode.classList.toggle('open'); });
    });
    var all = box.querySelector('.steps-all');
    if (all) all.addEventListener('click', function () {
      [].slice.call(box.querySelectorAll('.step')).forEach(function (s) { s.classList.add('open'); });
      all.disabled = true;
      all.textContent = 'All steps revealed';
    });
  });

  // ---- full-text search overlay ------------------------------------------------
  var INDEX = window.SEARCH_INDEX || [];
  var overlay = document.getElementById('searchOverlay');
  var sInput = document.getElementById('searchInput');
  var sResults = document.getElementById('searchResults');
  var sSel = -1;

  function escHtml(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  function runSearch(query) {
    var terms = query.toLowerCase().split(/\s+/).filter(function (t) { return t; });
    if (!terms.length) return [];
    var ql = query.toLowerCase();
    var hits = [];
    for (var n = 0; n < INDEX.length; n++) {
      var e = INDEX[n];
      var t = (e.t || '').toLowerCase();
      var h = (e.h || '').toLowerCase();
      var x = (e.x || '').toLowerCase();
      var score = 0, ok = true, firstPos = -1;
      for (var i = 0; i < terms.length; i++) {
        var term = terms[i];
        var pt = t.indexOf(term), ph = h.indexOf(term), px = x.indexOf(term);
        if (pt < 0 && ph < 0 && px < 0) { ok = false; break; }
        if (pt >= 0) score += 8;
        if (ph >= 0) score += 5;
        if (px >= 0) { score += 1; if (firstPos < 0) firstPos = px; }
      }
      if (!ok) continue;
      if (ql.length > 3 && x.indexOf(ql) >= 0) score += 6;
      if (h.indexOf(ql) >= 0) score += 4;
      hits.push({ e: e, score: score, pos: firstPos });
    }
    hits.sort(function (a, b) { return b.score - a.score; });
    return hits.slice(0, 24);
  }

  function snippetHtml(e, pos, query) {
    var x = e.x || '';
    if (pos < 0) pos = 0;
    var start = Math.max(0, pos - 60);
    var end = Math.min(x.length, pos + 150);
    var raw = (start > 0 ? '\u2026' : '') + x.substring(start, end) + (end < x.length ? '\u2026' : '');
    var html = escHtml(raw);
    var terms = query.toLowerCase().split(/\s+/).filter(function (t) { return t; })
      .sort(function (a, b) { return b.length - a.length; });
    for (var i = 0; i < terms.length; i++) {
      var t = terms[i].replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      html = html.replace(new RegExp('(' + t + ')', 'gi'), '<mark>$1</mark>');
    }
    return html;
  }

  function addHit(hit, query) {
    var e = hit.e;
    var a = document.createElement('a');
    a.className = 'sr-item';
    a.href = SITE_ROOT + e.u + (e.i ? '#' + e.i : '');
    var meta = e.g + (e.h ? ' \u00b7 ' + e.h : '');
    a.innerHTML =
      '<span class="sr-meta">' + escHtml(meta) + '</span>' +
      '<span class="sr-title">' + escHtml(e.t) + '</span>' +
      (query ? '<span class="sr-snippet">' + snippetHtml(e, hit.pos, query) + '</span>' : '');
    a.addEventListener('click', function () { closeSearch(); });
    sResults.appendChild(a);
  }

  function paintSearch(query) {
    sResults.innerHTML = '';
    if (!query.trim()) {
      var pages = [];
      for (var n = 0; n < INDEX.length; n++) {
        if (!INDEX[n].h) pages.push({ e: INDEX[n], pos: -1 });
      }
      pages.slice(0, 14).forEach(function (hit) { addHit(hit, ''); });
      return;
    }
    var hits = runSearch(query);
    if (!hits.length) {
      sResults.innerHTML = '<div class="sr-empty">Nothing matches &ldquo;' + escHtml(query) + '&rdquo;. Try a shorter word.</div>';
      return;
    }
    hits.forEach(function (hit) { addHit(hit, query); });
  }

  function paintSel() {
    var items = [].slice.call(sResults.querySelectorAll('.sr-item'));
    items.forEach(function (el, i) { el.classList.toggle('active', i === sSel); });
    if (sSel >= 0 && items[sSel]) items[sSel].scrollIntoView({ block: 'nearest' });
  }

  function openSearch() {
    if (!overlay) return;
    overlay.hidden = false;
    sInput.value = '';
    paintSearch('');
    sInput.focus();
  }
  function closeSearch() { if (overlay) overlay.hidden = true; }

  if (overlay && sInput && sResults) {
    document.getElementById('searchBtn').addEventListener('click', openSearch);
    overlay.addEventListener('mousedown', function (ev) {
      if (ev.target === overlay) closeSearch();
    });
    sInput.addEventListener('input', function () { paintSearch(sInput.value); });
    sInput.addEventListener('keydown', function (ev) {
      var items = [].slice.call(sResults.querySelectorAll('.sr-item'));
      if (ev.key === 'ArrowDown') { ev.preventDefault(); if (sSel < items.length - 1) sSel++; paintSel(); }
      else if (ev.key === 'ArrowUp') { ev.preventDefault(); if (sSel > 0) sSel--; paintSel(); }
      else if (ev.key === 'Enter') {
        ev.preventDefault();
        var target = items[sSel >= 0 ? sSel : 0];
        if (target) location.href = target.href;
      }
    });
  }

  // ---- find on this page --------------------------------------------------------
  var findBar = document.getElementById('findBar');
  var fInput = document.getElementById('findInput');
  var fCount = document.getElementById('findCount');
  var fMarks = [];
  var fCur = -1;
  var fTimer = null;

  function collectTextNodes(el, out) {
    var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        if (!n.nodeValue || !n.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
        var p = n.parentNode;
        if (p && p.closest && p.closest('script,style,mark.find-m')) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    while (walker.nextNode()) out.push(walker.currentNode);
    return out;
  }

  function clearFind() {
    [].slice.call(document.querySelectorAll('mark.find-m')).forEach(function (m) {
      var parent = m.parentNode;
      if (!parent) return;
      parent.replaceChild(document.createTextNode(m.textContent), m);
      parent.normalize();
    });
    fMarks = [];
    fCur = -1;
  }

  function paintFindCount() {
    if (!fCount) return;
    if (fMarks.length) {
      fCount.textContent = (fCur + 1) + ' / ' + fMarks.length;
    } else {
      fCount.textContent = (fInput.value.trim().length >= 2 ? 'no match' : '');
    }
  }

  function showFind(i) {
    [].slice.call(document.querySelectorAll('mark.find-m.current')).forEach(function (m) {
      m.classList.remove('current');
    });
    if (i >= 0 && i < fMarks.length) {
      fCur = i;
      var m = fMarks[i];
      m.classList.add('current');
      m.scrollIntoView({ block: 'center' });
    }
    paintFindCount();
  }

  function doFind(q) {
    clearFind();
    if (q.trim().length < 2) { paintFindCount(); return; }
    var content = document.querySelector('.content') || document.body;
    var nodes = collectTextNodes(content, []);
    var ql = q.toLowerCase();
    nodes.forEach(function (node) {
      var text = node.nodeValue;
      var lower = text.toLowerCase();
      var idx = lower.indexOf(ql);
      if (idx < 0) return;
      var frag = document.createDocumentFragment();
      var pos = 0;
      while (idx >= 0) {
        frag.appendChild(document.createTextNode(text.substring(pos, idx)));
        var mk = document.createElement('mark');
        mk.className = 'find-m';
        mk.textContent = text.substring(idx, idx + ql.length);
        frag.appendChild(mk);
        fMarks.push(mk);
        pos = idx + ql.length;
        idx = lower.indexOf(ql, pos);
      }
      frag.appendChild(document.createTextNode(text.substring(pos)));
      node.parentNode.replaceChild(frag, node);
    });
    if (fMarks.length) showFind(0); else paintFindCount();
  }

  function openFind() {
    if (!findBar) return;
    findBar.hidden = false;
    fInput.focus();
    fInput.select();
  }
  function closeFind() {
    if (!findBar) return;
    findBar.hidden = true;
    clearFind();
    paintFindCount();
  }

  if (findBar && fInput) {
    document.getElementById('findBtn').addEventListener('click', openFind);
    document.getElementById('findClose').addEventListener('click', closeFind);
    document.getElementById('findPrev').addEventListener('click', function () {
      if (fMarks.length) showFind((fCur - 1 + fMarks.length) % fMarks.length);
    });
    document.getElementById('findNext').addEventListener('click', function () {
      if (fMarks.length) showFind((fCur + 1) % fMarks.length);
    });
    fInput.addEventListener('input', function () {
      if (fTimer) clearTimeout(fTimer);
      fTimer = setTimeout(function () { doFind(fInput.value); }, 150);
    });
    fInput.addEventListener('keydown', function (ev) {
      if (ev.key === 'Enter') {
        ev.preventDefault();
        if (fMarks.length) showFind((fCur + 1) % fMarks.length);
      } else if (ev.key === 'Escape') {
        closeFind();
      }
    });
  }

  // ---- global keyboard shortcuts --------------------------------------------------
  document.addEventListener('keydown', function (ev) {
    var inField = /^(input|textarea|select)$/i.test((ev.target && ev.target.tagName) || '');
    if ((ev.ctrlKey || ev.metaKey) && (ev.key === 'k' || ev.key === 'K')) {
      ev.preventDefault();
      if (overlay && overlay.hidden) openSearch(); else closeSearch();
    } else if (ev.ctrlKey && ev.altKey && (ev.key === 'f' || ev.key === 'F')) {
      ev.preventDefault();
      if (findBar && findBar.hidden) openFind(); else closeFind();
    } else if (ev.key === 'Escape') {
      if (overlay && !overlay.hidden) closeSearch();
      else if (findBar && !findBar.hidden) closeFind();
    } else if (ev.key === '/' && !inField && overlay && overlay.hidden) {
      ev.preventDefault();
      openSearch();
    }
  });
})();
</script>
</body>
</html>
'@

# ------------------------------------------------------------------ docs ----
# The page list lives in site.json (loaded at the top of this script).

# ------------------------------------------------------- quiz data (parse) --

$script:QuizSections = New-Object 'System.Collections.Generic.List[object]'
$quizDataFile = Join-Path $OutRoot '_quiz.txt'

if (Test-Path -LiteralPath $quizDataFile) {
    $curSection = $null
    foreach ($line in [System.IO.File]::ReadAllLines($quizDataFile, [System.Text.Encoding]::UTF8)) {
        if ($line -match '^@(\d{2})\|(.+)$') {
            $num   = $Matches[1]
            $qtitle = $Matches[2]
            $curSection = [pscustomobject]@{
                Num   = $num
                Title = $qtitle
                Items = (New-Object 'System.Collections.Generic.List[object]')
            }
            $script:QuizSections.Add($curSection)
            continue
        }
        if ($line -match '^Q\|' -and $curSection) {
            $parts = $line -split '\|'
            if ($parts.Count -ge 8) { $curSection.Items.Add($parts) }
        }
    }
}

# ------------------------------------------------------------------ build ---

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$built = 0
$indexCards = New-Object 'System.Collections.Generic.List[object]'

# ------------------------------------------------------------------ theme ---

$themeCss = ':root {' + "`n" +
            '  --accent: '   + [string]$Site.accent  + ';' + "`n" +
            '  --accent-2: ' + [string]$Site.accent2 + ';' + "`n" +
            '}' + "`n" +
            '[data-theme="dark"] {' + "`n" +
            '  --accent: '   + [string]$Site.accentDark  + ';' + "`n" +
            '  --accent-2: ' + [string]$Site.accent2Dark + ';' + "`n" +
            '}' + "`n"
$assetsDir0 = Join-Path $OutRoot 'assets'
if (-not (Test-Path $assetsDir0)) { New-Item -ItemType Directory -Force -Path $assetsDir0 | Out-Null }
[System.IO.File]::WriteAllText((Join-Path $assetsDir0 'theme.css'), $themeCss,
    (New-Object System.Text.UTF8Encoding($false)))

# Link map: source Markdown path -> generated page.
foreach ($d in $script:Docs) {
    $srcRel = $d.Md -replace '\\', '/'
    $script:DocMap[$srcRel.ToLowerInvariant()] = $d.Out
    $leaf = $srcRel.Substring($srcRel.LastIndexOf('/') + 1).ToLowerInvariant()
    if (-not $script:DocMap.ContainsKey($leaf)) { $script:DocMap[$leaf] = $d.Out }
}

for ($d = 0; $d -lt $script:Docs.Count; $d++) {
    $doc = $script:Docs[$d]
    $src = Join-Path $PackRoot $doc.Md
    if (-not (Test-Path $src)) { Write-Warning "missing: $src"; continue }

    $script:CurrentOut = $doc.Out
    $script:TaskNo     = 0
    $script:BlankNo    = 0

    $md = Get-Content -LiteralPath $src -Raw -Encoding UTF8
    $res = ConvertMarkdown $md

    if ($doc.Out -match '^notes/(\d{2})_') {
        $num = $Matches[1]
        $hasPredict = $false
        foreach ($pd in $script:Docs) {
            if ($pd.Out -eq 'practice/PREDICT_OUTPUT.html') { $hasPredict = $true }
        }
        $hasQuiz = $false
        foreach ($qs in $script:QuizSections) {
            if ($qs.Num -eq $num) { $hasQuiz = $true }
        }
        $plinks = '<div class="practice-links"><span>Practise this topic:</span>'
        if ($hasPredict) {
            $plinks += '<a href="' + (Get-RelHref 'practice/PREDICT_OUTPUT.html') + '#note-' + $num + '">Predict the output</a>'
        }
        if ($hasQuiz) {
            $plinks += '<a href="' + (Get-RelHref ('quiz/' + $num + '.html')) + '">10-question quiz</a>'
        } else {
            $plinks += '<a href="' + (Get-RelHref 'practice/QUESTION_BANK.html') + '">Question bank</a>'
        }
        $plinks += '</div>' + "`n"
        $res.Html += $plinks
    }

    $depth = $doc.Out.Split('/').Count - 1
    $root  = if ($depth -gt 0) { '../' } else { '' }

    $title = if ($res.Title) { $res.Title } else { $doc.Label }

    Add-SearchEntries $res.Html $doc.Out $doc.Group $title

    $tools = '<div class="page-tools">'
    if ($res.Tasks -gt 0) {
        $tools += '<span class="check-count" id="checkCount">0 / ' + $res.Tasks + ' done</span>'
        $tools += '<button type="button" class="reset-btn" id="resetChecks">Reset checklist</button>'
    }
    $tools += '<button type="button" class="done-btn" id="markDone">Mark as done</button>'
    $tools += '</div>'

    $pageList = @()
    foreach ($pd in $script:Docs) {
        if ($pd.Group -ne 'Notes') { continue }
        $pageList += [pscustomobject]@{
            label = $pd.Label
            href  = (Get-RelHref $pd.Out)
            key   = $pd.Out
        }
    }
    $pageJson = ConvertTo-Json -InputObject @($pageList) -Compress

    $html = $script:PageTemplate
    $html = $html.Replace('__TITLE__', (HtmlEscape $title))
    $html = $html.Replace('__ROOT__',  $root)
    $html = $html.Replace('__SUFFIX__', (HtmlEscape $Site.suffix))
    $html = $html.Replace('__METADESC__', (HtmlEscape $Site.metadesc))
    $html = $html.Replace('__BRANDMARK__', (HtmlEscape $Site.brandMark))
    $html = $html.Replace('__BRANDNAME__', (HtmlEscape $Site.brandName))
    $html = $html.Replace('__BRANDSUB__', (HtmlEscape $Site.brandSub))
    $html = $html.Replace('__FOOTER__', (HtmlEscape $Site.footer))
    $html = $html.Replace('__STORE__', (HtmlEscape ([string]$Site.store)))
    $html = $html.Replace('__PAGEID__', (HtmlEscape $doc.Out))
    $html = $html.Replace('__PAGELIST__', (HtmlEscape $pageJson))
    $html = $html.Replace('__NAV__',   (BuildNav $root $doc.Out))
    $html = $html.Replace('__CRUMB__', (HtmlEscape $doc.Group) + ' <b>&rsaquo;</b> ' + (HtmlEscape ((Split-Path -Leaf $src) -replace '\.md$', '')))
    $html = $html.Replace('__TOOLS__', $tools)
    $html = $html.Replace('__BODY__',  $res.Html)
    $html = $html.Replace('__PAGER__', (BuildPager $d $root))
    $html = $html.Replace('__TOC__',   (BuildToc $res.Toc))

    $dest = Join-Path $OutRoot ($doc.Out -replace '/', '\')
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }

    [System.IO.File]::WriteAllText($dest, $html, (New-Object System.Text.UTF8Encoding($false)))
    $built++

    $indexCards.Add([pscustomobject]@{
        Group = $doc.Group
        Label = $doc.Label
        Out   = $doc.Out
        Title = $title
        Words = $res.Words
    })

    Write-Host ("  {0,-52} {1,6} words" -f $doc.Out, $res.Words)
}

# ------------------------------------------------------------------ quiz ----

$quizDir = Join-Path $OutRoot 'quiz'
    if (-not (Test-Path $quizDir)) { New-Item -ItemType Directory -Force -Path $quizDir | Out-Null }

    foreach ($s in $script:QuizSections) {
        $body = New-Object System.Text.StringBuilder
        [void]$body.Append('<h1>Quiz ' + $s.Num + ': ' + (HtmlEscape $s.Title) + '</h1>' + "`n")
        [void]$body.Append('<p class="quiz-intro">Ten questions. Pick one answer to get instant feedback. Your best score is saved on this device.</p>' + "`n")
        [void]$body.Append('<div class="quiz" data-quiz="' + $s.Num + '" data-total="' + $s.Items.Count + '">' + "`n")
        [void]$body.Append('<div class="quiz-score"><span class="quiz-now">0 / ' + $s.Items.Count + '</span>' +
                           '<span class="quiz-best">Best: 0 / ' + $s.Items.Count + '</span>' +
                           '<button type="button" class="quiz-retry">Retry</button></div>' + "`n")

        for ($k = 0; $k -lt $s.Items.Count; $k++) {
            $parts = $s.Items[$k]
            $question = $parts[1]
            $answer   = [int]$parts[6]
            $why      = $parts[7]
            [void]$body.Append('<div class="quiz-q" data-answer="' + $answer + '">' + "`n")
            [void]$body.Append('<p class="quiz-stem"><span class="qnum">' + ($k + 1) + '.</span> ' +
                               (Inline $question) + '</p>' + "`n")
            [void]$body.Append('<div class="quiz-opts">')
            for ($o = 0; $o -lt 4; $o++) {
                $letter = [char](65 + $o)
                [void]$body.Append('<button type="button" class="quiz-opt" data-i="' + ($o + 1) + '">' +
                                   '<span class="opt-letter">' + $letter + '.</span> ' +
                                   (Inline $parts[2 + $o]) + '</button>')
            }
            [void]$body.Append('</div>' + "`n")
            [void]$body.Append('<div class="quiz-why" hidden>' + (Inline $why) + '</div>' + "`n")
            [void]$body.Append('<div class="quiz-feedback" hidden></div>' + "`n")
            [void]$body.Append('</div>' + "`n")

            # one searchable entry per quiz question
            $qRendered = (Inline $question) + ' ' + ((2..5 | ForEach-Object { Inline $parts[$_] }) -join ' ') + ' ' + (Inline $why)
            Add-SearchEntry ('quiz/' + $s.Num + '.html') 'Quiz' ('Quiz ' + $s.Num + ': ' + $s.Title) '' '' $qRendered
        }
        [void]$body.Append('</div>' + "`n")
        $keep = '<div class="practice-links"><span>Keep going:</span>'
        $hasPredict = $false
        foreach ($pd in $script:Docs) {
            if ($pd.Out -eq 'practice/PREDICT_OUTPUT.html') { $hasPredict = $true }
        }
        if ($hasPredict) {
            $keep += '<a href="../practice/PREDICT_OUTPUT.html#note-' + $s.Num + '">Predict the output</a>'
        }
        $keep += '<a href="index.html">All quizzes</a>'
        $noteFile = Get-ChildItem -LiteralPath (Join-Path $PackRoot 'notes') -Filter ($s.Num + '_*.md') -ErrorAction SilentlyContinue |
                    Select-Object -First 1
        if ($noteFile) {
            $keep += '<a href="../notes/' + $s.Num + '_' + $noteFile.BaseName.Substring(3) + '.html">Back to the note</a>'
        }
        $keep += '</div>' + "`n"
        [void]$body.Append($keep)

        $qhtml = $script:PageTemplate
        $qhtml = $qhtml.Replace('__TITLE__', ('Quiz ' + $s.Num + ': ' + (HtmlEscape $s.Title)))
        $qhtml = $qhtml.Replace('__ROOT__', '../')
        $qhtml = $qhtml.Replace('__SUFFIX__', (HtmlEscape $Site.suffix))
        $qhtml = $qhtml.Replace('__METADESC__', (HtmlEscape $Site.metadesc))
        $qhtml = $qhtml.Replace('__BRANDMARK__', (HtmlEscape $Site.brandMark))
        $qhtml = $qhtml.Replace('__BRANDNAME__', (HtmlEscape $Site.brandName))
        $qhtml = $qhtml.Replace('__BRANDSUB__', (HtmlEscape $Site.brandSub))
        $qhtml = $qhtml.Replace('__FOOTER__', (HtmlEscape $Site.footer))
        $qhtml = $qhtml.Replace('__STORE__', (HtmlEscape ([string]$Site.store)))
        $qhtml = $qhtml.Replace('__PAGEID__', ('quiz/' + $s.Num + '.html'))
        $qhtml = $qhtml.Replace('__PAGELIST__', '[]')
        $qhtml = $qhtml.Replace('__NAV__', (BuildNav '../' ('quiz/' + $s.Num + '.html')))
        $qhtml = $qhtml.Replace('__CRUMB__', 'Practice <b>&rsaquo;</b> Quiz ' + $s.Num)
        $qhtml = $qhtml.Replace('__TOOLS__', '')
        $qhtml = $qhtml.Replace('__BODY__', $body.ToString())
        $qhtml = $qhtml.Replace('__PAGER__', '')
        $qhtml = $qhtml.Replace('__TOC__', '')

        [System.IO.File]::WriteAllText((Join-Path $quizDir ($s.Num + '.html')), $qhtml,
            (New-Object System.Text.UTF8Encoding($false)))

        $indexCards.Add([pscustomobject]@{
            Group = 'Quiz'
            Label = ('Quiz ' + $s.Num + ': ' + $s.Title)
            Out   = ('quiz/' + $s.Num + '.html')
            Title = ('Quiz ' + $s.Title)
            Words = 120
        })
    }

    # quiz hub
    $cards = New-Object System.Text.StringBuilder
    [void]$cards.Append('<h1>Quizzes</h1><p class="quiz-intro">Ten multiple-choice questions for every note. Answers give instant feedback; your best score stays on this device.</p><div class="quiz-cards">')
    foreach ($s in $script:QuizSections) {
        [void]$cards.Append('<a class="quiz-card" href="' + $s.Num + '.html"><b>' + $s.Num + '</b><span>' +
                            (HtmlEscape $s.Title) + '</span><em>' + $s.Items.Count + ' questions</em></a>')
    }
    [void]$cards.Append('</div><div class="practice-links"><span>Before the quiz:</span>')
    $hasPredict = $false
    foreach ($pd in $script:Docs) {
        if ($pd.Out -eq 'practice/PREDICT_OUTPUT.html') { $hasPredict = $true }
    }
    if ($hasPredict) {
        [void]$cards.Append('<a href="../practice/PREDICT_OUTPUT.html">Predict the output</a>')
    }
    [void]$cards.Append('<a href="../CHEAT_SHEET.html">Cheat sheet</a></div>')

    $ih = $script:PageTemplate
    $ih = $ih.Replace('__TITLE__', 'Quizzes')
    $ih = $ih.Replace('__ROOT__', '../')
    $ih = $ih.Replace('__SUFFIX__', (HtmlEscape $Site.suffix))
    $ih = $ih.Replace('__METADESC__', (HtmlEscape $Site.metadesc))
    $ih = $ih.Replace('__BRANDMARK__', (HtmlEscape $Site.brandMark))
    $ih = $ih.Replace('__BRANDNAME__', (HtmlEscape $Site.brandName))
    $ih = $ih.Replace('__BRANDSUB__', (HtmlEscape $Site.brandSub))
    $ih = $ih.Replace('__FOOTER__', (HtmlEscape $Site.footer))
    $ih = $ih.Replace('__STORE__', (HtmlEscape ([string]$Site.store)))
    $ih = $ih.Replace('__PAGEID__', 'quiz/index.html')
    $ih = $ih.Replace('__PAGELIST__', '[]')
    $ih = $ih.Replace('__NAV__', (BuildNav '../' 'quiz/index.html'))
    $ih = $ih.Replace('__CRUMB__', 'Practice <b>&rsaquo;</b> Quizzes')
    $ih = $ih.Replace('__TOOLS__', '')
    $ih = $ih.Replace('__BODY__', $cards.ToString())
    $ih = $ih.Replace('__PAGER__', '')
    $ih = $ih.Replace('__TOC__', '')
    [System.IO.File]::WriteAllText((Join-Path $quizDir 'index.html'), $ih,
        (New-Object System.Text.UTF8Encoding($false)))

    $indexCards.Add([pscustomobject]@{
        Group = 'Quiz'; Label = ([string]$Site.quizHub); Out = 'quiz/index.html'
        Title = 'Quizzes'; Words = 60
    })

# ------------------------------------------------------------ search index --

$jsIdx = New-Object System.Text.StringBuilder
[void]$jsIdx.Append('window.SEARCH_INDEX=[')
$firstEntry = $true
foreach ($e in $script:SearchEntries) {
    if (-not $firstEntry) { [void]$jsIdx.Append(',') }
    $firstEntry = $false
    [void]$jsIdx.Append('{"u":"' + (JEsc ([string]$e.u)) +
                        '","g":"' + (JEsc ([string]$e.g)) +
                        '","t":"' + (JEsc ([string]$e.t)) +
                        '","h":"' + (JEsc ([string]$e.h)) +
                        '","i":"' + (JEsc ([string]$e.i)) +
                        '","x":"' + (JEsc ([string]$e.x)) + '"}')
}
[void]$jsIdx.Append('];')
$assetsDir = Join-Path $OutRoot 'assets'
if (-not (Test-Path $assetsDir)) { New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null }
[System.IO.File]::WriteAllText((Join-Path $assetsDir 'search-index.js'), $jsIdx.ToString(),
    (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("Search index: {0} sections" -f $script:SearchEntries.Count)

# ----------------------------------------------------------------- index ----

$totalWords = ($indexCards | Measure-Object Words -Sum).Sum
$cardHtml = New-Object System.Text.StringBuilder

foreach ($g in ($indexCards | Group-Object Group)) {
    [void]$cardHtml.Append('<div class="group-title">' + (HtmlEscape $g.Name) + '</div><div class="cards">')
    foreach ($c in $g.Group) {
        $mins = [math]::Max(1, [math]::Round($c.Words / 200))
        [void]$cardHtml.Append(
            '<a class="card" href="' + $c.Out + '" data-search="' +
            (HtmlEscape ($c.Title + ' ' + $g.Name).ToLowerInvariant()) + '">' +
            '<span class="num">' + (HtmlEscape $g.Name).ToUpperInvariant() + '</span>' +
            '<span class="title">' + (HtmlEscape $c.Label) + '</span>' +
            '<span class="meta">' + $mins + ' min read</span></a>')
    }
    [void]$cardHtml.Append('</div>')
}

$indexTemplate = @'
<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__HEROTITLE__ · __SUFFIX__</title>
<meta name="description" content="__METADESC__">
<link rel="stylesheet" href="assets/notes.css">
<link rel="stylesheet" href="assets/theme.css">
</head>
<body>
<div class="progress" id="progress"></div>
<header class="hero">
  <span class="kicker">__KICKER__</span>
  <h1>__HEROTITLE__</h1>
  <p class="lede">__HEROLEDE__</p>
  <div class="search">
    <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="7"></circle><path d="M20 20l-3.5-3.5"></path></svg>
    <input id="q" type="search" placeholder="Search everything &mdash; topics, definitions, worked examples, quiz questions&hellip;" autocomplete="off" aria-label="Search">
  </div>
  <p class="search-hint">Searches <strong>inside</strong> every note, not just titles. On any notes page press <strong>Ctrl+K</strong> for this search, or <strong>Ctrl+Alt+F</strong> to find within that page.</p>
</header>
<main class="groups" id="groups">
__CARDS__
<div class="no-results" id="noResults" hidden>Nothing matches that search.</div>
<div class="search-hits" id="searchHits" hidden></div>
<div class="group-title">Print</div>
<p style="color:var(--muted);font-size:13.5px;margin:0">
  Any page can be saved as a PDF: open it and press <strong>Ctrl+P</strong> &rarr; <em>Destination: Save as PDF</em>.
</p>
</main>
<footer class="foot" style="padding-top:10px">
  __COUNT__ pages &middot; __WORDS__ words &middot; __FOOTER__
</footer>
<script src="assets/search-index.js"></script>
<script>
(function () {
  var root = document.documentElement;
  try {
    var saved = localStorage.getItem('__STORE__-theme');
    if (saved) root.setAttribute('data-theme', saved);
  } catch (e) {}

  var INDEX = window.SEARCH_INDEX || [];
  var q = document.getElementById('q');
  var groupsEl = document.getElementById('groups');
  var noRes = document.getElementById('noResults');
  var hitsEl = document.getElementById('searchHits');
  var cards = [].slice.call(document.querySelectorAll('.card'));

  function escHtml(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  function runSearch(query) {
    var terms = query.toLowerCase().split(/\s+/).filter(function (t) { return t; });
    if (!terms.length) return [];
    var ql = query.toLowerCase();
    var hits = [];
    for (var n = 0; n < INDEX.length; n++) {
      var e = INDEX[n];
      var t = (e.t || '').toLowerCase();
      var h = (e.h || '').toLowerCase();
      var x = (e.x || '').toLowerCase();
      var score = 0, ok = true, firstPos = -1;
      for (var i = 0; i < terms.length; i++) {
        var term = terms[i];
        var pt = t.indexOf(term), ph = h.indexOf(term), px = x.indexOf(term);
        if (pt < 0 && ph < 0 && px < 0) { ok = false; break; }
        if (pt >= 0) score += 8;
        if (ph >= 0) score += 5;
        if (px >= 0) { score += 1; if (firstPos < 0) firstPos = px; }
      }
      if (!ok) continue;
      if (ql.length > 3 && x.indexOf(ql) >= 0) score += 6;
      if (h.indexOf(ql) >= 0) score += 4;
      hits.push({ e: e, score: score, pos: firstPos });
    }
    hits.sort(function (a, b) { return b.score - a.score; });
    return hits.slice(0, 30);
  }

  function snippetHtml(e, pos, query) {
    var x = e.x || '';
    if (pos < 0) pos = 0;
    var start = Math.max(0, pos - 60);
    var end = Math.min(x.length, pos + 150);
    var raw = (start > 0 ? '\u2026' : '') + x.substring(start, end) + (end < x.length ? '\u2026' : '');
    var html = escHtml(raw);
    var terms = query.toLowerCase().split(/\s+/).filter(function (t) { return t; })
      .sort(function (a, b) { return b.length - a.length; });
    for (var i = 0; i < terms.length; i++) {
      var t = terms[i].replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      html = html.replace(new RegExp('(' + t + ')', 'gi'), '<mark>$1</mark>');
    }
    return html;
  }

  function paintHits(query) {
    hitsEl.innerHTML = '';
    var hits = runSearch(query);
    if (!hits.length) {
      hitsEl.hidden = true;
      noRes.hidden = false;
      return;
    }
    hits.forEach(function (hit) {
      var e = hit.e;
      var a = document.createElement('a');
      a.className = 'sr-item';
      a.href = e.u + (e.i ? '#' + e.i : '');
      var meta = e.g + (e.h ? ' \u00b7 ' + e.h : '');
      a.innerHTML =
        '<span class="sr-meta">' + escHtml(meta) + '</span>' +
        '<span class="sr-title">' + escHtml(e.t) + '</span>' +
        '<span class="sr-snippet">' + snippetHtml(e, hit.pos, query) + '</span>';
      hitsEl.appendChild(a);
    });
    hitsEl.hidden = false;
    noRes.hidden = true;
  }

  if (q) q.addEventListener('input', function () {
    var v = q.value.trim();
    if (!v) {
      groupsEl.style.display = '';
      hitsEl.hidden = true;
      noRes.hidden = true;
      return;
    }
    groupsEl.style.display = 'none';
    paintHits(v);
  });

  var bar = document.getElementById('progress');
  if (bar) window.addEventListener('scroll', function () {
    var h = document.documentElement;
    var max = h.scrollHeight - h.clientHeight;
    bar.style.width = (max > 0 ? (h.scrollTop / max) * 100 : 0) + '%';
  }, { passive: true });

  document.addEventListener('keydown', function (ev) {
    if ((ev.ctrlKey || ev.metaKey) && (ev.key === 'k' || ev.key === 'K')) {
      ev.preventDefault();
      q.focus();
      q.select();
    }
  });
})();
</script>
</body>
</html>
'@

$index = $indexTemplate.Replace('__CARDS__', $cardHtml.ToString())
$index = $index.Replace('__COUNT__', [string]$built)
$index = $index.Replace('__WORDS__', ('{0:N0}' -f $totalWords))
$index = $index.Replace('__KICKER__', (HtmlEscape ([string]$Site.kicker)))
$index = $index.Replace('__HEROTITLE__', (HtmlEscape ([string]$Site.heroTitle)))
$index = $index.Replace('__HEROLEDE__', (HtmlEscape ([string]$Site.heroLede)))
$index = $index.Replace('__METADESC__', (HtmlEscape $Site.metadesc))
$index = $index.Replace('__SUFFIX__', (HtmlEscape $Site.suffix))
$index = $index.Replace('__FOOTER__', (HtmlEscape $Site.footer))
$index = $index.Replace('__STORE__', (HtmlEscape ([string]$Site.store)))

[System.IO.File]::WriteAllText((Join-Path $OutRoot 'index.html'), $index,
    (New-Object System.Text.UTF8Encoding($false)))

$sw.Stop()
Write-Host ''
Write-Host ("Done: {0} pages + index in {1:N1}s" -f $built, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
Write-Host ("Open: {0}" -f (Join-Path $OutRoot 'index.html'))
