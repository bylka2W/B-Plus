@echo off
echo B+ Transpiler v3.0.4L BETA
echo.

if "%1"=="" (
    echo Usage: run.bat examples\traffic_light.bp [--aot]
    echo    or: drag .bp file onto this batch file
    pause
    exit /b
)

set SELF_EXE=release\win-x64\bpc.exe
if exist "%SELF_EXE%" (
    echo Using self-contained binary: %SELF_EXE%
    "%SELF_EXE%" %*
) else (
    echo Using dotnet run (self-contained binary not found)
    echo Build with: publish.bat --aot
    dotnet run --project src/BPlusTranspiler -- %*
)
pause