@echo off
set "BPC=%~dp0bpc.exe"
if exist "%BPC%" (
    "%BPC%" %*
) else (
    dotnet run --project "%~dp0src\BPlusTranspiler" -- %*
)
