@echo off
echo B+ Transpiler v3.0.4L BETA
echo.

set RUNTIME=win-x64
set AOT_FLAG=
set CI_MODE=

:parse
if "%1"=="" goto :run
if "%1"=="--aot"    set AOT_FLAG=-p:PublishAot=true
if "%1"=="--linux"  set RUNTIME=linux-x64
if "%1"=="--osx"    set RUNTIME=osx-x64
if "%1"=="--ci"     set CI_MODE=1
shift
goto :parse

:run
dotnet publish -c Release -r %RUNTIME% --self-contained true %AOT_FLAG% --no-build
if errorlevel 1 (
    echo Publish failed
    exit /b 1
)

set OUT_DIR=release\%RUNTIME%
if not exist "%OUT_DIR%" mkdir %OUT_DIR%

if "%CI_MODE%"=="1" (
    echo.
    echo ##teamcity[blockOpened name='NativeAOT publish']
    echo NativeAOT publish: %RUNTIME% AOT=%AOT_FLAG%
    echo ##teamcity[blockClosed name='NativeAOT publish']
)

echo.
echo Done: %OUT_DIR%\bpc
echo Build with: bpc publish --aot --runtime %RUNTIME%