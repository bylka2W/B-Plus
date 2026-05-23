@echo off
title B+ v4.0.0
echo B+ v4.0.0

dotnet build src/BPlusTranspiler >nul 2>&1

dotnet build src/vs-extension/BPlusLanguage -c Release >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Extension build failed
    exit /b %ERRORLEVEL%
)

rem Find the latest Visual Studio instance
for /f "delims=" %%i in ('dir "%LOCALAPPDATA%\Microsoft\VisualStudio\*.*_" /b /o:-n 2^>nul') do (
    set "VS_INSTANCE=%%i"
    goto :found
)
:found

echo Installing to Visual Studio: %VS_INSTANCE%

set "EXT_DIR=%LOCALAPPDATA%\Microsoft\VisualStudio\%VS_INSTANCE%\Extensions\CapGames221\BPlusLanguage\4.0.0"
if not exist "%EXT_DIR%" mkdir "%EXT_DIR%"
copy /y src\vs-extension\BPlusLanguage\bin\Release\BPlusLanguage.dll "%EXT_DIR%\BPlusLanguage.dll" >nul
copy /y src\vs-extension\BPlusLanguage\source.extension.vsixmanifest "%EXT_DIR%\extension.vsixmanifest" >nul

rem Write Content_Types if not exists
if not exist "%EXT_DIR%\[Content_Types].xml" copy /y src\vs-extension\BPlusLanguage\bin\Release\BPlusLanguage.dll "%EXT_DIR%\[Content_Types].xml" >nul 2>&1

rem Clear extension cache
del /f /q "%LOCALAPPDATA%\Microsoft\VisualStudio\%VS_INSTANCE%\Extensions\ExtensionMetadata.mpack" >nul 2>&1
del /f /q "%LOCALAPPDATA%\Microsoft\VisualStudio\%VS_INSTANCE%\Extensions\ExtensionMetadataCache.sqlite" >nul 2>&1
del /f /q "%LOCALAPPDATA%\Microsoft\VisualStudio\%VS_INSTANCE%\Extensions\extensions.configurationchanged" >nul 2>&1

echo Done. Starting Visual Studio...
start devenv
exit
