@echo off
title B+ - Compile Metal Stack (LLVM)
setlocal enabledelayedexpansion

set "GEN_DIR=gen"
set "LLVM_DIR=%USERPROFILE%\.bplus\llvm"

if not exist "%GEN_DIR%\kernels.ll" (
    echo No generated .ll found. Run 'run <file>' first.
    exit /b 1
)

:: --- Check for llc ---
where llc >nul 2>&1
if %ERRORLEVEL% neq 0 (
    if not exist "%LLVM_DIR%\bin\llc.exe" (
        echo LLVM not found. Downloading portable LLVM (llc.exe)...
        if not exist "%USERPROFILE%\.bplus" mkdir "%USERPROFILE%\.bplus"
        :: Download LLVM prebuilt for Windows - we only extract llc.exe + LTO.dll
        curl -sL -o "%TEMP%\llvm.zip" "https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/LLVM-18.1.8-Windows-X64.zip"
        if !ERRORLEVEL! neq 0 (
            echo Download failed. Install LLVM manually: https://github.com/llvm/llvm-project/releases
            exit /b 1
        )
        echo Extracting llc.exe...
        powershell -Command "& {Add-Type -A 'System.IO.Compression.FileSystem'; [IO.Compression.ZipFile]::ExtractToDirectory('%TEMP%\llvm.zip', '%TEMP%\llvm-extract'); Move-Item '%TEMP%\llvm-extract\LLVM-18.1.8-Windows-X64\bin\llc.exe' '%LLVM_DIR%\bin\llc.exe'; Move-Item '%TEMP%\llvm-extract\LLVM-18.1.8-Windows-X64\bin\LTO.dll' '%LLVM_DIR%\bin\LTO.dll'; Remove-Item '%TEMP%\llvm-extract' -Recurse -Force; Remove-Item '%TEMP%\llvm.zip' -Force}"
    )
    set "PATH=%LLVM_DIR%\bin;%PATH%"
)

:: --- Validate llc ---
where llc >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Error: llc not available after download attempt.
    exit /b 1
)

:: --- Find MSVC link.exe ---
call "%ProgramFiles%\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if %ERRORLEVEL% neq 0 (
    call "%ProgramFiles%\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
)

where link >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Warning: link.exe not found. Will skip linking step.
    echo Install VS with "Desktop development with C++" for linking.
    set "SKIP_LINK=1"
)

:: --- Compile .ll to .obj ---
echo Compiling %GEN_DIR%\kernels.ll...
llc -filetype=obj "%GEN_DIR%\kernels.ll" -o "%GEN_DIR%\kernels_metal.obj"
if %ERRORLEVEL% neq 0 (
    echo LLVM compilation failed.
    exit /b %ERRORLEVEL%
)
echo Object file: %GEN_DIR%\kernels_metal.obj

:: --- Link to .exe ---
if "%SKIP_LINK%"=="" (
    echo Linking bplus_metal_output.exe...
    link "%GEN_DIR%\kernels_metal.obj" /OUT:bplus_metal_output.exe /NOLOGO
    if !ERRORLEVEL! neq 0 (
        echo Linking failed.
        exit /b !ERRORLEVEL!
    )
    echo.
    echo Running bplus_metal_output.exe...
    echo.
    bplus_metal_output.exe
    echo.
    echo Exit code: !ERRORLEVEL!
) else (
    echo.
    echo Skipped. Only .obj was produced.
)

echo Done.
