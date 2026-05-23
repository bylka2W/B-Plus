@echo off
title B+ - Compile and Run

if "%1"=="" (
    echo Usage: run ^<file^>
    echo Example: run hello
    echo       or: run hello.bp
    exit /b 1
)

set "FILE=%1"
if not exist "%FILE%" (
    if exist "%FILE%.bp" (
        set "FILE=%FILE%.bp"
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