@echo off
title B+ — установка
dotnet build src/BPlusTranspiler
if errorlevel 1 goto error

cd src/vs-extension/BPlusLanguage
dotnet build -c Release
if errorlevel 1 goto error

echo.
echo ==========================================
echo Готово! Открой BPlusLanguage.vsix вручную:
echo %cd%\bin\Release\BPlusLanguage.vsix
echo ==========================================
start "" "%cd%\bin\Release\BPlusLanguage.vsix"
goto end

:error
echo Ошибка сборки. Установи .NET 8 SDK:
echo https://dotnet.microsoft.com/download

:end
pause