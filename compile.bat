@echo off
setlocal enabledelayedexpansion

:: 1. Capture description from argument %1
set "DESC=%~1"

set PATH=C:\intelFPGA_lite\17.0\quartus\bin64;%PATH%

echo Running Map...
quartus_map mpeg2fpga
if %errorlevel% neq 0 exit /b %errorlevel%

echo Running Fit...
quartus_fit mpeg2fpga
if %errorlevel% neq 0 exit /b %errorlevel%

echo Running Asm...
quartus_asm mpeg2fpga
if %errorlevel% neq 0 exit /b %errorlevel%

echo Running STA...
quartus_sta mpeg2fpga
if %errorlevel% neq 0 exit /b %errorlevel%

echo Generating RBF...
quartus_cpf -c -o bitstream_compression=on output_files\mpeg2fpga.sof output_files\mpeg2fpga.rbf
if %errorlevel% neq 0 exit /b %errorlevel%

echo.
echo Compilations successful.
echo.

:: 2. If no description was passed, ask now
if "%DESC%"=="" (
    set /p "DESC=Enter description (or press Enter to skip release): "
)

:: 3. If we have a description now, move to releases
if not "%DESC%"=="" (
    :: Get standardized Date and Time using WMIC
    for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value') do set datetime=%%I
    
    :: Slice the string: YYYYMMDD and HHMM
    set "mydate=!datetime:~0,8!"
    set "mytime=!datetime:~8,4!"
    
    set "RELEASE_NAME=MPEG2_!DESC!_!mydate!_!mytime!.rbf"
    
    if not exist "releases" mkdir "releases"
    
    copy "output_files\mpeg2fpga.rbf" "releases\!RELEASE_NAME!"
    echo Released to: releases\!RELEASE_NAME!
) else (
    echo Skipping release folder.
)

echo Done.