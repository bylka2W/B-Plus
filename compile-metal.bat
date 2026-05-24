@echo off
title B+ - Compile Metal Stack (LLVM)
setlocal enabledelayedexpansion

set "GEN_DIR=gen_metal"
set "LLVM_DIR=%USERPROFILE%\.bplus\llvm"

if not exist "%GEN_DIR%\kernels_metal.ll" (
    echo No generated .ll found. Run: dotnet run --project src\BPlusTranspiler -- hello.bp --metal --tier=L0
    exit /b 1
)

:: --- Check for llc ---
where llc >nul 2>&1
if %ERRORLEVEL% neq 0 (
    if not exist "%LLVM_DIR%\bin\llc.exe" (
        echo LLVM not found. Downloading portable LLVM...
        if not exist "%USERPROFILE%\.bplus" mkdir "%USERPROFILE%\.bplus"
        powershell -Command "Invoke-WebRequest -Uri 'https://github.com/vovkos/llvm-package-windows/releases/download/llvm-21.1.1/LLVM-21.1.1-win64.zip' -OutFile '%TEMP%\llvm.zip'"
        echo Extracting llc.exe...
        powershell -Command "Expand-Archive -Path '%TEMP%\llvm.zip' -DestinationPath '%TEMP%\llvm-extract' -Force"
        move /Y "%TEMP%\llvm-extract\*\bin\llc.exe" "%LLVM_DIR%\bin\llc.exe"
        rmdir /s /q "%TEMP%\llvm-extract"
        del "%TEMP%\llvm.zip"
    )
    set "PATH=%LLVM_DIR%\bin;%PATH%"
)

:: --- Validate llc ---
where llc >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Error: llc not available.
    exit /b 1
)

:: --- Compile .ll to .obj ---
echo Compiling %GEN_DIR%\kernels_metal.ll...
llc -filetype=obj "%GEN_DIR%\kernels_metal.ll" -o "%GEN_DIR%\kernels_metal.obj"
if %ERRORLEVEL% neq 0 (
    echo LLVM compilation failed.
    exit /b %ERRORLEVEL%
)
echo Object file: %GEN_DIR%\kernels_metal.obj
echo Done.