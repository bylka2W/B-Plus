param(
    [string]$Bpc = ""
)

$ErrorActionPreference = "Stop"

if ($Bpc -eq "") {
    $Bpc = Join-Path $PSScriptRoot "..\..\zig-out\bin\bpc.exe"
}
if (!(Test-Path $Bpc)) {
    Write-Error "bpc not found at $Bpc (run 'zig build' in zig/ first)"
}

$tests = @(
    @{ file = "hello_plan.b+";  exit = 0;  out = "Hello World!" },
    @{ file = "hello_metal.b+"; exit = 0;  out = "Hello World!" },
    @{ file = "return_0.b+";    exit = 0;  out = $null },
    @{ file = "return_42.b+";   exit = 42; out = $null },
    @{ file = "print.b+";       exit = 0;  out = "count=" }
)

$pass = 0
$fail = 0
foreach ($t in $tests) {
    $path = Join-Path $PSScriptRoot $t.file
    $out = & $Bpc run $path 2>&1
    $code = $LASTEXITCODE
    $ok = ($code -eq $t.exit)
    if ($null -ne $t.out) {
        $joined = ($out -join "`n")
        $ok = $ok -and ($joined -match [regex]::Escape($t.out))
    }
    if ($ok) {
        $pass += 1
        Write-Host "PASS $($t.file)"
    } else {
        $fail += 1
        Write-Host "FAIL $($t.file) (exit=$code, expected exit=$($t.exit))"
    }
}

Write-Host ""
Write-Host "runtime tests: $pass passed, $fail failed"
exit $(if ($fail -eq 0) { 0 } else { 1 })
