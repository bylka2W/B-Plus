@echo off
title B+ - Compile Metal Stack (LLVM -> .exe)
setlocal enabledelayedexpansion

set "GEN_DIR=gen_metal"
set "LLVM_DIR=%USERPROFILE%\.bplus\llvm"
set "LLVM_BIN=%LLVM_DIR%\bin"

:: --- Find input .ll ---
if not exist "%GEN_DIR%\kernels.ll" (
    if not exist "%GEN_DIR%\kernels_metal.ll" (
        echo No .ll found. Run: dotnet run --project src\BPlusTranspiler -- hello.bp
        exit /b 1
    )
    set "LL_FILE=%GEN_DIR%\kernels_metal.ll"
) else (
    set "LL_FILE=%GEN_DIR%\kernels.ll"
)

:: --- Ensure clang + lld-link available ---
where clang >nul 2>&1
if %ERRORLEVEL% neq 0 (
    if not exist "%LLVM_BIN%\clang.exe" (
        echo LLVM not found. Downloading official clang+llvm ^(includes lld-link^)...
        echo Size: ~943 MB compressed. One-time download.
        if not exist "%USERPROFILE%\.bplus" mkdir "%USERPROFILE%\.bplus"
        if not exist "%LLVM_DIR%" mkdir "%LLVM_DIR%"
        if not exist "%LLVM_BIN%" mkdir "%LLVM_BIN%"
        curl.exe -sL -o "%TEMP%\llvm.tar.xz" "https://github.com/llvm/llvm-project/releases/download/llvmorg-21.1.1/clang%%2Bllvm-21.1.1-x86_64-pc-windows-msvc.tar.xz"
        if !ERRORLEVEL! neq 0 (
            echo Download failed.
            exit /b 1
        )
        echo Extracting clang + lld-link...
        where 7z >nul 2>&1
        if !ERRORLEVEL! equ 0 (
            7z x -y "%TEMP%\llvm.tar.xz" -o"%TEMP%\llvm-full" >nul 2>&1
        ) else (
            mkdir "%TEMP%\llvm-full" >nul 2>&1
            tar -xJf "%TEMP%\llvm.tar.xz" -C "%TEMP%\llvm-full" >nul 2>&1
        )
        if not exist "%TEMP%\llvm-full" (
            echo Error: cannot extract. Install 7-Zip: https://www.7-zip.org/download.html
            exit /b 1
        )
        for /r "%TEMP%\llvm-full" %%f in (clang.exe lld-link.exe) do (
            copy /Y "%%f" "%LLVM_BIN%\" >nul 2>&1
        )
        rmdir /s /q "%TEMP%\llvm-full" 2>nul
        del "%TEMP%\llvm.tar.xz" 2>nul
    )
    set "PATH=%LLVM_BIN%;%PATH%"
)

:: --- Validate clang ---
where clang >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Error: clang not available after download.
    exit /b 1
)

:: --- Compile .ll -> .obj ---
echo Compiling %LL_FILE%...
"%LLVM_BIN%\clang.exe" -c "%LL_FILE%" -o "%GEN_DIR%\kernels_metal.obj"
if %ERRORLEVEL% neq 0 (
    echo LLVM compilation failed.
    exit /b %ERRORLEVEL%
)
echo Object: %GEN_DIR%\kernels_metal.obj

:: --- Compile legacy_stdio.ll ---
if not exist "legacy_stdio.ll" (
    echo Error: legacy_stdio.ll not found -- required for entry main^(^) output.
    exit /b 1
)
echo Compiling legacy_stdio.ll...
"%LLVM_BIN%\clang.exe" -c "legacy_stdio.ll" -o "%GEN_DIR%\legacy_stdio.obj"
if %ERRORLEVEL% neq 0 (
    echo Warning: legacy_stdio.ll compilation failed.
)

:: --- Validate lld-link ---
where lld-link >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Error: lld-link not available.
    exit /b 1
)

:: --- Link .obj -> .exe ---
echo Linking...
"%LLVM_BIN%\lld-link.exe" "%GEN_DIR%\kernels_metal.obj" "%GEN_DIR%\legacy_stdio.obj" /OUT:"%GEN_DIR%\bplus_metal_output.exe" /NOLOGO /ENTRY:main /SUBSYSTEM:CONSOLE kernel32.lib /NODEFAULTLIB
if %ERRORLEVEL% neq 0 (
    echo Linking failed.
    exit /b %ERRORLEVEL%
)

:: --- Run ---
echo.
echo Running %GEN_DIR%\bplus_metal_output.exe...
echo.
%GEN_DIR%\bplus_metal_output.exe
echo.
echo Exit code: %ERRORLEVEL%
