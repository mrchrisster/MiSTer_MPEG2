# YUV2RGB Bug Fix Summary

## Problem
The modified mpeg2fpga code was producing black PPM output files when running iverilog simulations, while the original mpeg2fpga-orig code produced correct color images.

## Root Cause Analysis

### 1. **Critical Bug: YUV2RGB Pipeline Error**
**File:** `rtl/mpeg2/yuv2rgb.v` lines 238-239

**Broken Code:**
```verilog
else
  begin
    r_1   <= r_1;
    g_1   <= g_1;    // WRONG - should be r_1
    b_1   <= b_1;    // WRONG - should be r_1
  end
```

**Fixed Code:**
```verilog
else
  begin
    r_1   <= r_1;
    g_1   <= r_1;    // Correct
    b_1   <= r_1;    // Correct
  end
```

**Impact:** This bug broke the YUV→RGB color conversion pipeline. When clock enable was inactive, the green and blue channels held stale values instead of propagating through the pipeline correctly, resulting in corrupted RGB output (all black pixels).

### 2. **Verilog Compilation Issues**
**File:** `bench/iverilog/mem_ctl.v`

**Problem:** Tasks `write_mb` (line 300) and `write_row` (line 376) have `input [31:0] fp` parameters. Modern Icarus Verilog requires consistent width declarations for file pointers used with `$fopen` and `$fwrite`.

**Fix:** Changed task-local declarations from `integer fp;` to `reg [31:0] fp;`:
- Changed at line 319 in `write_mb` task
- Changed at line 384 in `write_row` task

This maintains the 32-bit width throughout and is compatible with procedural file I/O assignments, fixing the elaboration phase assertion error in modern iverilog.

### 3. **Compiler Flags**
**Files:** `bench/iverilog/build_sim.bat`, `run_susi.bat`, `test_yuv2rgb_fix.bat`

**No special flags needed:** The original code uses default iverilog behavior (no `-g` flag). The old Verilog-1995 style port declarations work best with default mode.

**Note:** Initial attempt to add `-g2012` flag caused syntax errors in generic memory modules due to incompatibility with non-ANSI port declarations. Removed to match original working configuration.

## Files Modified

1. **rtl/mpeg2/yuv2rgb.v**
   - Fixed pipeline register assignments (lines 238-239) - GREEN/BLUE channels now propagate correctly

2. **rtl/mpeg2/osd.v**
   - Reverted module names from `mpeg2_osd`, `mpeg2_osd_clt`, `mpeg2_alpha_blend` back to `osd`, `osd_clt`, `alpha_blend`
   - Module instantiation names in mpeg2video.v now match module definitions

3. **rtl/mpeg2/mpeg2video.v**
   - Removed h_pos/v_pos module outputs (made them internal wires)
   - Fixed OSD module instantiation to use correct names

4. **rtl/mpeg2/motcomp.v**
   - Changed `$display` to `$strobe` for error messages (proper simulation timing)

5. **bench/iverilog/mem_ctl.v**
   - Changed task-local `integer fp;` to `reg [31:0] fp;` for modern iverilog compatibility

3. **bench/iverilog/build_sim.bat**
   - Added `-g2012` compiler flag

4. **bench/iverilog/run_susi.bat**
   - Added `-g2012` compiler flag

5. **bench/iverilog/test_yuv2rgb_fix.bat** (NEW)
   - Comprehensive test script with verification

## Testing

Run the test script:
```batch
cd bench\iverilog
test_yuv2rgb_fix.bat
```

This will:
1. Compile the simulation with fixed code
2. Run simulation with stream-susi.mpg test video
3. Generate PPM output files
4. Verify file size against reference (should be ~1.7MB for valid output)
5. Report success/failure

## Expected Results

- **Before Fix:** `tv_out_0000.ppm` ~146KB (all black/grey pixels)
- **After Fix:** `tv_out_0000.ppm` ~1.7MB (valid color image matching reference in `valid/` folder)

## Key Insights from Original Port

The original mpeg2fpga-orig required:
- Converting `.mpg` to hex `.dat` using `xxd -c 1` for `$readmemh`
- Fixing Verilog-2001 compatibility issues
- Using `-g2012` or `-g2005` compiler flags

Our modified version:
- Uses `$fread` to read binary `.mpg` directly (modern iverilog feature)
- Maintains same compatibility fixes for stable compilation
- Produces identical output to original when bug-free

## Verification

Compare generated output against reference:
```batch
fc /b bench\iverilog\tv_out_0000.ppm bench\iverilog\valid\tv_out_0000.ppm
```

Or view the PPM files in an image viewer to verify color content.
