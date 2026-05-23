@echo off
title B+ v4.0.0

echo B+ v4.0.0

dotnet build src/BPlusTranspiler >nul 2>&1
dotnet build src/vs-extension/BPlusLanguage -c Release >nul 2>&1

set "VSIX=%cd%\src\vs-extension\BPlusLanguage\bin\Release\BPlusLanguage.vsix"

if exist "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\VSIXInstaller.exe" (
    "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\VSIXInstaller.exe" /quiet "%VSIX%" >nul 2>&1
)

start devenv
exit