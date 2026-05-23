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

if not exist "hello.bp" (
    echo state Hello { > hello.bp
    echo     on start -^> World >> hello.bp
    echo     enter { print("b+ v4.0.0") } >> hello.bp
    echo } >> hello.bp
)

start devenv hello.bp
exit