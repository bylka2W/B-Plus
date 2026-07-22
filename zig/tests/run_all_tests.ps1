# B+ Comprehensive Test Runner
# Runs: parser fuzz, symbol resolution, recursion, overflow, memory, struct, expression, stress tests
# Usage: powershell -File run_all_tests.ps1 [-Fuzz] [-Stress] [-SkipBuild]

param(
    [switch]$Fuzz,
    [switch]$Stress,
    [switch]$SkipBuild,
    [int]$FuzzCount = 1000,
    [int]$FuzzSeed = 42
)

$BPC = "C:\B-Plus\zig\bpc.exe"
$TESTDIR = "C:\B-Plus\zig\tests"

if (-not (Test-Path $BPC)) {
    $BPC = "C:\B-Plus\zig\zig-out\bin\bpc.exe"
}

$passed = 0
$failed = 0
$skipped = 0
$crashes = 0
$failures = @()

Write-Host "=== B+ Comprehensive Test Suite ===" -ForegroundColor Cyan
Write-Host "BPC: $BPC" -ForegroundColor Gray
Write-Host ""

if (-not (Test-Path $BPC)) {
    Write-Host "ERROR: bpc.exe not found at $BPC" -ForegroundColor Red
    exit 1
}

# ============================================================
# Category 1: Parser Fuzz Tests — expect no crash, expect error
# ============================================================
Write-Host "--- Parser Fuzz Tests ---" -ForegroundColor Yellow

$parserTests = Get-ChildItem -Path "$TESTDIR\fuzz\parser" -Filter "*.b+" -ErrorAction SilentlyContinue

foreach ($test in $parserTests) {
    $name = $test.Name
    Write-Host -NoNewline "  $name ... "

    # These should NOT crash. They may produce errors (expected).
    try {
        $result = & $BPC run $test.FullName 2>&1
        $exit = $LASTEXITCODE
        # Parser errors are expected (exit 1). Crash = exit code like -1073741819, or timeout.
        if ($exit -eq -1073741819 -or $exit -eq -1073741818 -or $exit -eq -1073741815 -or
            $exit -eq -1073741816 -or $exit -eq -1073740771 -or $exit -eq 3221225477) {
            Write-Host "CRASH (exit=$exit)" -ForegroundColor Red
            $crashes++
            $failures += @{ cat = "parser_fuzz"; file = $name; issue = "crash exit=$exit" }
        } elseif ($exit -lt 0 -and $exit -ne 1) {
            Write-Host "ABNORMAL EXIT ($exit)" -ForegroundColor Red
            $failures += @{ cat = "parser_fuzz"; file = $name; issue = "exit=$exit" }
            $failed++
        } else {
            Write-Host "OK (exit=$exit, no crash)" -ForegroundColor Green
            $passed++
        }
    } catch {
        Write-Host "EXCEPTION: $_" -ForegroundColor Red
        $crashes++
        $failures += @{ cat = "parser_fuzz"; file = $name; issue = "exception: $_" }
    }
}

Write-Host ""

# ============================================================
# Category 2: Symbol Resolution Tests
# ============================================================
Write-Host "--- Symbol Resolution Tests ---" -ForegroundColor Yellow

$symbolTests = Get-ChildItem -Path "$TESTDIR\fuzz\symbols" -Filter "*.b+" -ErrorAction SilentlyContinue

foreach ($test in $symbolTests) {
    $name = $test.Name
    Write-Host -NoNewline "  $name ... "

    try {
        $result = & $BPC run $test.FullName 2>&1
        $exit = $LASTEXITCODE
        $output = $result -join "`n"

        if ($exit -eq -1073741819 -or $exit -eq -1073741818 -or $exit -eq -1073741815 -or
            $exit -eq 3221225477) {
            Write-Host "CRASH (exit=$exit)" -ForegroundColor Red
            $crashes++
            $failures += @{ cat = "symbol_resolution"; file = $name; issue = "crash" }
        } else {
            Write-Host "OK (exit=$exit, no crash)" -ForegroundColor Green
            $passed++
        }
    } catch {
        Write-Host "EXCEPTION: $_" -ForegroundColor Red
        $crashes++
        $failures += @{ cat = "symbol_resolution"; file = $name; issue = "exception" }
    }
}

Write-Host ""

# ============================================================
# Category 3: Recursion Tests
# ============================================================
Write-Host "--- Recursion Tests ---" -ForegroundColor Yellow

$recursionTests = Get-ChildItem -Path "$TESTDIR\fuzz\recursion" -Filter "*.b+" -ErrorAction SilentlyContinue

