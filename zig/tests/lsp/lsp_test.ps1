param(
    [string]$Lsp = ""
)

$ErrorActionPreference = "Stop"

if ($Lsp -eq "") {
    $Lsp = Join-Path $PSScriptRoot "..\..\zig-out\bin\bplus-lsp.exe"
}
if (!(Test-Path $Lsp)) {
    Write-Error "bplus-lsp not found at $Lsp (run 'zig build' in zig/ first)"
}

function Get-FrameBytes([string]$body) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $header = "Content-Length: $($bytes.Length)`r`n`r`n"
    $h = [System.Text.Encoding]::ASCII.GetBytes($header)
    $ms = New-Object System.IO.MemoryStream
    $ms.Write($h, 0, $h.Length)
    $ms.Write($bytes, 0, $bytes.Length)
    return ,$ms.ToArray()
}

function Run-Session([byte[]]$payload, [string]$name, [string[]]$expect) {
    $bin = Join-Path $env:TEMP "lsp_$name.bin"
    [System.IO.File]::WriteAllBytes($bin, $payload)
    $out = & cmd /c "`"$Lsp`" < `"$bin`"" 2>&1 | Out-String
    Remove-Item $bin -ErrorAction SilentlyContinue
    $ok = $true
    foreach ($e in $expect) {
        if ($out -notmatch [regex]::Escape($e)) { $ok = $false }
    }
    return ,@($ok, $out)
}

$uri = "file:///C:/B-Plus/hello_LspTest.b+"

$good = @(
    (Get-FrameBytes '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'),
    (Get-FrameBytes '{"jsonrpc":"2.0","method":"initialized","params":{}}'),
    (Get-FrameBytes ('{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"' + $uri + '","languageId":"bplus","version":1,"text":"fn main() {\n var x:i32 = 42\n print(x)\n}\n"}}}')),
    (Get-FrameBytes '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'),
    (Get-FrameBytes '{"jsonrpc":"2.0","method":"exit","params":null}')
)
$msGood = New-Object System.IO.MemoryStream
foreach ($f in $good) { $msGood.Write($f, 0, $f.Length) }

$bad = @(
    (Get-FrameBytes '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'),
    (Get-FrameBytes '{"jsonrpc":"2.0","method":"initialized","params":{}}'),
    (Get-FrameBytes ('{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"' + $uri + '","languageId":"bplus","version":1,"text":"fn main() {\n var x:i32 = \"hello\"\n print(x)\n}\n"}}}')),
    (Get-FrameBytes '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'),
    (Get-FrameBytes '{"jsonrpc":"2.0","method":"exit","params":null}')
)
$msBad = New-Object System.IO.MemoryStream
foreach ($f in $bad) { $msBad.Write($f, 0, $f.Length) }

$pass = 0
$fail = 0

$r1 = Run-Session $msGood.ToArray() "good" @(
    '"serverInfo":{"name":"bplus-lsp"',
    'textDocument/publishDiagnostics'
)
if ($r1[0]) { $pass += 1; Write-Host "PASS lsp_clean" } else { $fail += 1; Write-Host "FAIL lsp_clean"; Write-Host $r1[1] }

$r2 = Run-Session $msBad.ToArray() "bad" @(
    'type mismatch: cannot assign',
    '"line":1'
)
if ($r2[0]) { $pass += 1; Write-Host "PASS lsp_diagnostics" } else { $fail += 1; Write-Host "FAIL lsp_diagnostics"; Write-Host $r2[1] }

Write-Host ""
Write-Host "lsp tests: $pass passed, $fail failed"
exit $(if ($fail -eq 0) { 0 } else { 1 })
