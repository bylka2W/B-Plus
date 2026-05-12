@echo off
echo B+ Transpiler v2.5.0GH
echo.
if "%1"=="" (
    echo Usage: drag .bp file onto this batch file
    echo    or: run.bat examples\traffic_light.bp
    pause
    exit /b
)
dotnet run --project src/BPlusTranspiler -- %*
pause
