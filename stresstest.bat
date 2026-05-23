@echo off
title B+ - Multi-core CPU Stress Test

call "%ProgramFiles%\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1

echo Compiling multi-core stress test...
cl /nologo /O2 /EHsc /std:c++17 /Fe:cpu_stress.exe tools\stress.cpp 2>&1
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

echo Running - press Enter to stop...
cpu_stress.exe
