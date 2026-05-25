@echo off
title B+ - Transpile + Compile + Run

set "FILE=hello.bp"
if not "%1"=="" set "FILE=%1"
if not exist "%FILE%" (
    if exist "%FILE%.bp" (
        set "FILE=%FILE%.bp"
    ) else if exist "tests\%FILE%" (
        set "FILE=tests\%FILE%"
    ) else if exist "tests\%FILE%.bp" (
        set "FILE=tests\%FILE%.bp"
    ) else (
        echo File not found: %FILE% ^(or %FILE%.bp^)
        exit /b 1
    )
)

echo Compiling %FILE%...
dotnet run --project src/BPlusTranspiler "%FILE%"
if %ERRORLEVEL% neq 0 (
    echo Compilation failed
    exit /b %ERRORLEVEL%
)
echo Done.

call compile