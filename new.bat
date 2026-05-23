@echo off
title B+ - Create new file

if "%1"=="" (
    set "FILE=hello.bp"
) else (
    set "FILE=%1"
)

echo kernel main { > "%FILE%"
echo     entry() { >> "%FILE%"
echo         print("Hello from B+!"); >> "%FILE%"
echo         return 0; >> "%FILE%"
echo     } >> "%FILE%"
echo } >> "%FILE%"

echo Created %FILE%
echo Run: bplus %FILE%