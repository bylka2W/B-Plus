@echo off
cd /d "%~dp0"
if "%~1"=="" (
    echo Usage: drag a .b+ file onto this bat, or: bpc run hello.b+
    pause
    exit /b 1
)
"zig\zig-out\bin\bpc.exe" run %*
echo.
pause
