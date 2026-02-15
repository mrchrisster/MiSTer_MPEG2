@echo off
set IVERILOG=C:\iverilog\bin\iverilog.exe
set VVP=C:\iverilog\bin\vvp.exe

echo === Compiling tb_emu_clk ===
"%IVERILOG%" -D__IVERILOG__ -g2005-sv -I ..\..\rtl\mpeg2 -o emu_clk.vvp ^
  tb_emu_clk.sv ^
  hps_stubs.v ^
  ..\..\rtl\sys_pll.sv ^
  ..\..\rtl\emu.sv ^
  ..\..\rtl\uart_debug.sv ^
  ..\..\rtl\mem_shim.sv ^
  ..\..\rtl\mpg_streamer.sv ^
  ..\..\rtl\uart_tx.v ^
  wrappers.v ^
  generic_fifo_dc.v ^
  generic_fifo_sc_b.v ^
  generic_dpram.v ^
  ..\..\rtl\mpeg2\mpeg2video.v ^
  ..\..\rtl\mpeg2\vbuf.v ^
  ..\..\rtl\mpeg2\getbits.v ^
  ..\..\rtl\mpeg2\vld.v ^
  ..\..\rtl\mpeg2\rld.v ^
  ..\..\rtl\mpeg2\iquant.v ^
  ..\..\rtl\mpeg2\idct.v ^
  ..\..\rtl\mpeg2\motcomp.v ^
  ..\..\rtl\mpeg2\motcomp_motvec.v ^
  ..\..\rtl\mpeg2\motcomp_addrgen.v ^
  ..\..\rtl\mpeg2\motcomp_picbuf.v ^
  ..\..\rtl\mpeg2\motcomp_dcttype.v ^
  ..\..\rtl\mpeg2\motcomp_recon.v ^
  ..\..\rtl\mpeg2\fwft.v ^
  ..\..\rtl\mpeg2\resample.v ^
  ..\..\rtl\mpeg2\resample_addrgen.v ^
  ..\..\rtl\mpeg2\resample_dta.v ^
  ..\..\rtl\mpeg2\resample_bilinear.v ^
  ..\..\rtl\mpeg2\pixel_queue.v ^
  ..\..\rtl\mpeg2\mixer.v ^
  ..\..\rtl\mpeg2\syncgen.v ^
  ..\..\rtl\mpeg2\syncgen_intf.v ^
  ..\..\rtl\mpeg2\yuv2rgb.v ^
  ..\..\rtl\mpeg2\osd.v ^
  ..\..\rtl\mpeg2\regfile.v ^
  ..\..\rtl\mpeg2\reset.v ^
  ..\..\rtl\mpeg2\watchdog.v ^
  ..\..\rtl\mpeg2\framestore.v ^
  ..\..\rtl\mpeg2\framestore_request.v ^
  ..\..\rtl\mpeg2\framestore_response.v ^
  ..\..\rtl\mpeg2\read_write.v ^
  ..\..\rtl\mpeg2\mem_addr.v ^
  ..\..\rtl\mpeg2\synchronizer.v ^
  ..\..\rtl\mpeg2\probe.v ^
  ..\..\rtl\mpeg2\xfifo_sc.v

if errorlevel 1 (
    echo === Compilation FAILED ===
    exit /b 1
)

echo === Running Simulation ===
"%VVP%" emu_clk.vvp
if errorlevel 1 (
    echo === Simulation FAILED ===
    exit /b 1
)
