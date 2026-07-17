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
    "if\true.plan"       = 42
    "if\false.plan"      = 99
    "if\expr.plan"       = 42
    "if\nested.plan"     = 7
    "if\no_braces.plan"  = 55
    # loops
    "loops\while_simple.plan"     = 10
    "loops\while_break.plan"      = 5
    "loops\while_continue.plan"   = 9
    "loops\for_range.plan"        = 45
    "loops\for_simple.plan"       = 5
    # match
    "match\simple.plan"   = 20
    "match\wildcard.plan" = 42
    "match\enum.plan"     = 20
    # defer
    "defer\simple.plan"   = 11
    "defer\if.plan"       = 12
    "defer\while.plan"    = 5
    # enum
    "enum\values.plan"    = 3
    "enum\compare.plan"   = 1
    # fn
    "fn\no_args.plan"     = 5
    "fn\two_args.plan"    = 30
    "fn\first_arg.plan"   = 10
    "fn\nested_call.plan" = 5
    "fn\nested_add.plan"  = 30
    # recursion — `*` and recursion working
    "recursion\factorial.plan"  = 120
    "recursion\fibonacci.plan"  = 55
    # scope
    "scope\block.plan"    = 30
    # expr — `*` now supported
    "expr\arith.plan"     = 50
    "expr\sub.plan"       = 50
    # ref — `&var` (address-of)
    "ref\ampersand.plan"  = 99
    # plan — FSM / Plan backend
    "plan\basic.plan"     = 42
    "plan\chain.plan"     = 99
    "plan\on_event.plan"  = 77
    # mega — combined feature tests
    "mega\megatest_bitops.plan"    = 29
    "mega\megatest_shifts.plan"    = 2
    "mega\megatest_shifts2.plan"   = 8
    "mega\megatest_shifts3.plan"   = 16
    "mega\megatest_ifelse.plan"    = 42
    "mega\megatest_ifelse2.plan"   = 99
    "mega\megatest_while.plan"     = 45
    "mega\robot_fsm.plan"          = 111
    "mega\calc.plan"               = 15
    "mega\combined.plan"           = 95
}

# Stdin input for tests that need it (file path → string to pipe)
$piped_input = @{
    "plan\on_event.plan"  = "Go"
}

Write-Host "=== B+ Regression Tests ===" -ForegroundColor Cyan
Write-Host ""

Get-ChildItem -Path $TESTDIR -Recurse -Filter "*.plan" | ForEach-Object {
    $rel = $_.FullName.Substring($TESTDIR.Length + 1)
    $exe = $_.FullName -replace '\.plan$', '.exe'

    Write-Host -NoNewline "  $rel ... "

    # Compile & run in one step via bpc run
    $inputStr = $piped_input[$rel]
    if ($inputStr -ne $null) {
        $result = $inputStr | & $BPC run $_.FullName 2>&1
    } else {
        $result = & $BPC run $_.FullName 2>&1
    }
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
