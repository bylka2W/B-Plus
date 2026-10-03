<#
    Copies the freshly built B+ compiler into the extension so the published
    .vsix always ships a working bpc.exe.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File ./scripts/sync-compiler.ps1
        powershell ... -File ./scripts/sync-compiler.ps1 -Bpc "D:\some\bpc.exe"
#>
param(
    [string]$Bpc = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

if ($Bpc -eq "") {
    $candidates = @(
        (Join-Path $root "..\zig\zig-out\bin\bpc.exe"),
        "C:\B-Plus\zig\zig-out\bin\bpc.exe",
        "D:\B-Plus\zig\zig-out\bin\bpc.exe"
    )
    $Bpc = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

if (-not $Bpc -or -not (Test-Path -LiteralPath $Bpc)) {
    Write-Host "sync-compiler: bpc.exe not found. Build it first:  cd zig; zig build" -ForegroundColor Red
    exit 1
}

# Smoke test: a broken compiler must never be bundled.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("bpc-sync-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $hello = Join-Path $tmp "probe.b+"
    Set-Content -LiteralPath $hello -Value "fn main()`n{`n    print(1)`n}`n" -NoNewline -Encoding utf8
    & $Bpc run $hello *> (Join-Path $tmp "out.txt")
    if ($LASTEXITCODE -ne 0) {
        Write-Host "sync-compiler: $Bpc cannot compile a hello-world (exit $LASTEXITCODE). Not bundling." -ForegroundColor Red
        Get-Content -LiteralPath (Join-Path $tmp "out.txt") | Select-Object -First 10
        exit 1
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$dest = Join-Path $root "bin\bpc.exe"
New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
Copy-Item -LiteralPath $Bpc -Destination $dest -Force
$dbg = Join-Path $root "bin\bpc.pdb"
if (Test-Path -LiteralPath $dbg) { Remove-Item -LiteralPath $dbg -Force -ErrorAction SilentlyContinue }

$size = [math]::Round((Get-Item -LiteralPath $dest).Length / 1MB, 2)
Write-Host "sync-compiler: bundled $dest ($size MB) from $Bpc" -ForegroundColor Green
