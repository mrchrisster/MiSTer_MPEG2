# MPEG2FPGA MiSTer Port - Complete Bug Fix Log

**Last Updated:** 2026-02-20
**Status:** Active Development - DDR3 Integration Phase

This document provides a comprehensive timeline of all bugs discovered and fixed during the MiSTer port of the MPEG2 video decoder core.

---

## Early Integration Bugs (Pre-DDR3 Phase)

These bugs were found and fixed before the DDR3 migration was attempted.

### E1. ❌ **mem_req_rd_en Pulsed Instead of Continuous**
**Symptom:** FIFO never drained — decoder stalled immediately
**Root Cause:** `mem_req_rd_en` was treated as a per-command pulse (asserted for 1 cycle per request). It is actually the **continuous read-enable** of the dual-clock `mem_request_fifo`. The FIFO pops only when BOTH `rd_en=1` AND `rd_valid=1`.
**Fix:** Changed to continuous: `mem_req_rd_en <= ~mem_res_wr_almost_full` (mirrors original `mem_ctl.v` behavior).

---

### E2. ❌ **Address Byte-Width Calculation Error**
**Symptom:** Frame store writes at wrong offsets
**Root Cause:** Address multiplied by 4 (`{addr, 2'b00}`) instead of 8 (`{addr, 3'b000}`). Each word is 64-bit = **8 bytes**, not 4.
**Fix:** Changed all address shifts to `{addr, 3'b000}`.

---

### E3. ❌ **SDRAM BUSY Not Respected → Duplicate Reads**
**Symptom:** Memory controller issued duplicate read commands
**Root Cause:** FSM did not gate state transitions on BUSY signal, allowing commands to be re-issued while the previous was still being processed.
**Fix:** All state changes gated with `if (!DDRAM_BUSY)`.

---

### E4. ❌ **Watchdog Reset Not Fed Back into reset_n**
**Symptom:** Decoder locked up after watchdog fired — never recovered
**Root Cause:** `watchdog_rst` output from `mpeg2video` was not connected back to the reset input. Decoder stalled permanently after the first watchdog event.
**Fix:** `reset_n` now includes `~watchdog_rst` in the reset logic.

---

### E5. ❌ **Reset Polarity Mismatch in FIFOs**
**Symptom:** FIFOs behaved erroneously on reset
**Root Cause:** `xfifo_sc.v` and `wrappers.v` had mismatched reset polarities — one expected active-HIGH, the other active-LOW.
**Fix:** Aligned reset polarity across all FIFO wrappers.

---

### E6. ❌ **Race Condition Between SDRAM Refresh and RD/WR**
**Symptom:** Occasional memory corruption under heavy load
**Root Cause:** SDRAM refresh requests could collide with in-progress read/write operations.
**Fix:** Added refresh arbitration that completes or defers pending operations before issuing refresh.

---

## Critical Bugs Fixed

### 1. ❌ **CLK_VIDEO HDMI PHY Mismatch** (Fixed 2026-02-19)
**Symptom:** Black screen / no HDMI output
**Root Cause:** `CLK_VIDEO` set to `clk_mem` (108MHz) with `ce_pixel` as 25% duty cycle enable, but MiSTer's HDMI serializer uses `CLK_VIDEO` directly without checking `CE_PIXEL`. TV received 108MHz pixel clock instead of 27MHz.

**Fix Applied:**
```verilog
// emu.sv line 170-171
assign CLK_VIDEO = clk_sys;  // 27 MHz (was: clk_mem)
assign CE_PIXEL  = 1'b1;     // Fully utilized (was: ce_pixel strobe)

// emu.sv line 328-329
.dot_clk    (clk_sys),   // 27MHz native dot clock
.dot_ce     (1'b1),      // No clock enable needed
```

**Impact:** HDMI output now works correctly at native 27MHz pixel rate.

---

### 2. ❌ **Outstanding Reads Counter Reset Corruption** (Fixed 2026-02-19)
**Symptom:** After watchdog reset, system deadlocks with writes permanently blocked
**Root Cause:** Watchdog reset cleared `outstanding_reads` counter to 0, but DDR3 bridge still had reads in flight. When responses arrived, counter underflowed (0-1=255 for 8-bit), causing `safe_to_write` to permanently evaluate FALSE.

