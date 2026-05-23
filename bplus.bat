@echo off
title B+ v4.0.0

echo B+ v4.0.0

dotnet build src/BPlusTranspiler >nul 2>&1
dotnet build src/vs-extension/BPlusLanguage -c Release >nul 2>&1

powershell -ExecutionPolicy Bypass -File src/vs-extension/build-vsix.ps1 >nul 2>&1

if exist "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\VSIXInstaller.exe" (
    start /wait "" "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\VSIXInstaller.exe" "%cd%\BPlusLanguage.vsix"
)

start devenv
exit