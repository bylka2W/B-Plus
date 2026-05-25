@echo off
set "LLVM=%USERPROFILE%\.bplus\llvm\bin"
set "GEN=gen_metal"

echo Compiling...
"%LLVM%\clang.exe" -c %GEN%\kernels_metal.ll -o %GEN%\kernels_metal.obj
"%LLVM%\clang.exe" -c legacy_stdio.ll -o legacy_stdio.obj

echo Linking...
"%LLVM%\lld-link.exe" /SUBSYSTEM:CONSOLE /ENTRY:main %GEN%\kernels_metal.obj legacy_stdio.obj kernel32.lib /OUT:output.exe /NOLOGO /NODEFAULTLIB

if exist output.exe (
    echo Running...
    output.exe
)
