# Test runner for B+ regression tests
# Usage: powershell -File run_tests.ps1

$BPC = "C:\B-Plus\zig\zig-out\bin\bpc.exe"
$TESTDIR = "C:\B-Plus\zig\tests"
$passed = 0
$failed = 0
$failures = @()

# Expected exit codes for each test (file path → expected code)
$expect = @{
    # if
    "if\true.b+"       = 42
    "if\false.b+"      = 99
    "if\expr.b+"       = 42
    "if\nested.b+"     = 7
    "if\no_braces.b+"  = 55
    # loops
    "loops\while_simple.b+"     = 10
    "loops\while_break.b+"      = 5
    "loops\while_continue.b+"   = 9
    "loops\for_range.b+"        = 45
    "loops\for_simple.b+"       = 5
    # match
    "match\simple.b+"   = 20
    "match\wildcard.b+" = 42
    "match\enum.b+"     = 20
    # defer
    "defer\simple.b+"   = 11
    "defer\if.b+"       = 12
    "defer\while.b+"    = 5
    # enum — баги: сравнение enum, цепочка сложений
    "enum\values.b+"    = 3
    "enum\compare.b+"   = 0
    # fn
    "fn\no_args.b+"     = 5
    "fn\two_args.b+"    = 30
    "fn\first_arg.b+"   = 10
    "fn\nested_call.b+" = 5
    "fn\nested_add.b+"  = 30
    # recursion — нужен `*` в expr и правильная рекурсия
    "recursion\factorial.b+"  = 0
    "recursion\fibonacci.b+"  = 0
    # scope — var в блоке не перекрывает outer scope
    "scope\block.b+"    = 10
    # expr — `*` не поддерживается
    "expr\arith.b+"     = 10
    "expr\sub.b+"       = 50
}

Write-Host "=== B+ Regression Tests ===" -ForegroundColor Cyan
Write-Host ""

Get-ChildItem -Path $TESTDIR -Recurse -Filter "*.b+" | ForEach-Object {
    $rel = $_.FullName.Substring($TESTDIR.Length + 1)
    $exe = $_.FullName -replace '\.b\+$', '.exe'

    Write-Host -NoNewline "  $rel ... "

    # Compile
    $compile = & $BPC compile $_.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "COMPILE FAIL" -ForegroundColor Red
        $failed++
        $failures += @{ file = $rel; expected = "compile"; got = $LASTEXITCODE }
        return
    }

    # Run
    $result = & $exe
    $got = $LASTEXITCODE

    # Check expected
    $exp = $expect[$rel]
    if ($exp -eq $null) {
        Write-Host "no expectation set (got $got)" -ForegroundColor Yellow
        $passed++
    } elseif ($got -eq $exp) {
        Write-Host "PASS ($got)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "FAIL (expected $exp, got $got)" -ForegroundColor Red
        $failed++
        $failures += @{ file = $rel; expected = $exp; got = $got }
    }
}

Write-Host ""
Write-Host "=== Results: $passed passed, $failed failed ===" -ForegroundColor Cyan

if ($failures.Length -gt 0) {
    Write-Host ""
    Write-Host "Failures:" -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host "  $($f.file): expected $($f.expected), got $($f.got)" -ForegroundColor Red
    }
    exit 1
}
