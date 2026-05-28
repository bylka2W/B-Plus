@echo off
setlocal enabledelayedexpansion
set ZIG=C:\tools\zig\zig-windows-x86_64-0.14.0\zig.exe
set BPC=C:\B+ v1.0\bpc.exe

set PASS=0
set FAIL=0

for /l %%i in (1,1,25) do (
    set "FILE=C:\B+ v1.0\stress\syntax\t0%%i.bp"
    if %%i geq 10 set "FILE=C:\B+ v1.0\stress\syntax\t%%i.bp"
    if %%i geq 100 set "FILE=C:\B+ v1.0\stress\syntax\t%%i.bp"
    
    if %%i lss 10 (
        set "FP=C:\B+ v1.0\stress\syntax\t00%%i.bp"
    ) else (
        set "FP=C:\B+ v1.0\stress\syntax\t0%%i.bp"
    )
    if %%i geq 100 set "FP=C:\B+ v1.0\stress\syntax\t%%i.bp"
    
    rem Fix for simpler naming
    set "NUM=%%i"
    if %%i lss 10 set "NUM=0%%i"
    
    %BPC% stress\syntax\t%NUM%.bp >nul 2>&1
    if !ERRORLEVEL! neq 0 (
        echo FAIL t%NUM%: bpc
        set /a FAIL+=1
    ) else (
        %ZIG% build-exe output.zig --name out --cache-dir src\zig-bpc\zig-cache --global-cache-dir src\zig-bpc\zig-global-cache >nul 2>&1
        if !ERRORLEVEL! neq 0 (
            echo FAIL t%NUM%: zig compile
            set /a FAIL+=1
        ) else (
            echo PASS t%NUM%
            set /a PASS+=1
        )
    )
)

echo.
echo %PASS%/25 passed, %FAIL% failed
if %FAIL% gtr 0 exit /b 1