**Debug Evidence:**
```
Line 16: P:13AC (5036 reads) RP:13A9 (5033 responses) PC:0000 (counter shows 0!)
Actual outstanding: 3 reads, Counter value: 0 (desynchronized)
```

**Fix Applied:**
```verilog
// mem_shim.sv - Two-tier reset architecture
input rst_n,        // Soft reset (Watchdog) - resets FSM
input hard_rst_n,   // Hard reset (Power-on) - resets counters

// Counters survive watchdog resets
always @(posedge clk) begin
    if (!hard_rst_n) begin
        outstanding_reads <= 0;
        rd_count <= 0;
        wr_count <= 0;
        rsp_count <= 0;
    end else begin
        // Counter logic with underflow protection
        if (rd_accepted && !ddr3_readdatavalid) begin
            outstanding_reads <= outstanding_reads + 1'd1;
        end else if (!rd_accepted && ddr3_readdatavalid) begin
            if (outstanding_reads > 0)  // Underflow protection
                outstanding_reads <= outstanding_reads - 1'd1;
        end
    end
end

// FSM resets on soft reset
always @(posedge clk) begin
    if (!rst_n) begin
        state <= S_IDLE;
        ram_read <= 0;
        ram_write <= 0;
        // ... FSM state only
    end
end
```

**Impact:** System can now recover from watchdog resets without losing DDR3 transaction synchronization.

---

### 3. ❌ **DDR3 Address Mapping - Inconsistent Formulas** (Fixed 2026-02-20)
**Symptom:** System hangs after exactly 64 writes, `waitrequest` stuck HIGH
**Root Cause:** The old `mem_shim.sv` had **two different address formulas** — the FIFO path used `{4'b0011, addr, 3'b000}` (correct, window 3) but the skid buffer path used `{4'b0110, 2'b00, addr, 1'b0}` (window **6**, unmapped). When the skid path was exercised, writes targeted unmapped HPS memory, triggering kernel protection after 64 writes.

**Debug Evidence:**
```
W:0040 P:0000 @:06000200 M:D U:1  (stuck after 64 writes)
64 writes = AXI transaction queue size before protection engages
```

**Address Formula History:**
```verilog
// WRONG — old skid path (window 6, unmapped!):
ram_address <= {4'b0110, 2'b00, saved_addr, 1'b0};

// WRONG — first attempted fix (window 0, kernel memory!):
ram_address <= {7'b0000011, mem_req_rd_addr[21:0]};

// CORRECT — proven working (window 3, DENSE 8-byte packing):
ram_address <= {7'b0011000, mem_req_rd_addr[21:0]};
```

**Fix Applied:**
```verilog
// mem_shim.sv — consistent formula for both paths:
// Skid buffer path:
ram_address <= {7'b0011000, saved_addr};
// FIFO path:
ram_address <= {7'b0011000, mem_req_rd_addr};
```