foreach ($test in $recursionTests) {
    $name = $test.Name
    Write-Host -NoNewline "  $name ... "

    try {
        $result = & $BPC run $test.FullName 2>&1
        $exit = $LASTEXITCODE
        if ($exit -eq -1073741819 -or $exit -eq 3221225477) {
            Write-Host "CRASH" -ForegroundColor Red
            $crashes++
            $failures += @{ cat = "recursion"; file = $name; issue = "crash" }
        } else {
            Write-Host "OK (exit=$exit)" -ForegroundColor Green
            $passed++
        }
    } catch {
        Write-Host "EXCEPTION: $_" -ForegroundColor Red
        $crashes++
        $failures += @{ cat = "recursion"; file = $name; issue = "exception" }
    }
}

Write-Host ""

# ============================================================
# Category 4: Overflow Tests
# ============================================================
Write-Host "--- Integer Overflow Tests ---" -ForegroundColor Yellow

$overflowTests = Get-ChildItem -Path "$TESTDIR\fuzz\overflow" -Filter "*.b+" -ErrorAction SilentlyContinue

foreach ($test in $overflowTests) {
    $name = $test.Name
    Write-Host -NoNewline "  $name ... "

    try {
        $result = & $BPC run $test.FullName 2>&1
        $exit = $LASTEXITCODE
        if ($exit -eq -1073741819 -or $exit -eq 3221225477) {
            Write-Host "CRASH" -ForegroundColor Red
            $crashes++
            $failures += @{ cat = "overflow"; file = $name; issue = "crash" }
        } else {
            Write-Host "OK (exit=$exit)" -ForegroundColor Green
            $passed++
        }
    } catch {
        Write-Host "EXCEPTION: $_" -ForegroundColor Red
        $crashes++
        $failures += @{ cat = "overflow"; file = $name; issue = "exception" }
    }
}

Write-Host ""

# ============================================================
# Category 5: Memory Tests
# ============================================================
Write-Host "--- Memory Corruption Tests ---" -ForegroundColor Yellow

$memoryTests = Get-ChildItem -Path "$TESTDIR\fuzz\memory" -Filter "*.b+" -ErrorAction SilentlyContinue

foreach ($test in $memoryTests) {
    $name = $test.Name
    Write-Host -NoNewline "  $name ... "

    try {
        $result = & $BPC run $test.FullName 2>&1
        $exit = $LASTEXITCODE
        if ($exit -eq -1073741819 -or $exit -eq 3221225477) {
            Write-Host "CRASH" -ForegroundColor Red
            $crashes++
            $failures += @{ cat = "memory"; file = $name; issue = "crash" }
        } else {
            Write-Host "OK (exit=$exit)" -ForegroundColor Green
            $passed++
        }
    } catch {
        Write-Host "EXCEPTION: $_" -ForegroundColor Red
        $crashes++
        $failures += @{ cat = "memory"; file = $name; issue = "exception" }
    }
}

Write-Host ""

# ============================================================
# Category 6: Struct & Enum Tests
# ============================================================
Write-Host "--- Struct & Enum Tests ---" -ForegroundColor Yellow

$structTests = Get-ChildItem -Path "$TESTDIR\fuzz\struct" -Filter "*.b+" -ErrorAction SilentlyContinue

foreach ($test in $structTests) {
    $name = $test.Name
    Write-Host -NoNewline "  $name ... "

    try {
        $result = & $BPC run $test.FullName 2>&1
        $exit = $LASTEXITCODE
        if ($exit -eq -1073741819 -or $exit -eq 3221225477) {
            Write-Host "CRASH" -ForegroundColor Red
            $crashes++
            $failures += @{ cat = "struct_enum"; file = $name; issue = "crash" }
        } else {
            Write-Host "OK (exit=$exit)" -ForegroundColor Green
            $passed++
        }
    } catch {
        Write-Host "EXCEPTION: $_" -ForegroundColor Red
        $crashes++
        $failures += @{ cat = "struct_enum"; file = $name; issue = "exception" }
    }
}

Write-Host ""

# ============================================================
# Category 7: Expression Tests
# ============================================================
Write-Host "--- Expression Tests ---" -ForegroundColor Yellow

$exprTests = Get-ChildItem -Path "$TESTDIR\fuzz\expressions" -Filter "*.b+" -ErrorAction SilentlyContinue

foreach ($test in $exprTests) {
    $name = $test.Name
    Write-Host -NoNewline "  $name ... "

    try {
        $result = & $BPC run $test.FullName 2>&1
        $exit = $LASTEXITCODE
        if ($exit -eq -1073741819 -or $exit -eq 3221225477) {
            Write-Host "CRASH" -ForegroundColor Red
            $crashes++
            $failures += @{ cat = "expression"; file = $name; issue = "crash" }
        } else {
            Write-Host "OK (exit=$exit)" -ForegroundColor Green
            $passed++
        }
    } catch {
        Write-Host "EXCEPTION: $_" -ForegroundColor Red
        $crashes++
        $failures += @{ cat = "expression"; file = $name; issue = "exception" }
    }
}

