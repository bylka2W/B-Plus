@echo off
title B+ - Compile and Run

if "%1"=="" (
    echo Usage: run ^<file.bp^>
    echo Example: run hello.bp
    exit /b 1
)

set "FILE=%1"
if not exist "%FILE%" (
    echo File not found: %FILE%
    exit /b 1
)

echo Compiling %FILE%...
dotnet run --project src/BPlusTranspiler "%FILE%"
if %ERRORLEVEL% neq 0 (
    echo Compilation failed
    exit /b %ERRORLEVEL%
)
echo Done.