# MPEG2FPGA Core Architecture Guide

**Original Design:** Koenraad De Vleeschauwer (2007-2009)
**MiSTer Port Analysis:** 2026-02-20

This document explains the internal architecture of the MPEG2 video decoder core for developers working on platform ports and debugging.

---

## Table of Contents

1. [Overview & Data Flow](#overview--data-flow)
2. [Clock Domains](#clock-domains)
3. [Memory Interface Architecture](#memory-interface-architecture)
4. [Frame Store Organization](#frame-store-organization)
5. [Memory Profiles (SDTV vs HDTV)](#memory-profiles-sdtv-vs-hdtv)
6. [Video Output Pipeline](#video-output-pipeline)
7. [Critical Design Patterns](#critical-design-patterns)
8. [Key Files Reference](#key-files-reference)

---

## Overview & Data Flow

### Block Diagram

The MPEG2 decoder implements a full hardware video decoder with these major pipeline stages:

```
MPEG2 Stream → Video Buffer → VLD → Run/Length + Motion Vectors
                                ↓
                         IDCT + IQ (Run/Length)
                                ↓
                    Motion Compensation (Motion Vectors)
                                ↓
                         Reconstructed Frame
                                ↓
                Frame Store (4 frames + OSD) ← Memory Controller
                                ↓
                      Chroma Resampling (4:2:0 → 4:4:4)
                                ↓
                         Video Sync Generator
                                ↓
                         Mixer + OSD Blend
                                ↓
                         YUV → RGB Converter
                                ↓
                    RGB/YUV Video Output (dot_clk)
```

### Pipeline Components

1. **Video Buffer**: FIFO between incoming stream and decoder, smooths bitrate variations
2. **Getbits**: Sliding window over bitstream for variable-length code extraction
3. **Variable Length Decoder (VLD)**: Parses MPEG2 syntax, extracts run/length values and motion vectors
4. **RLD + IQ + IDCT**: Inverse quantization and discrete cosine transform (decompression)
5. **Motion Compensation**: Retrieves reference frames from memory, applies motion vector translations
6. **Frame Store**: Manages 4 reference frames + OSD in external memory
7. **Chroma Resampling**: Upsamples 4:2:0 chroma to 4:4:4 with bilinear interpolation
8. **Video Sync Generator**: Counts pixels/lines/frames at dot clock frequency
9. **Mixer**: Blends video with on-screen display
10. **YUV2RGB**: Final colorspace conversion

---

## Clock Domains

The decoder operates across **three independent clock domains**:

### `clk` - Main Decoder Clock
- **Domain**: All decoder logic (VLD, IDCT, motion compensation, frame store control)
- **Typical Frequency**: 27 MHz (NTSC), 25 MHz (PAL)
- **Synchronous Signals**:
  - `stream_data`, `stream_valid`, `busy`
  - `reg_addr`, `reg_wr_en`, `reg_dta_in/out`
  - `error`, `interrupt`, `watchdog_rst`

### `mem_clk` - Memory Controller Clock
- **Domain**: Memory request/response FIFOs (dual-clock crossing)
- **Typical Frequency**: 100-108 MHz (higher than decoder for bandwidth)
- **Synchronous Signals**:
  - `mem_req_rd_cmd`, `mem_req_rd_addr`, `mem_req_rd_dta`
  - `mem_req_rd_en`, `mem_req_rd_valid`
  - `mem_res_wr_dta`, `mem_res_wr_en`, `mem_res_wr_almost_full`
- **Critical**: Request FIFO has write side on `clk`, read side on `mem_clk` (dual-clock FIFO)

### `dot_clk` - Video Output Clock
- **Domain**: Video output signals (pixel data, sync)
- **Typical Frequency**: Pixel clock for target resolution (25.175 MHz for 640×480, 27 MHz for 480i)
- **Synchronous Signals**:
  - `r`, `g`, `b`, `y`, `u`, `v`
  - `pixel_en`, `h_sync`, `v_sync`, `c_sync`

**CRITICAL REQUIREMENT (MiSTer)**: On MiSTer, `clk` and `mem_clk` **MUST** be from the same PLL oscillator. If from different oscillators (e.g., PLL vs HPS-derived), the dual-clock FIFO enters write-faster-than-read CDC mode and can deadlock the HPS bridge. Hardware-confirmed: using PLL 108 MHz for `clk` and HPS 100 MHz for `mem_clk` caused a permanent hang after exactly 4 writes (the f2sdram bridge's write buffer depth).

---

## Memory Interface Architecture

### Dual-FIFO Interface

The core uses a **bidirectional dual-FIFO** interface to communicate with the external memory controller:

```
                  ┌─────────────────────────────┐
                  │    MPEG2 Decoder Core       │
                  │         (clk domain)         │
                  └─────────────┬───────────────┘
                                │
                  ┌─────────────▼───────────────┐
                  │   Memory Request FIFO       │
                  │   (Dual-Clock, clk→mem_clk) │
                  │   Depth: ~32 entries        │
                  └─────────────┬───────────────┘
                                │ mem_clk domain
                  ┌─────────────▼───────────────┐
                  │   Memory Controller         │
                  │   (External, User-Supplied) │
                  └─────────────┬───────────────┘
                                │
                  ┌─────────────▼───────────────┐
                  │   Memory Response FIFO      │
                  │   (Dual-Clock, mem_clk→clk) │
                  │   Depth: ~32 entries        │
                  └─────────────┬───────────────┘
                                │
                  ┌─────────────▼───────────────┐
                  │    MPEG2 Decoder Core       │
                  │   (Motion Comp, Display)    │
                  └─────────────────────────────┘
```

### Memory Request FIFO (Decoder → Memory)

**Standard-mode FIFO** (NOT first-word-fall-through):

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `mem_req_rd_cmd` | Output | 2 | Command: 0=NOOP, 1=REFRESH, 2=READ, 3=WRITE |
| `mem_req_rd_addr` | Output | 22 | 64-bit word address (8 bytes per word) |
| `mem_req_rd_dta` | Output | 64 | Write data (for CMD_WRITE) |
| `mem_req_rd_en` | **Input** | 1 | **FIFO read enable** (continuous flow control) |
| `mem_req_rd_valid` | Output | 1 | Data valid (1 cycle after `rd_en` assertion) |

**CRITICAL PROTOCOL**:
- `mem_req_rd_en` is **NOT a per-command pulse**
- It is the **continuous read enable** of the dual-clock FIFO
- Memory controller should assert `mem_req_rd_en` whenever it can accept work
- FIFO pops when **BOTH** `mem_req_rd_en=1` AND `mem_req_rd_valid=1`
- Original design: `mem_req_rd_en <= ~mem_res_wr_almost_full` (from `mem_ctl.v`)
- **FIFO mode**: Standard (NOT first-word-fall-through). `mem_req_rd_valid` appears **1 cycle after** `rd_en` asserts. The external controller must account for this 1-cycle latency.

### Memory Response FIFO (Memory → Decoder)

**Standard-mode FIFO** for read data:

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `mem_res_wr_dta` | Input | 64 | Read data from memory |
| `mem_res_wr_en` | Input | 1 | Write enable (pulse to write data) |
| `mem_res_wr_almost_full` | Output | 1 | Back-pressure (stop writing when asserted) |

**Read Ordering**: Read responses **MUST** appear in the same order as read requests were issued.

### Memory Request Sources (Internal Arbitration)

The frame store receives up to **6 simultaneous memory requests** from:

1. **Motion Compensation (Forward)** - Read reference frame (TAG_FWD)
2. **Motion Compensation (Backward)** - Read reference frame (TAG_BWD)
3. **Motion Compensation (Reconstruct)** - Write decoded frame (TAG_RECON)
4. **Chroma Resampling (Display)** - Read for video output (TAG_DISP)
5. **On-Screen Display (OSD)** - Write from register file (TAG_OSD)
6. **Memory Controller Init** - Clear/refresh operations (TAG_CTRL)

The **frame store prioritizes** and **serializes** these into a single request stream sent to `mem_req_rd_*` outputs.

---

## Frame Store Organization

### Address Space Structure

The decoder uses **22-bit word addresses** where each address points to a **64-bit (8-byte) word** containing **8 consecutive pixels** of Y, Cb, or Cr data.

**Storage Format**: 4:2:0 YCbCr
- **Luminance (Y)**: Full resolution (e.g., 1920×1088 for HDTV)
- **Chrominance (Cb, Cr)**: Half horizontal, half vertical resolution (960×544)

### Frame Layout (4:2:0)

Each frame consists of three components stored sequentially:

```
Frame N:
  ┌─────────────────┐
  │   Y (Luma)      │  Size: 2^WIDTH_Y words
  ├─────────────────┤
  │   Cr (Chroma)   │  Size: 2^WIDTH_C words
  ├─────────────────┤
  │   Cb (Chroma)   │  Size: 2^WIDTH_C words
  └─────────────────┘
```

**Block Row Addressing**: Each 64-bit word stores **one row** (8 pixels) from an 8×8 block. Blocks are organized in raster-scan order within macroblocks.

### Frame Store Map (4 Frames + OSD)

From `rtl/mpeg2/mem_codes.v`:

```verilog
FRAME_0_Y  = 0x000000               // Frame 0 (I/P reference)
FRAME_0_CR = FRAME_0_Y  + 2^WIDTH_Y
FRAME_0_CB = FRAME_0_CR + 2^WIDTH_C

FRAME_1_Y  = FRAME_0_CB + 2^WIDTH_C // Frame 1 (I/P reference)
FRAME_1_CR = FRAME_1_Y  + 2^WIDTH_Y
FRAME_1_CB = FRAME_1_CR + 2^WIDTH_C

FRAME_2_Y  = FRAME_1_CB + 2^WIDTH_C // Frame 2 (B reference)
FRAME_2_CR = FRAME_2_Y  + 2^WIDTH_Y
FRAME_2_CB = FRAME_2_CR + 2^WIDTH_C

FRAME_3_Y  = FRAME_2_CB + 2^WIDTH_C // Frame 3 (B reference)
FRAME_3_CR = FRAME_3_Y  + 2^WIDTH_Y
FRAME_3_CB = FRAME_3_CR + 2^WIDTH_C

OSD        = FRAME_3_CB + 2^WIDTH_C // On-Screen Display (256-color palette)
VBUF       = OSD + (calculated)     // Video Buffer (input stream FIFO)
VBUF_END   = (end of vbuf)
ADDR_ERR   = VBUF_END + 1           // Sentinel for invalid addresses
```

**Frame Initialization**: After reset or watchdog, the core writes `0x80` (128) to all addresses from `FRAME_0_Y` to `VBUF_END` to clear the frame store. This takes ~2M writes for MP@HL profile.

---

## Memory Profiles (SDTV vs HDTV)

The core supports two compile-time profiles via `MP_AT_HL` define in `rtl/mpeg2/mem_codes.v`:

### SDTV Profile (Default, `MP_AT_HL` undefined)

**Target**: Standard Definition TV up to 768×576 (MP@ML)

```verilog
WIDTH_Y    = 16   // 2^16 = 64K words = 512 KB luminance per frame
WIDTH_C    = 14   // 2^14 = 16K words = 128 KB chrominance per component
VBUF       = 0x070000
VBUF_END   = 0x077FFE
ADDR_ERR   = 0x077FFF
```

**Total Memory**: ~4 MB
- 4 frames × (512KB Y + 128KB Cr + 128KB Cb) = 3 MB
- OSD + Video Buffer = ~1 MB

### HDTV Profile (`MP_AT_HL` defined) — **CURRENT MISTER CONFIG**

**Target**: High Definition TV up to 1920×1088 (MP@HL)

```verilog
WIDTH_Y    = 18   // 2^18 = 256K words = 2 MB luminance per frame
WIDTH_C    = 16   // 2^16 = 64K words = 512 KB chrominance per component
VBUF       = 0x1C0000
VBUF_END   = 0x1EFFFE
ADDR_ERR   = 0x1EFFFF  ← ERROR SENTINEL (seen in MiSTer debug as @:06F7FFF8)
```

**Total Memory**: ~15 MB
- 4 frames × (2MB Y + 512KB Cr + 512KB Cb) = 12 MB
- OSD + Video Buffer = ~3 MB

**VBUF Alignment Requirement**: `VBUF` must end in 18 zeroes (binary) because internal counters are 18-bit. Valid: `0x1C0000`, Invalid: `0x1D0000`.

**ADDR_ERR Sentinel**: When `mem_addr.v` receives invalid `{frame, component}` (e.g., macroblock address overflow, motion vector out of bounds, or pipeline flush on startup), it outputs `ADDR_ERR` (0x1EFFFF). This appears in MiSTer UART debug as `@:06F7FFF8` (after `{4'b0011, 22'h1EFFFF, 3'b000}` DDR3 address translation).

**ADDR_ERR in production**: `@:06F7FFF8` during decode = decoder state machine error (motion vector OOB, invalid macroblock). `@:06F7FFF8` immediately on first video select = expected startup pipeline flush — must be filtered in `mem_shim.sv` before reaching DDR3, or the bridge will assert `waitrequest=1` permanently.

**MiSTer fix**: `mem_shim.sv` discards WRITE/READ to address `22'h1EFFFF` silently (WRITE dropped; READ returns `64'd0`).

---

## Video Output Pipeline

### Chroma Upsampling (4:2:0 → 4:4:4)

The frame store contains 4:2:0 video (chroma at half resolution). The **chroma resampling** stage reads from memory and performs **bilinear interpolation** to produce full-resolution color output.

```
Frame Store (4:2:0)       Chroma Resampling         Mixer
    ↓                            ↓                     ↓
Y: 1920×1088          Bilinear Upsample      Video Sync Generator
Cb: 960×544     →     Cb, Cr: 1920×1088  →  (counts X,Y coords)
Cr: 960×544                                         ↓
                                              Blend with OSD
                                                    ↓
                                               YUV2RGB
                                                    ↓
                                            RGB Output (dot_clk)
```

### Video Synchronization Generator

**Clock**: `dot_clk` (pixel clock)
**Function**: Generates `h_sync`, `v_sync`, `c_sync`, and `pixel_en` signals based on programmable modeline registers.

**Default Modeline**: 800×600 @ 60 Hz SVGA (can be configured via registers)

### On-Screen Display (OSD)

- **Resolution**: Same as video output
- **Format**: 256-color palette (8-bit indexed)
- **Blending Modes** (configurable):
  - OSD on top (video hidden)
  - Blended (translucent overlay)
- **Access**: Software writes via register file (TAG_OSD memory requests)

### YUV to RGB Conversion

Final stage converts YCbCr (ITU-R BT.601) to RGB using hardware multipliers.

**Outputs Available**:
- `r`, `g`, `b` (8-bit each)
- `y`, `u`, `v` (8-bit each, for external conversion)
- `pixel_en` (blanking control)

---

## Critical Design Patterns

### 1. Dual-Clock FIFO Synchronization

**Request FIFO**: Write side on `clk`, read side on `mem_clk`
**Response FIFO**: Write side on `mem_clk`, read side on `clk`

**MiSTer Issue**: If `clk` and `mem_clk` come from different oscillators, true asynchronous CDC occurs. If write clock > read clock, the FIFO fills faster than it drains, causing permanent back-pressure.

**Solution**: Ensure `clk` and `mem_clk` are **derived from the same PLL** (phase-locked, frequency-related).

### 2. Memory Controller Flow Control

Memory controller should implement:

```verilog
always @(posedge mem_clk) begin
    // Allow request FIFO to pop when response FIFO has space
    mem_req_rd_en <= ~mem_res_wr_almost_full;

    // Process commands when valid
    if (mem_req_rd_en && mem_req_rd_valid) begin
        case (mem_req_rd_cmd)
            CMD_READ:  /* issue read to SDRAM */
            CMD_WRITE: /* issue write to SDRAM */
            CMD_REFRESH: /* refresh DRAM */
        endcase
    end
end
```

### 3. Macroblock Address Translation

`rtl/mpeg2/mem_addr.v` translates:
- Macroblock address (sequential counter)
- Motion vector (mv_x, mv_y) with half-pixel precision
- Signed offset (delta_x, delta_y)

Into 22-bit word address. **Constraint**: Macroblock address must increment by 1 or reset to 0. Any other transition → `ADDR_ERR`.

### 4. Watchdog Reset

`watchdog_rst` output pulses **LOW for one clock cycle** when decoder stalls.

**Actions on Watchdog**:
1. Core re-initializes frame store (writes 128 to all addresses)
2. VLD parser resets
3. **CRITICAL (MiSTer)**: Memory transaction counters (e.g., `outstanding_reads`) must **survive** watchdog reset on `hard_rst_n` domain, while FSM resets on `rst_n` domain.

### 5. IDCT Accuracy

The Inverse Discrete Cosine Transform uses:
- 12× 18×18 multipliers
- 2× dual-port RAMs
- Streaming architecture (1 pixel per clock)
- **Conforms to IEEE-1180** accuracy requirements

---

## Key Files Reference

### Core MPEG2 Decoder
- `rtl/mpeg2/mpeg2video.v` - Top-level decoder (24K lines)
- `rtl/mpeg2/vld.v` - Variable Length Decoder
- `rtl/mpeg2/getbits.v` - Bitstream sliding window
- `rtl/mpeg2/idct.v` - Inverse DCT
- `rtl/mpeg2/motcomp.v` - Motion Compensation
- `rtl/mpeg2/framestore.v` - Memory arbiter & request generation
- `rtl/mpeg2/resample.v` - Chroma upsampling (4:2:0 → 4:4:4)
- `rtl/mpeg2/yuv2rgb.v` - YUV to RGB conversion

### Memory Subsystem
- `rtl/mpeg2/mem_codes.v` - **Memory map definitions, profiles**
- `rtl/mpeg2/mem_addr.v` - **Macroblock → memory address translation**
- `rtl/mpeg2/framestore_request.v` - Request generation & frame init

### Platform Interface (MiSTer)
- `rtl/emu.sv` - MiSTer wrapper (DDR3, video, HPS interface)
- `rtl/mem_shim.sv` - MPEG2 FIFO ↔ Avalon-MM DDR3 bridge
- `rtl/uart_debug.sv` - Debug telemetry output (one line/second, 147 chars)

**mem_shim.sv responsibilities:**
1. Pop commands from `mem_req_rd_*` dual-clock FIFO (standard mode, 1-cycle latency)
2. Filter ADDR_ERR (`22'h1EFFFF`) — drop writes, synthesize zero-reads
3. Map 22-bit word addresses to 29-bit DDR3 address: `{4'b0011, addr[21:0], 3'b000}`
   - Window 0011 (bits [28:25]) = HPS-mapped to byte address 0x30000000 range
   - Hardware-proven formula: each addr increment = 8 DDRAM units (64-byte DDR3 stride)
   - See `MiSTer_DDR3_Memory_Mapping.md` for details
4. Implement Avalon-MM protocol (gate on `!DDRAM_BUSY`, combinational `DDRAM_RD/WE`)
5. Push `ddr3_readdatavalid` responses back into `mem_res_wr_*` FIFO
6. Assert `mem_req_rd_en` continuously when able to accept work

### FIFOs
- `rtl/generic/generic_fifo_dc.v` - **Dual-clock FIFO** (request/response)
- `rtl/generic/generic_fifo_sc_b.v` - Single-clock FIFO (video buffer)

---

## Debugging Reference

### Common Issues

| Symptom | Likely Cause | Check |
|---------|--------------|-------|
| `@:06F7FFF8` in debug | ADDR_ERR sentinel access | Decoder state machine error or startup flush (motion vector OOB, invalid macroblock) |
| `M:D U:1` stuck | Memory waitrequest deadlock | Clock domain crossing, write-after-read hazard, wrong address window |
| Black screen | Video clock mismatch | CLK_VIDEO ≠ dot_clk, CDC violation in video path |
| `P > RP` growing | Outstanding reads accumulating | Memory controller not sending responses, read ordering violated |
| Watchdog fires (`O:1`) | Decoder stalled | Stream corruption, VLD parser stuck, frame store init incomplete |

### UART Debug Fields (MiSTer Port)

See `BUG_FIX_LOG.md` for full field reference. Key memory fields:
- `@`: DDRAM_ADDR (should be `@:06xxxxxx` for valid frame buffer; `@:06F7FFF8` = ADDR_ERR!)
- `W`: Write count (increases ~2M during frame store init, then driven by motion comp writes)
- `P`: Read count (should increase continuously during decode/display)
- `RP`: Read response count (should match P when idle; `P > RP` = responses missing)
- `M`: Memory shim FSM state — `{cmd[1:0], saved_valid, state}`:
  - `M:0` = S_IDLE (normal)
  - `M:9` = READ in S_WAIT
  - `M:D` = WRITE in S_WAIT, no skid — if stuck = deadlock
  - `M:F` = WRITE in S_WAIT, skid occupied — if stuck = deadlock

**NOTE:** The debug_state encoding was changed to `{debug_cmd[1:0], state[1:0]}` where state is now 2 bits (S_IDLE=0, S_WAIT=1). The `saved_valid` is no longer in the M field; it is now reported separately via the `SC` (saved_cmd) field.
- `U`: `ddr3_waitrequest` — stuck at 1 = permanent bridge deadlock
- `I`: `init_cnt` 0→1FF — when `1FF`, internal RAMs ready (frame store CLEAR may still be running)
- `FC`: Free-running frame counter — must be incrementing for video to be progressing

---

## References

1. Original documentation: `doc/mpeg2fpga.pdf` / `doc/mpeg2fpga.txt`
2. MiSTer port notes: `doc/MiSTer_MPEG2_Porting_Notes.md`
3. DDR3 interface: `doc/MiSTer_DDR3_Memory_Mapping.md`
4. Bug fixes: `doc/BUG_FIX_LOG.md`
5. MPEG-2 Video Specification: ISO/IEC 13818-2
6. IEEE-1180 IDCT Accuracy Test

---

*Document created: 2026-02-20*
*For MiSTer FPGA port of MPEG2FPGA core*
