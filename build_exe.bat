@echo off
set "LLC=%USERPROFILE%\.bplus\llvm\bin\llc.exe"
set "LL_FILE=gen_metal\kernels_metal.ll"
set "OBJ_FILE=gen_metal\kernels_metal.obj"

if not exist "%LLC%" (
    echo llc.exe not found at %LLC%
    exit /b 1
)

if not exist "%LL_FILE%" (
    echo Run metal first: dotnet run --project src\BPlusTranspiler -- hello.bp --metal --tier=L0
    exit /b 1
)

echo Compiling %LL_FILE%...
"%LLC%" -filetype=obj "%LL_FILE%" -o "%OBJ_FILE%"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
echo Created %OBJ_FILE%