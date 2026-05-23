@echo off
title B+ v4.0.0

echo B+ v4.0.0

dotnet build src/BPlusTranspiler >nul 2>&1

dotnet build src/vs-extension/BPlusLanguage -c Release >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Extension build failed
    exit /b %ERRORLEVEL%
)

set "EXT_DIR=%LOCALAPPDATA%\Microsoft\VisualStudio\17.0_9e4753c6\Extensions\CapGames221\BPlusLanguage\4.0.0"
if not exist "%EXT_DIR%" mkdir "%EXT_DIR%"
copy /y src\vs-extension\BPlusLanguage\bin\Release\BPlusLanguage.dll "%EXT_DIR%\BPlusLanguage.dll" >nul
copy /y src\vs-extension\BPlusLanguage\source.extension.vsixmanifest "%EXT_DIR%\extension.vsixmanifest" >nul

rem Clear extension cache so VS picks up new extension
del /f /q "%LOCALAPPDATA%\Microsoft\VisualStudio\17.0_9e4753c6\Extensions\ExtensionMetadata.mpack" >nul 2>&1
del /f /q "%LOCALAPPDATA%\Microsoft\VisualStudio\17.0_9e4753c6\Extensions\ExtensionMetadataCache.sqlite" >nul 2>&1

echo Extension installed. Starting Visual Studio...
start devenv
exit
