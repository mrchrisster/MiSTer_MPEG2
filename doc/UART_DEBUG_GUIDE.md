# UART Debug Guide for MPEG2FPGA Black Screen Issue

## Overview
The UART debug module outputs diagnostic information every ~1 second at 115200 baud to help diagnose why the MPEG2 decoder shows a black screen.

## Hardware Setup
1. **Connect USB-to-Serial adapter** to MiSTer's UART pins:
   - **TX** (FPGA transmit): Connect to adapter's RX
   - **GND**: Connect to adapter's GND
   - UART pins are on the 40-pin GPIO header (check MiSTer documentation for exact location)

2. **Open Serial Terminal** on your PC:
   ```bash
   # Linux/Mac
   screen /dev/ttyUSB0 115200
   # or
   minicom -D /dev/ttyUSB0 -b 115200

   # Windows
   # Use PuTTY or TeraTerm
   # Settings: 115200 baud, 8N1, no flow control
   ```

## Debug Output Format
Every second, you'll see a line like:
```
L:1 A:0 B:0 V:1 X:000 Y:000
```

### Signal Meanings

| Signal | Name | Source | Meaning | What to Look For |
|--------|------|--------|---------|------------------|
| **L** | `locked` | PLL | PLL lock status | Should be `1` - if `0`, clocks are unstable |
| **A** | `active` | `core_video_active` | Decoder producing video | Should become `1` after 3 vsyncs. **KEY INDICATOR!** |
| **B** | `busy` | `core_busy` | SDRAM busy | Should toggle 0/1 during decoding. If stuck at `1`, memory stalled |
| **V** | `valid` | `stream_valid` | MPEG stream valid | Should be `1` when MPG file is loaded. If `0`, no stream data |
| **X** | `arx` | `core_h_pos[11:0]` | Horizontal position | Should count 0→width during active video |
| **Y** | `ary` | `core_v_pos[11:0]` | Vertical position | Should count 0→height during active video |

## Diagnostic Scenarios

### Scenario 1: No Stream Data
```
L:1 A:0 B:0 V:0 X:000 Y:000
```
**Problem**: Stream not being fed to decoder
- Check: Is MPG file properly loaded?
- Check: Is `stream_data_strobe` working? (add to UART debug if needed)
- Check: File reading logic in MiSTer framework

### Scenario 2: Stream Valid but No Video Activity
```
L:1 A:0 B:0 V:1 X:000 Y:000
```
**Problem**: Decoder receiving stream but not producing vsync pulses
- **Most likely cause**: Decoder stuck in initialization or parsing
- Check: Is decoder reset being released properly?
- Check: MPEG2 sequence header being parsed?
- Add debug: Monitor `picture_start`, `sequence_header_code` from decoder

### Scenario 3: Counting But No Active Flag
```
L:1 A:0 B:0 V:1 X:2D0 Y:240
```
**Problem**: Decoder producing timing signals but `core_video_active` not asserting
- X/Y are counting → vsync IS happening
- But vsync edge counter `core_vs_edge_cnt` not reaching 3
- **Bug**: Check [emu.sv:464](emu.sv#L464) - vsync edge detection on `clk_vid` domain

### Scenario 4: Memory Stall
```
L:1 A:0 B:1 V:1 X:000 Y:000
```
**Problem**: SDRAM permanently busy
- Decoder stuck waiting for memory
- Check: `mem_shim.sv` - is `mem_req_rd_en` continuous?
- Check: SDRAM controller responding?
- This was **Bug #1** from MEMORY.md

### Scenario 5: Active But Still Black Screen
```
L:1 A:1 B:0 V:1 X:2D0 Y:240
```
**Problem**: Decoder active, but video MUX not working
- Check: RGB values from decoder (add to UART debug)
- Check: `VGA_SCALER` setting
- Check: Video clock domain crossing

### Scenario 6: X/Y Stuck at Zero Despite Active
```
L:1 A:1 B:0 V:1 X:000 Y:000
```
**Problem**: Position counters not incrementing
- Vsync edges detected (A=1) but no pixel counting
- Check: `pixel_en` from decoder
- Check: Video output timing generation

## Recommended Additional Debug Signals

To enhance debugging, consider adding these signals to [uart_debug.sv](rtl/uart_debug.sv):

```systemverilog
// Add to uart_debug module inputs:
input picture_start,          // New picture being decoded
input sequence_header_valid,  // Sequence header found
input [7:0] r_sample,         // Sample RGB values
input [7:0] g_sample,
input [7:0] b_sample,
input pixel_en,               // Pixel enable signal
input h_sync,                 // Actual hsync/vsync
input v_sync
```

Output format could become:
```
L:1 A:1 B:0 V:1 X:2D0 Y:240 P:1 S:1 RGB:80:FF:20 PE:1
```

## Expected Normal Operation

When working correctly, you should see progression like:

```
# Initial state (no file)
L:1 A:0 B:0 V:0 X:000 Y:000

# File loaded
L:1 A:0 B:0 V:1 X:000 Y:000

# First vsync after ~1 frame time (~40ms for PAL)
L:1 A:0 B:0 V:1 X:2D0 Y:240

# After 3 vsyncs (~120ms)
L:1 A:1 B:0 V:1 X:2D0 Y:240  ← Active! Should see video now
```

X/Y values should change over time as different parts of the frame are being rendered:
- X typically ranges 0 → horizontal_resolution
- Y typically ranges 0 → vertical_resolution
- For 720×576 PAL: X up to 0x2D0 (720), Y up to 0x240 (576)

## Common Issues Based on MEMORY.md

From previous debugging sessions:

1. **mem_req_rd_en pulsing instead of continuous** → B stuck at 1
2. **Address mapping wrong** → Corrupted video/artifacts (not black screen)
3. **SDRAM BUSY not respected** → Corrupted video/artifacts
4. **watchdog_rst feedback loop** → L goes 0/1 randomly, system resets
5. **VGA_SCALER=1 with ascal** → Black screen despite A:1

## Next Steps Based on UART Output

Record the UART output for 10-15 seconds and analyze:
- Does `V` (valid) ever go to 1? → Stream loading issue
- Does `X/Y` ever change? → Vsync generation issue
- Does `A` (active) ever go to 1? → Vsync detection or counter issue
- Does `B` (busy) toggle? → Memory system health
- Is `L` (locked) always 1? → Clock stability

Share the captured UART log to get specific guidance on the failure mode.