Write-Host ""

# ============================================================
# Category 8: Stress Tests (generated)
# ============================================================
if ($Stress) {
    Write-Host "--- Stress Tests ---" -ForegroundColor Yellow

    $stressTests = Get-ChildItem -Path "$TESTDIR\stress\generated" -Filter "*.b+" -ErrorAction SilentlyContinue | Sort-Object Length

    foreach ($test in $stressTests) {
        $name = $test.Name
        $size = [math]::Round($test.Length / 1024, 1)
        Write-Host -NoNewline "  $name (${size}KB) ... "

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $result = & $BPC run $test.FullName 2>&1
            $exit = $LASTEXITCODE
            $sw.Stop()

            if ($exit -eq -1073741819 -or $exit -eq 3221225477) {
                Write-Host "CRASH ($($sw.ElapsedMilliseconds)ms)" -ForegroundColor Red
                $crashes++
                $failures += @{ cat = "stress"; file = $name; issue = "crash" }
            } else {
                Write-Host "OK (exit=$exit, $($sw.ElapsedMilliseconds)ms)" -ForegroundColor Green
                $passed++
            }
        } catch {
            $sw.Stop()
            Write-Host "EXCEPTION ($($sw.ElapsedMilliseconds)ms)" -ForegroundColor Red
            $crashes++
            $failures += @{ cat = "stress"; file = $name; issue = "exception" }
        }
    }
    Write-Host ""
}

# ============================================================
# Category 9: Fuzz Tests
# ============================================================
if ($Fuzz) {
    Write-Host "--- Fuzz Tests ($FuzzCount tests, seed=$FuzzSeed) ---" -ForegroundColor Yellow

    $fuzzer = "$TESTDIR\fuzz\fuzzer.py"
    if (Test-Path $fuzzer) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & python $fuzzer $FuzzSeed $FuzzCount
        $sw.Stop()
        Write-Host "  Fuzzer completed in $($sw.ElapsedMilliseconds)ms" -ForegroundColor Gray

        # Check report
        $reportPath = "$TESTDIR\..\fuzz_report.json"
        if (Test-Path $reportPath) {
            $report = Get-Content $reportPath | ConvertFrom-Json
            $crashes += $report.crashes.Count
            if ($report.crashes.Count -gt 0) {
                foreach ($c in $report.crashes) {
                    Write-Host "  FUZZ CRASH #$($c.id): $($c.detail)" -ForegroundColor Red
                    $failures += @{ cat = "fuzz"; file = "test_$($c.id)"; issue = $c.detail }
                }
            }
        }
    } else {
        Write-Host "  fuzzer.py not found, skipping" -ForegroundColor Gray
    }
    Write-Host ""
}

# ============================================================
# Category 10: Regression Tests
# ============================================================
Write-Host "--- Regression Tests ---" -ForegroundColor Yellow

$regressionTests = Get-ChildItem -Path "$TESTDIR\regressions" -Filter "*.b+" -ErrorAction SilentlyContinue

if ($regressionTests.Count -eq 0) {
    Write-Host "  (no regression tests yet)" -ForegroundColor Gray
} else {
    foreach ($test in $regressionTests) {
        $name = $test.Name
        Write-Host -NoNewline "  $name ... "

        try {
            $result = & $BPC run $test.FullName 2>&1
            $exit = $LASTEXITCODE
            if ($exit -eq -1073741819 -or $exit -eq 3221225477) {
                Write-Host "REGRESSION CRASH" -ForegroundColor Red
                $crashes++
                $failures += @{ cat = "regression"; file = $name; issue = "regression crash" }
            } else {
                Write-Host "OK (exit=$exit)" -ForegroundColor Green
                $passed++
            }
        } catch {
            Write-Host "EXCEPTION: $_" -ForegroundColor Red
            $crashes++
            $failures += @{ cat = "regression"; file = $name; issue = "exception" }
        }
    }
}

Write-Host ""

# ============================================================
# Summary
# ============================================================
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed:  $passed" -ForegroundColor Green
Write-Host "  Failed:  $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Gray" })
Write-Host "  Crashes: $crashes" -ForegroundColor $(if ($crashes -gt 0) { "Red" } else { "Gray" })

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Failures:" -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host "  [$($f.cat)] $($f.file): $($f.issue)" -ForegroundColor Red
    }
}

if ($crashes -gt 0) {
    exit 2
} elseif ($failed -gt 0) {
    exit 1
} else {
    Write-Host ""
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
}
