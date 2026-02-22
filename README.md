# MPEG2FPGA

This is a bare-metal, hardware-level MPEG-2 video core.



## MiSTer FPGA Port

This core has been successfully ported to the **MiSTer FPGA (Cyclone V)** ecosystem. It natively parses, compensates, and decodes MPEG-2 bitstreams in hardware, completely independent of the HPS/ARM CPU.

### MiSTer Features
- **Hardware-Accelerated Decoding**: Fully parses and decodes MPEG-2 bitstreams in logic.
- **Native SD Card Streaming (`mpg_streamer.sv`)**: Ingests `.mpg` files linearly utilizing the MiSTer `sd_*` block device interface, circumventing the slow `ioctl` byte-by-byte bus for massive bandwidth.
- **DDR3 AXI Interleaving (`mem_shim.sv`)**: Contains a custom, high-speed 2-state pipelined FSM with a Skid Buffer to interleave concurrent standard-mode dual-clock FIFO reads and writes across the MiSTer's `f2sdram` Avalon-MM bridge.
- **TrustZone Compliant Address Mapping**: Employs a dense 25-bit word addressing formula (`{7'b0011000, addr}`) to pack the 15.5MB HD frame buffer natively into the MiSTer's restrictive 24MB Contiguous Memory Allocator (CMA) bounds without triggering Linux `waitrequest` deadlocks.
- **NTSC Video Output**: Generates a pure 27 MHz pixel clock matching the physical VESA/CEA standard to allow for pixel-perfect NTSC 60Hz CRT and HDMI display.

### Known Limitations
* **Framerate Synchronization:** The decoder currently "VSYNC-paces" itself to the hardware display generator. A 25 FPS (PAL) file played on a hardcoded 60Hz NTSC (`modeline.v`) display will execute in "fast forward." To test video cleanly, use **NTSC 480i/p 30/60FPS** encoded `.mpg` files.
* **HD Modeline Switching:** While the core natively decodes resolutions up to `1920x1080` (MP@HL), the display block (`emu.sv`) currently drives a hardcoded 27 MHz pixel clock intended for Standard Definition (SD). To output 720p/1080p, dynamic PLL reallocation based on the sequence header must be implemented.
* **Audio Playback:** The core handles only video bitstreams. Synthesizing audio requires extracting the MPEG-Audio stream and feeding it to a soft-core or I2S bus.

### Documentation
Extensive engineering and debugging notes recorded during the MiSTer porting process are available in the `doc/` folder:
- `MiSTer_MPEG2_Porting_Notes.md` - Core architecture limitations and structural design migrations.
- `MiSTer_DDR3_Memory_Mapping.md` - The definitive guide on AXI memory address packing and f2sdram 24 MB boundaries.
- `BUG_FIX_LOG.md` - A timeline of clocking, coherence, and bounds deadlocks resolved.

### Original Authors
The core logic of the MPEG-2 video decoder was originally authored by **Koen De Vleeschauwer** (2007).
This repository focuses on integrating and modernizing the core for the **MiSTer FPGA / Cyclone V / DDR3 Avalon-MM** architecture.
