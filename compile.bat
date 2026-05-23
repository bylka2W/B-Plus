@echo off
title B+ - Compile Generated C++

setlocal

call "%ProgramFiles%\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1

set "GEN_DIR=gen"

if not exist "%GEN_DIR%\kernels.cpp" (
    echo No generated files found. Run 'run hello' first.
    exit /b 1
)

echo Compiling generated C++...

cl /nologo /O2 /EHsc /std:c++17 /Fe:bplus_output.exe ^
    %GEN_DIR%\kernels.cpp %GEN_DIR%\states.cpp 2>&1

if %ERRORLEVEL% neq 0 (
    echo Compilation failed
    exit /b %ERRORLEVEL%
)

echo Running...
echo.
bplus_output.exe
echo.
echo Exit code: %ERRORLEVEL%
