@echo off
cd /d "%~dp0"
bpc.exe %*
if errorlevel 1 pause
