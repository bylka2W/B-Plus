@echo off
title B+ - Create new file

if "%1"=="" (
    set "FILE=hello.bp"
) else (
    set "FILE=%1"
)

echo entry main() > "%FILE%"
echo     print("Hello from B+!") >> "%FILE%"
echo     return 0 >> "%FILE%"

echo Created %FILE%
echo Run: run %FILE%