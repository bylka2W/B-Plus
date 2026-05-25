@echo off
setlocal

set "BPC_DIR=%~dp0"
set "PUBLISH_DIR=%BPC_DIR%src\BPlusTranspiler\bin\Release\net8.0\win-x64\publish"

if not exist "%PUBLISH_DIR%\bpc.exe" (
    echo Building standalone bpc.exe (first run — may take a minute)...
    pushd "%BPC_DIR%src\BPlusTranspiler"
    dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true
    popd
    echo.
)

if exist "%PUBLISH_DIR%\bpc.exe" (
    "%PUBLISH_DIR%\bpc.exe" --repl %*
) else (
    echo Falling back to dotnet run...
    dotnet run --project "%BPC_DIR%src\BPlusTranspiler" -- --repl %*
)

pause
