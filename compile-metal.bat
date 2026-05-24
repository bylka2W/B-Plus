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
        echo LLVM not found. Downloading official clang+llvm (includes lld-link)...
        echo Size: ~943 MB compressed. One-time download.
        if not exist "%USERPROFILE%\.bplus" mkdir "%USERPROFILE%\.bplus"
        if not exist "%LLVM_DIR%" mkdir "%LLVM_DIR%"
        if not exist "%LLVM_DIR%\bin" mkdir "%LLVM_DIR%\bin"
        curl.exe -sL -o "%TEMP%\llvm.tar.xz" "https://github.com/llvm/llvm-project/releases/download/llvmorg-21.1.1/clang%%2Bllvm-21.1.1-x86_64-pc-windows-msvc.tar.xz"
        if !ERRORLEVEL! neq 0 (
            echo Download failed.
            exit /b 1
        )
        echo Extracting llc + lld-link...
        :: Full extract since selective extraction from .tar.xz is unreliable
        where 7z >nul 2>&1
        if !ERRORLEVEL! equ 0 (
            7z x -y "%TEMP%\llvm.tar.xz" -o"%TEMP%\llvm-full" >nul 2>&1
        ) else (
            mkdir "%TEMP%\llvm-full" >nul 2>&1
            tar -xJf "%TEMP%\llvm.tar.xz" -C "%TEMP%\llvm-full" >nul 2>&1
        )
        if not exist "%TEMP%\llvm-full" (
            echo Error: cannot extract %TEMP%\llvm.tar.xz. Install 7-Zip: https://www.7-zip.org/download.html
            exit /b 1
        )
        for /r "%TEMP%\llvm-full" %%f in (llc.exe lld-link.exe) do (
            copy /Y "%%f" "%LLVM_DIR%\bin\" >nul 2>&1
        )
        rmdir /s /q "%TEMP%\llvm-full" 2>nul
        del "%TEMP%\llvm.tar.xz" 2>nul
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

:: --- Compile legacy_stdio.ll (no-CRT puts/printf via kernel32) ---
if not exist "legacy_stdio.ll" (
    echo Error: legacy_stdio.ll not found — required for entry main() output.
    exit /b 1
)
echo Compiling legacy_stdio.ll...
llc -filetype=obj "legacy_stdio.ll" -o "%GEN_DIR%\legacy_stdio.obj"
if %ERRORLEVEL% neq 0 (
    echo Warning: legacy_stdio.ll compilation failed — entry print() may not work.
)

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
    %LINKER% "%GEN_DIR%\kernels_metal.obj" "%GEN_DIR%\legacy_stdio.obj" /OUT:"bplus_metal_output.exe" /NOLOGO /ENTRY:main /SUBSYSTEM:CONSOLE kernel32.lib /NODEFAULTLIB
) else (
    %LINKER% "%GEN_DIR%\kernels_metal.obj" "%GEN_DIR%\legacy_stdio.obj" /OUT:"bplus_metal_output.exe" /NOLOGO
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
