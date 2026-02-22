@echo off
echo Compiling...
iverilog -g2012 -o mem_shim.vvp tb_mem_shim.sv ..\..\rtl\mem_shim.sv
if %errorlevel% neq 0 (
    echo Compilation Failed
    exit /b 1
)
echo Running...
vvp mem_shim.vvp
echo Done.