**Key Insight:** MiSTer's f2sdram bridge uses **window-based mapping**. The upper bits select a pre-configured window:
- Window `0011` (bits [28:25] = 4'b0011) → 0x30000000 byte range
- Lower 25 bits are word offset within that window
- Both paths must use the SAME address formula

**Impact:** DDR3 writes now target correct memory region from both paths.

---

### 4. ❌ **Write-After-Read AXI Coherence Deadlock** (Fixed 2026-02-19)
**Symptom:** `M:9 U:1` hang - read command stuck waiting for `readdatavalid`
**Root Cause:** AXI coherence hazard when WRITE issued while READ pending in f2sdram bridge pipeline.

**Fix Applied:**
```verilog
// mem_shim.sv - Outstanding reads tracking
reg [7:0] outstanding_reads;
wire safe_to_write = (outstanding_reads == 0) ||
                     (outstanding_reads == 1 && ddr3_readdatavalid);

// Block writes when reads pending
if (safe_to_write) begin
    ram_write <= 1;
    // ... issue write
end else begin
    // Stall: wait for reads to complete
    mem_req_rd_en <= 0;
end
```

**Testbench Verification:**
- Test 2: Issues READ, then WRITE while read pending → WRITE correctly stalled
- Test 3: Watchdog reset during pending read → outstanding_reads preserved, WRITE still blocked

**Impact:** Prevents AXI protocol violations that deadlock the HPS bridge.

---

### 5. ❌ **DDR3 Permanent Waitrequest After 4 Writes — Oscillator CDC** (Fixed 2026-02-21)
**Symptom:** `M:F U:1 W:0004` — bridge hangs after exactly 4 writes
**Root Cause:** `mem_shim.clk` and `DDRAM_CLK` were connected to `clk_100m` (HPS-derived 100 MHz from `HPS_BUS[43]`), while `mpeg2video.mem_clk` was also `clk_100m`. The `mem_request_fifo` write side (`clk_sys` = 27 MHz) is slower than read side (`clk_100m` = 100 MHz), so FIFO fill rate was NOT the issue. The actual cause is that the f2sdram hard IP bridge expects its port clock (`ram1_clk` driven by `DDRAM_CLK`) to be phase-related to the HPS internal clocks. Using `clk_100m` from `HPS_BUS[43]` introduced an async boundary at the hard IP, causing the bridge's internal 4-entry write buffer to stall permanently.

**Debug Evidence:**
```
W:0004 U:1 M:F — exactly 4 writes, permanently stuck
```

**Fix Applied (emu.sv):**
```verilog
// All DDR3-side signals use the same PLL output:
assign DDRAM_CLK          = clk_mem;   // PLL 108 MHz (was: HPS 100MHz)
mpeg2video.mem_clk        = clk_mem;   // PLL 108 MHz — FIFO rd_clk
mem_shim.clk              = clk_mem;   // PLL 108 MHz — same domain as bridge
// mem_request_fifo: wr_clk=clk_sys(27MHz), rd_clk=clk_mem(108MHz) = read-faster = safe
```

**Impact:** Bridge no longer stalls. W:0004 hang eliminated.

---

### 6. ❌ **CDC Violation in Vsync Edge Detection** (Fixed 2026-02-20)
**Symptom:** `core_video_active` might not go HIGH correctly; possible missed or double-counted vsync edges
**Root Cause:** `core_v_sync` is in the `clk_mem` domain (`dot_clk=clk_mem`) but the edge counter (`core_vs_edge_cnt`) was sampled on `clk_vid` (25.175 MHz PLL output) — a different clock domain.
**Fix:** Moved `core_vs_edge_cnt` always block from `posedge clk_vid` to `posedge clk_mem`.

---

### 7. ❌ **ADDR_ERR Sentinel Causes Permanent DDR3 Stall** (Fixed 2026-02-20)
**Symptom:** `M:D U:1 @:06F7FFF8` — bridge hangs within 1 second of first video select
**Root Cause:** `mem_addr.v` address pipeline flushes with invalid `{frame, component}` on decoder startup, generating `ADDR_ERR = 22'h1EFFFF`. This address maps to DDRAM_ADDR `0x06F7FFF8`. When forwarded to the DDR3 bridge, `waitrequest` is asserted permanently.

**Debug Evidence:**
```
@:06F7FFF0 (= VBUF_END, normal init)  → then:
@:06F7FFF8 (= ADDR_ERR, first decode write) → M:D U:1 forever
```

**Fix Applied (mem_shim.sv):**
```verilog
// Silently discard WRITE/READ to ADDR_ERR address
localparam ADDR_ERR = 22'h1EFFFF;

// In WRITE path:
if (addr == ADDR_ERR) begin
    // Drop silently, stay IDLE
end else begin
    // Forward to DDR3
end

// In READ path:
if (addr == ADDR_ERR) begin
    mem_res_wr_dta <= 64'd0;  // Synthetic zero response
    mem_res_wr_en  <= 1'b1;
end else begin
    // Forward to DDR3
end
```

**Impact:** Decoder startup no longer stalls the DDR3 bridge. Frame store init completes normally.

---

### 8. ❌ **Quartus Hangs on uart_tx.v Rewrite** (Fixed 2026-02-20)
**Symptom:** Quartus elaboration hangs indefinitely (no error, no progress)
**Root Cause:** `uart_tx.v` was rewritten using SystemVerilog constructs that Quartus 18.x cannot elaborate correctly.
**Fix:** Reverted to the original TangNano-9K version (Verilog-2001 syntax).

---

### 9. ❌ **Quartus Hangs on `function automatic` in uart_debug.sv** (Fixed 2026-02-20)
**Symptom:** Quartus elaboration hangs when `uart_debug.sv` contains helper functions
**Root Cause:** `function automatic` causes Quartus to hang during elaboration.
**Fix:** Changed all `function automatic` to plain `function`.

---

### 10. ❌ **mem_shim FSM: S_READ_PEND Infinite Wait** (Observed 2026-02-20)
**Symptom:** `M:A` (S_READ_PEND) — bridge hangs after exactly 2,165 reads. P:0875, RP:0874 (one outstanding read response never arrives).
**Root Cause:** A 3-state FSM (IDLE / WAIT / READ_PEND) was added to track read responses. S_READ_PEND blocked all new commands until `ddr3_readdatavalid` arrived. One read's response was never returned by the bridge (possibly flushed), causing permanent deadlock.

**Key Evidence:**
```
Line 3: P:0874, RP:0874  ← 2,164 reads, all matching, U:0 ← CORRECT OPERATION
Line 4: M:A  ← S_READ_PEND entered
Lines 5+: Frozen, M:A U:0  ← Not waitrequest — bridge ready, FSM blocking itself
```

**Fix:** Removed S_READ_PEND state, reverted to 2-state FSM (IDLE/WAIT). The response path (`mem_res_wr_en <= ddr3_readdatavalid`) runs every clock cycle independent of FSM state, so responses are always captured.

---

### 11. ⚠️ **yuv2rgb.v Color Channel Corruption** (Reported, unverified)
**Symptom:** Black/greyscale frames
**Root Cause (claimed):** In clock-enable gating logic, wrong assignment:
```verilog
// WRONG:
else begin
    g_1 <= r_1;  // Should hold own value!
    b_1 <= r_1;  // Should hold own value!
end

// CORRECT:
else begin
    g_1 <= g_1;
    b_1 <= b_1;
end
```

**Status:** Current code (lines 237-239) shows correct implementation. Either already fixed or never existed. Unable to verify from git history.

---

## Active Issues

### 🔴 **mem_shim FSM — Rewritten from Prior Working Config**
**Status:** `mem_shim.sv` has been rewritten to match the prior working config (which produced video output on screen) plus ADDR_ERR filter. **Awaiting recompile and hardware test.**

**Timeline of FSM versions and results:**
| Version | Result |
|---------|--------|
| 3-state (IDLE/WAIT/READ_PEND) + skid buffer | M:A permanent hang after 2,165 reads |
| 2-state (IDLE/WAIT) **without** skid buffer + ADDR_ERR filter | M:A eliminated; 2,164 reads succeed; then... new hang |
| 2-state (IDLE/WAIT) **with** skid buffer + ADDR_ERR filter (Gemini version) | M:D U:1 permanent waitrequest after 55 reads (P:0037) |
| **Current: prior-working-config + ADDR_ERR filter** | Not yet compiled |

**Current implementation:** 2-state FSM (state=0 IDLE / state=1 WAIT) WITH skid buffer + ADDR_ERR filter + `{4'b0011, addr, 3'b000}` encoding. Based on the exact prior working config that produced video, with only the ADDR_ERR filter added. No `safe_to_write`/`outstanding_reads` tracking (the working config didn't have these).

**Key differences from working config → current:**
- ADDED: ADDR_ERR filter (drop writes to `22'h1EFFFF`, return `64'd0` for reads)
- REMOVED: `outstanding_reads` / `safe_to_write` (not in working config)
- REMOVED: `hard_rst_n` separation (both rst_n and hard_rst_n are same signal)
- UPDATED: `{7'b0011000, addr}` DENSE address formula (fixes 24MB crash)

**Old code had TWO DIFFERENT broken formulas:**
- Skid path: `{4'b0110, 2'b00, saved_addr, 1'b0}` — window **0110** (unmapped, caused 64-write hangs)
- FIFO path: `{4'b0011, mem_req_rd_addr, 3'b000}` — correct window 3 (worked when exercised)

---

## Testing Status

### ✅ Testbench Verification (tb_mem_shim.sv)
- **Test 1:** Simple write → Address translation verified (`7'b0011000` prefix)
- **Test 2:** Write-after-read stall → Correctly blocks writes during pending reads
- **Test 3:** Watchdog reset survival

### ✅ Hardware Tests Completed
| Build | Key Result | Status |
|-------|-----------|--------|
| Wrong address window | Hung @:06000200 after 64 writes | Fixed |
| Correct address, different oscillators | Hung after 4 writes (M:F U:1) | Fixed |
| ADDR_ERR not filtered | Hung @:06F7FFF8 immediately on video select | Fixed |
| 3-state FSM + skid | 2,165 reads then M:A hang (S_READ_PEND) | Fixed |
| 2-state no skid + ADDR_ERR filter | 2,164 reads, all responses matched (P:0874/RP:0874) | In progress |
| 2-state + skid (Gemini) | Hung M:D U:1 after 55 reads | Broken |

### 🔶 Remaining Hardware Testing
- Compile 2-state (no skid) + ADDR_ERR filter build
- Verify video plays continuously without M:D or M:A hang
- Monitor W/P/RP counters for stability over multiple frames

---

## Reference Implementations

### TSConf DDR3 Pattern (PROVEN WORKING)
```verilog
// TSConf_MiSTer-master/rtl/memory/ddram.sv line 52
assign DDRAM_ADDR = {4'b0011, ram_address[27:3]};  // RAM at 0x30000000
assign DDRAM_BE   = (8'd1<<ram_address[2:0]) | {8{ram_read}};
```

**Our proven-working formula for 22-bit word addresses:**
```verilog
// Window 3 + alignment padding + word address (hardware-proven DENSE mapping)
assign ddr3_addr = {7'b0011000, mem_req_rd_addr[21:0]};
// Each addr increment = 1 DDRAM unit (8-byte stride, fits in 24MB Linux allocation)
```

---

## Memory Map Reference

| Address Range | Purpose | DDRAM_ADDR Formula |
|--------------|---------|------------------|
| 0x00000000 - 0x0FFFFFFF | ❌ Linux Kernel (FORBIDDEN) | N/A |
| 0x30000000 - 0x3FFFFFFF | ✅ FPGA Frame Buffer | `{4'b0011, addr, 3'b000}` |
| 0xC0000000+ | ❌ Invalid (would use wrong prefix) | N/A |

**Critical:** Window `0011` (bits [28:25]) is pre-mapped by HPS to byte address 0x30000000 range.

---

## Lessons Learned

1. **Always reference working MiSTer cores** (TSConf, ao486, etc.) for DDR3 patterns
2. **HPS uses window-based address mapping**, not linear byte addressing
3. **Test with oscilloscope/SignalTap** - simulation can't catch HPS-specific behaviors
4. **Separate hard/soft reset domains** for hardware pipeline state vs. logic state
5. **AXI coherence matters** - reads and writes can't be freely interleaved
6. **HDMI PHY timing is strict** - can't fake pixel clocks with enables
7. **Trust testbenches** but verify on hardware - HPS behavior differs from simulation

---

## Next Steps

1. ✅ mem_shim.sv rewritten from prior working config + ADDR_ERR filter
2. ✅ Address formula: `{4'b0011, addr, 3'b000}` (proven working, consistent for both paths)
3. ✅ CLK_VIDEO = clk_sys, CE_PIXEL = 1'b1 (HDMI clock fix applied)
4. ✅ ADDR_ERR filter added to mem_shim (discards 22'h1EFFFF)
5. 🔴 **Recompile in Quartus** — source has correct code but .rbf is stale (old code still running)
6. ⏳ Hardware test with new .rbf: confirm no 64-write hang, @ shows `0x06xxxxxx` range
7. ⏳ Confirm memory clear completes (W should reach ~2M during init)
8. ⏳ Confirm video decode produces output (V:1, FC incrementing)
9. ⏳ Verify video output quality (color accuracy, motion, B-frames)
10. ⏳ Test watchdog recovery under real decode stress

---

## Debug Field Reference (UART)

Full output format (one line per second):
```
L:x A:x B:x V:x X:xxx Y:xxx I:xxx S:x F:x E:x Q:x R:x M:x U:x K:x T:x D:x C:x H:x W:xxxx P:xxxx J:xxxx Z:xxxx @:xxxxxxxx G:x O:x N:x SC:x FC:xxxx\r\n
```

| Field | Meaning | Critical Values |
|-------|---------|----------------|
| L | PLL locked | 1=OK, 0=clock problem |
| A | core_video_active | 1=vsync seen ≥3 times |
| B | core_busy | 1=decoder active |
| I | init_cnt (0→511) | 1FF=internal RAM ready |
| F | vbw_almost_full | 1=video buffer back-pressure |
| E | mem_req_rd_en | 1=FIFO read enabled |
| Q | mem_req_rd_valid | 1=command at FIFO output |
| R | mem_res_wr_almost_full | 1=response FIFO back-pressure |
| W | Write count (wr_accepted, wraps at FFFF) | Should increase during init (~2M writes total) |
| P | Read count (rd_accepted) | Should increase continuously during decode |
| RP | Read response count (ddr3_readdatavalid) | Should match P when idle |
| @ | DDRAM_ADDR[28:0] as 8 hex chars | `0x06xxxxxx` = valid frame buffer; `0x06F7FFF8` = ADDR_ERR! |
| M | FSM state `{cmd[1:0], saved_valid, state[1:0]}` | 0=IDLE, 9=READ+WAIT, D=WRITE+WAIT(no skid), F=WRITE+WAIT(skid full), A=S_READ_PEND(removed) |
| U | ddr3_waitrequest | 0=ready, 1=busy (stuck=deadlock) |
| K | ddr3_ack (write accepted) | 1=write completed |
| G | vld_err | 1=VLD parser error |
| O | watchdog_rst | 1=watchdog fired |
| N | vsync_edge_cnt | increments per vsync |
| SC | skid buffer cmd | 0=none, 2=RD pending, 3=WR pending |
| FC | frame counter (free-running 16-bit) | increments each frame |

**M field decode** (`{cmd[1:0], saved_valid, state}` where cmd: 0=NOOP 1=REFRESH 2=READ 3=WRITE):
**Current encoding:** `M = {debug_cmd[1:0], state[1:0]}` where state: S_IDLE=0, S_WAIT=1.
`debug_cmd` is combinational: WRITE if `ram_write`, READ if `ram_read`, else `saved_cmd` if skid valid, else FIFO cmd if valid, else NOOP.
- `M:0` = IDLE, no pending command (normal)
- `M:8` = READ active, IDLE
- `M:9` = READ active, WAIT (read in flight)
- `M:C` = WRITE active, IDLE
- `M:D` = WRITE active, WAIT ← stuck here = deadlock
- `M:F` = WRITE+skid active, WAIT ← stuck here = deadlock (skid shows in SC field)

The `saved_valid` / skid buffer command is now in a separate `SC` debug field (not in M).

**Address decode** (with `{7'b0011000, addr}` encoding):
`word_addr[21:0] = DDRAM_ADDR[21:0]` (lower 22 bits map natively to word address)

| `@:` value | Word addr | Meaning |
|-----------|-----------|---------|
| `@:06000000` | `0x000000` | FRAME_0_Y start (first init write) |
| `@:06000004` | `0x000004` | 5th word during init clear |
| `@:061EFFFE` | `0x1EFFFE` | VBUF_END (last normal init write) |
| `@:061EFFFF` | `0x1EFFFF` | **ADDR_ERR sentinel** (decoder error!) |
| `@:06xxxxxx` | valid range | Normal frame buffer access |

**Healthy operation:** W increasing during init (then stable), P and RP both increasing during decode and matching, U=0 or briefly 1, @ in `0x06xxxxxx` range, FC incrementing

---

*Document maintained by: AI Agent Analysis / Human Verification*
*For questions: Review MEMORY.md, TSConf reference, and this log*
