# YUV2RGB Black Screen Bug Analysis

## Problem
iverilog simulation produces black PPM files instead of decoded video.

## Root Cause
The ported `yuv2rgb.v` has a **pipeline timing mismatch** between RGB data and control signals (pixel_en, h_sync, v_sync).

## Detailed Analysis

### RGB Pipeline Stages (both original and modified)
When `clk_en` is asserted:
1. **Cycle 0**: Input y,u,v → compute offsets (y_offset, u_offset, v_offset)
2. **Cycle 1**: Multiply coefficients (cy_y, crv_v, etc.) → add (r_0, g1_0, g2_0, b_0) → shift (r_1, g_1, b_1)
3. **Cycle 2**: Clip (r_1 → r, g_1 → g, b_1 → b) **[OUTPUT]**

**Total RGB pipeline: ~3 clk_en cycles** (with some combinational within each stage)

### Control Signal Pipeline

**ORIGINAL (mpeg2fpga-orig/rtl/mpeg2/yuv2rgb.v):**
```verilog
pixel_en_0 <= pixel_en_in;   // Stage 1
pixel_en_1 <= pixel_en_0;    // Stage 2
pixel_en_2 <= pixel_en_1;    // Stage 3
pixel_en_out <= pixel_en_2;  // Stage 4 [OUTPUT]
```
**Total: 4 clk_en cycles** → 1 cycle more than RGB (may be intentional for other timing reasons)

**MODIFIED (rtl/mpeg2/yuv2rgb.v):**
```verilog
pixel_en_0 <= pixel_en_in;   // Stage 1
pixel_en_1 <= pixel_en_0;    // Stage 2
pixel_en_2 <= pixel_en_1;    // Stage 3
pixel_en_3 <= pixel_en_2;    // Stage 4  ← EXTRA STAGE ADDED
pixel_en_out <= pixel_en_3;  // Stage 5 [OUTPUT]
```
**Total: 5 clk_en cycles** → 2 cycles more than RGB!

## Why This Causes Black PPMs

In [testbench.v:360](bench/iverilog/testbench.v#L360):
```verilog
else if (pixel_en) $fwrite(fp, "%3d %3d %3d\n", r, g, b);
else if (v_sync || h_sync) $fwrite(fp, "  0   0   0\n");  // BLACK
else $fwrite(fp, " 48  48  48\n");  // GRAY
```

With the timing mismatch:
- RGB data for pixel arrives at cycle N
- `pixel_en` arrives at cycle N+1 (too late)
- When `pixel_en` goes high, RGB has already moved to the NEXT pixel
- During the actual pixel time, `pixel_en` is LOW but `h_sync` or `v_sync` may be HIGH
- Result: black pixels written (0 0 0) instead of actual RGB values

## Other Bug Fixed (Good!)

The original code had a CRITICAL bug at lines 238-239:
```verilog
else    // when clk_en is LOW  begin
    r_1   <= r_1;
    g_1   <= r_1;  // BUG! Should be g_1
    b_1   <= r_1;  // BUG! Should be b_1
  end
```

This was correctly fixed in the port to:
```verilog
    r_1   <= r_1;
    g_1   <= g_1;  // FIXED
    b_1   <= b_1;  // FIXED
```

This fix is CORRECT and must be kept.

## Solution

**Remove the extra pipeline stage (_3) that was incorrectly added during the port.**

The delay pipeline should match the original: `_0 → _1 → _2 → _out` (4 stages)

### Files to Fix
1. `rtl/mpeg2/yuv2rgb.v` - remove all references to `pixel_en_3`, `h_sync_3`, `v_sync_3`, `y_3`, `u_3`, `v_3`
2. Revert delay chains to original 4-stage depth
3. Keep the g_1/b_1 bug fix (lines 244-246)

## Verification

After fix, check:
1. iverilog simulation produces non-black PPM files
2. PPM shows expected greyramp pattern
3. RGB values are reasonable (not all 0 or all 255)
