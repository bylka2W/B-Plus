@echo off
title B+ - One Click
if "%1"=="" (set "FILE=hello") else (set "FILE=%1")
call run "%FILE%" && call compile
