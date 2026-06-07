@echo off
setlocal enabledelayedexpansion
set "ARGS=%*"
echo %ARGS% | findstr /i "\-\-target x64 \-\-target windows \-\-target linux \-\-target elf" >nul
if %ERRORLEVEL% equ 0 (
    :: x64/PE targets — use CLI project with force rebuild
    dotnet build --force -c Release "%~dp0src\BPlus.Cli" >nul 2>&1
    if %ERRORLEVEL% neq 0 (
        echo CLI build failed.
        exit /b %ERRORLEVEL%
    )
    dotnet run --project "%~dp0src\BPlus.Cli" -c Release -- %*
    exit /b %ERRORLEVEL%
)
set "BPC=%~dp0bpc.exe"
if exist "%BPC%" (
    "%BPC%" %*
) else (
    dotnet run --project "%~dp0src\BPlusTranspiler" -- %*
)
