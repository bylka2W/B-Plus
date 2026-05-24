@echo off
title B+ - Compile Metal Stack (LLVM → .exe)
setlocal enabledelayedexpansion

set "GEN_DIR=gen"
set "LLVM_DIR=%USERPROFILE%\.bplus\llvm"

if not exist "%GEN_DIR%\kernels.ll" (
    if not exist "%GEN_DIR%\kernels_metal.ll" (
        echo No .ll found. Run: dotnet run --project src\BPlusTranspiler -- hello.bp
        exit /b 1
    )
    set "LL_FILE=%GEN_DIR%\kernels_metal.ll"
) else (
    set "LL_FILE=%GEN_DIR%\kernels.ll"
)

:: --- Ensure llc + lld-link are available ---
where llc >nul 2>&1
if %ERRORLEVEL% neq 0 (
    if not exist "%LLVM_DIR%\bin\llc.exe" (
        echo LLVM not found. Downloading portable LLVM (llc + lld-link)...
        if not exist "%USERPROFILE%\.bplus" mkdir "%USERPROFILE%\.bplus"
        if not exist "%LLVM_DIR%" mkdir "%LLVM_DIR%"
        if not exist "%LLVM_DIR%\bin" mkdir "%LLVM_DIR%\bin"
        curl.exe -sL -o "%TEMP%\llvm.7z" "https://github.com/vovkos/llvm-package-windows/releases/download/llvm-21.1.1/llvm-21.1.1-windows-amd64-msvc17-msvcrt.7z"
        if !ERRORLEVEL! neq 0 (
            echo Download failed.
            exit /b 1
        )
        echo Extracting llc + lld-link...
        :: Try 7-Zip first, fall back to tar
        where 7z >nul 2>&1
        if !ERRORLEVEL! equ 0 (
            7z e -y "%TEMP%\llvm.7z" -o"%TEMP%\llvm-extract" bin\llc.exe bin\lld-link.exe bin\LTO.dll >nul 2>&1
        ) else (
            tar -xf "%TEMP%\llvm.7z" -C "%TEMP%\llvm-extract" --strip-components 1 2>nul || (
                echo Need 7-Zip or tar to extract LLVM.
                echo Install 7-Zip: https://www.7-zip.org/download.html
                exit /b 1
            )
        )
        if exist "%TEMP%\llvm-extract\bin\llc.exe" (
            move /Y "%TEMP%\llvm-extract\bin\llc.exe" "%LLVM_DIR%\bin\llc.exe" >nul
            move /Y "%TEMP%\llvm-extract\bin\lld-link.exe" "%LLVM_DIR%\bin\lld-link.exe" >nul
            if exist "%TEMP%\llvm-extract\bin\LTO.dll" move /Y "%TEMP%\llvm-extract\bin\LTO.dll" "%LLVM_DIR%\bin\LTO.dll" >nul
        )
        rmdir /s /q "%TEMP%\llvm-extract" 2>nul
        del "%TEMP%\llvm.7z" 2>nul
    )
    set "PATH=%LLVM_DIR%\bin;%PATH%"
)

:: --- Validate llc ---
where llc >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Error: llc not available after download.
    exit /b 1
)

:: --- Compile .ll → .obj ---
echo Compiling %LL_FILE%...
llc -filetype=obj "%LL_FILE%" -o "%GEN_DIR%\kernels_metal.obj"
if %ERRORLEVEL% neq 0 (
    echo LLVM compilation failed.
    exit /b %ERRORLEVEL%
)
echo Object: %GEN_DIR%\kernels_metal.obj

:: --- Link .obj → .exe (lld-link, fallback to MSVC link.exe) ---
set "LINKER="
where lld-link >nul 2>&1 && set "LINKER=lld-link"
if "%LINKER%"=="" (
    where link >nul 2>&1 && set "LINKER=link"
)
if "%LINKER%"=="" (
    call "%ProgramFiles%\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
    if %ERRORLEVEL% equ 0 set "LINKER=link"
)
if "%LINKER%"=="" (
    call "%ProgramFiles%\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
    if %ERRORLEVEL% equ 0 set "LINKER=link"
)

if "%LINKER%"=="" (
    echo.
    echo ==== Only .obj produced =========================================
    echo No linker found. Install VS with C++ workload or install LLVM.
    echo lld-link/llc are bundled at: %LLVM_DIR%
    echo.
    exit /b 0
)

echo Linking with %LINKER%...
if "%LINKER%"=="lld-link" (
    %LINKER% "%GEN_DIR%\kernels_metal.obj" /OUT:"bplus_metal_output.exe" /NOLOGO /ENTRY:main /SUBSYSTEM:CONSOLE
) else (
    %LINKER% "%GEN_DIR%\kernels_metal.obj" /OUT:"bplus_metal_output.exe" /NOLOGO
)
if %ERRORLEVEL% neq 0 (
    echo Linking failed.
    exit /b %ERRORLEVEL%
)

echo.
echo Running bplus_metal_output.exe...
echo.
bplus_metal_output.exe
echo.
echo Exit code: %ERRORLEVEL%
