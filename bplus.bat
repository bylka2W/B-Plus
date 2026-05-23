@echo off
title B+ v4.0.0
setlocal enabledelayedexpansion

echo Building B+ v4.0.0...

dotnet build src/BPlusTranspiler >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Build failed.
    pause
    exit /b %ERRORLEVEL%
)

echo Building VS extension...
dotnet build src/vs-extension/BPlusLanguage -c Release >nul 2>&1

echo Installing to all Visual Studio versions...

for /f "delims=" %%i in ('dir "%LOCALAPPDATA%\Microsoft\VisualStudio" /b /ad 2^>nul') do (
    set "EXT_DIR=%LOCALAPPDATA%\Microsoft\VisualStudio\%%i\Extensions\CapGames221\BPlusLanguage\4.0.0"
    if not exist "!EXT_DIR!" mkdir "!EXT_DIR!"
    if exist src\vs-extension\BPlusLanguage\bin\Release\BPlusLanguage.dll (
        copy /y src\vs-extension\BPlusLanguage\bin\Release\BPlusLanguage.dll "!EXT_DIR!\BPlusLanguage.dll" >nul
        copy /y src\vs-extension\BPlusLanguage\source.extension.vsixmanifest "!EXT_DIR!\extension.vsixmanifest" >nul
        del /f /q "%LOCALAPPDATA%\Microsoft\VisualStudio\%%i\Extensions\ExtensionMetadata*" >nul 2>&1
        del /f /q "%LOCALAPPDATA%\Microsoft\VisualStudio\%%i\Extensions\extensions.configurationchanged" >nul 2>&1
        echo   Installed to: %%i
    )
)

echo.
echo === B+ v4.0.0 ready ===
echo.
echo Commands:
echo   new          - create hello.bp
echo   run hello    - compile hello.bp
echo.
echo Open .bp file in any VS - syntax highlighting works.
echo.
exit
