@echo off
set IVERILOG=C:\iverilog\bin\iverilog.exe
set VVP=C:\iverilog\bin\vvp.exe

echo Compiling...
"%IVERILOG%" -D__IVERILOG__ -o mem_shim.vvp tb_mem_shim.sv ..\..\rtl\mem_shim.sv
if errorlevel 1 (
    echo Compilation Failed
    exit /b 1
)

echo Running...
"%VVP%" mem_shim.vvp
if errorlevel 1 (
    echo Simulation Failed
    exit /b 1
)

echo Done.
