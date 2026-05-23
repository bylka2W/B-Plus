@echo off
title B+ v4.0.0 — Visual Studio

echo B+ v4.0.0

dotnet build src/BPlusTranspiler >nul 2>&1
dotnet build src/vs-extension/BPlusLanguage -c Release >nul 2>&1

set "VSIX=src\vs-extension\BPlusLanguage\bin\Release\BPlusLanguage.vsix"
set "VSIXINSTALL=C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\VSIXInstaller.exe"

if exist "%VSIXINSTALL%" (
    "%VSIXINSTALL%" /quiet "%VSIX%" >nul 2>&1
)

start devenv

exit