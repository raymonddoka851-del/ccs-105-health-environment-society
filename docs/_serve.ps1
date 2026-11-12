# Serves the generated docs/ folder locally so the browser tool can open it.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File ".\docs\_serve.ps1" [-Port 8765]
param(
    [int]$Port = 8765
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$l = New-Object System.Net.HttpListener
$l.Prefixes.Add("http://127.0.0.1:$Port/")
$l.Start()
Write-Host "Serving $root at http://127.0.0.1:$Port/ (Ctrl+C to stop)"

$types = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.json' = 'application/json; charset=utf-8'
    '.md'   = 'text/plain; charset=utf-8'
    '.txt'  = 'text/plain; charset=utf-8'
    '.pdf'  = 'application/pdf'
}

try {
    while ($l.IsListening) {
        $ctx = $l.GetContext()
        $path = $ctx.Request.Url.LocalPath
        if ($path -eq '/' -or $path -eq '') { $path = '/index.html' }
        $rel  = ($path.TrimStart('/') -replace '/', '\')
        $file = Join-Path $root $rel

        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $bytes = [System.IO.File]::ReadAllBytes($file)
            $ext = [System.IO.Path]::GetExtension($file).ToLower()
            if ($types.ContainsKey($ext)) { $ctx.Response.ContentType = $types[$ext] }
            else { $ctx.Response.ContentType = 'application/octet-stream' }
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $ctx.Response.StatusCode = 404
            $msg = [System.Text.Encoding]::UTF8.GetBytes('not found')
            $ctx.Response.OutputStream.Write($msg, 0, $msg.Length)
        }
        $ctx.Response.Close()
    }
} finally {
    $l.Stop()
}
