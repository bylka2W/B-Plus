@echo off
chcp 65001 >nul
title B+ VS Code Extension Installer v2.5.0GH

echo ╔════════════════════════════════════════╗
echo ║   B+ v2.5.0GH — VS Code Installer     ║
echo ╚════════════════════════════════════════╝
echo.

REM Check for PowerShell
where powershell >nul 2>&1
if %errorlevel% neq 0 (
    echo ✗ PowerShell not found. Please install VS Code extension manually:
    echo   cd src\BPlusTranspiler
    echo   dotnet run -- --install-lsp
    pause
    exit /b 1
)

REM Check for dotnet
where dotnet >nul 2>&1
if %errorlevel% neq 0 (
    echo ✗ .NET SDK not found. Install from https://dotnet.microsoft.com/download
    pause
    exit /b 1
)

REM Run PowerShell installer
echo → Starting installation...
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0setup-vscode.ps1"

if %errorlevel% equ 0 (
    echo.
    echo ✓ Installation complete!
) else (
    echo.
    echo ✗ Installation encountered issues.
)

pause
