@echo off
title B+ - Install

echo Setting up B+ v4.0.0...

:: 1. Build transpiler
dotnet build src/BPlusTranspiler -c Release >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Build failed. Install .NET 8 SDK first.
    pause
    exit /b 1
)

:: 2. Add alias bpc.bat in project root
echo @echo off > bpc.bat
echo dotnet run --project "%%~dp0src\BPlusTranspiler" -- %%* >> bpc.bat
echo Done. Use: bpc input.bp

:: 3. Install VS extension
call bplus.bat

echo.
echo === B+ v4.0.0 installed ===
echo.
echo Usage:
echo   bpc input.bp          - transpile
echo   bpc input.bp --metal  - metal mode
echo   new                    - create hello.bp
echo   run                    - transpile + compile + run
echo.
pause
