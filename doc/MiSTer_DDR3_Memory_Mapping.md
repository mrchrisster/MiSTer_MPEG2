# MiSTer FPGA DDR3 Memory Mapping Guide

This document captures the physical DDR3 address mapping mechanism for the `f2sdram` bridge in the MiSTer Cyclone V Linux environment. It is crucial knowledge for porting bare-metal SDRAM cores to use the Terasic DE10-Nano onboard DDR3 memory via `sysmem.sv`.

## The `waitrequest` 64-Write Hang
If your core interfaces with the `sysmem` DDR3 Avalon-MM bridge and perfectly executes exactly **64 writes** before `waitrequest` asserts and never de-asserts, you have encountered an AXI/TrustZone memory bounds violation. 

The Cyclone V AXI Interconnect contains a **64-entry write FIFO**. If the HPS DDR3 controller rejects the transaction (because the address is unallocated, restricted by Linux, or nonexistent), the bridge silently accepts 64 transactions before the FIFO fills and permanently halts the bus.

## The Correct Memory Window (`0x30000000`)
The Linux kernel on the MiSTer HPS safely allocates memory for the FPGA fabric at a specific offset. It expects transactions to target the `0x30000000` **Byte Address** window.

However, the `sys_top.v` `ram_address` ports (e.g. `ram1_address[28:0]`) are configured in **64-bit Words**, not bytes. Therefore:
- **Byte Address**: `0x30000000`
- **64-bit Word Address**: `0x30000000 >> 3 = 0x06000000`

## TSConf Implementation Pattern (PROVEN WORKING)
TSConf successfully accesses the 0x30000000 byte range using:
```verilog
assign DDRAM_ADDR = {4'b0011, ram_address[27:3]};  // RAM at 0x30000000
```

Where `ram_address` is a **byte address**, and `[27:3]` extracts the **word portion** (25 bits).

### HPS Window-Based Mapping (CRITICAL UNDERSTANDING)
The MiSTer f2sdram bridge uses **window-based addressing**, NOT linear byte addresses:
- DDRAM_ADDR bits [28:25] = Window selector (4 bits)
- DDRAM_ADDR bits [24:0] = Offset within window (25 bits)
- Window `4'b0011` is **pre-mapped by HPS** to byte address 0x30000000 range

### Mapping for 22-bit Word Addresses

**The DENSE Formula (CORRECT - Verified on Hardware)**
```verilog
ram_address <= {7'b0011000, mem_req_addr[21:0]};       // Window + padding + addr
// Equivalently: {4'b0011, 3'b000, mem_req_addr[21:0]}
```
- Places the 3-bit alignment padding *before* the address, preventing left-shifting.
- Each addr increment = 1 DDRAM unit = 8 bytes in DDR3 (dense, ~16 MB total memory used).
- Perfectly matches TSConf's dense `{4'b0011, byte_addr[27:3]}` pattern.
- Stays safely within the MiSTer Linux 24 MB frame buffer limit.

**The SPARSE Formula (WRONG - Causes 24 MB Crash)**
```verilog
ram_address <= {4'b0011, mem_req_addr[21:0], 3'b000};  // Window + addr + padding
```
- Places the 3-bit alignment padding *after* the address, left-shifting the offset by 3!
- Each addr increment = 8 DDRAM units = 64 bytes in DDR3 (sparse, wastes DDR3 capacity).
- Max address `0x1EFFFF` requires ~124 MB of DDR3 memory!
- Crosses the HPS 24 MB memory allocation around `0x0601B2` (24.02 MB -> `DDRAM_ADDR=0x06300D90`). 
- Completely crashes the AXI bridge via Linux TrustZone memory isolation.

**Common Mistake:**
Using `7'b0000011` would create window `0000` (bits [28:25]), which is NOT mapped to 0x30000000!

---

## Two Types of Permanent Waitrequest Hangs

Both hangs produce `U:1` stuck HIGH, but have **different causes and different write counts**:

### A. 4-Write Hang — Clock Oscillator Mismatch
```
W:0004 U:1 M:F  (exactly 4 writes, then stuck)
```
**Cause:** `mpeg2video.clk` and `mem_clk` connected to clocks from **different oscillators** (e.g., PLL-derived 108 MHz vs HPS-derived 100 MHz). The `mem_request_fifo` write clock (108 MHz) runs faster than read clock (100 MHz). The f2sdram bridge has a **4-entry write buffer** — once full, `waitrequest` asserts permanently.

**Fix:** Both `mpeg2video.clk` and `DDRAM_CLK` / `mem_shim.clk` must use the **same PLL** (same oscillator). Even if numerically close (108 vs 100 MHz), different oscillators = truly async = eventual deadlock.

```verilog
// CORRECT — all from same PLL:
assign DDRAM_CLK          = clk_mem;  // PLL output
assign mpeg2video.mem_clk = clk_mem;  // same PLL output
assign mem_shim.clk       = clk_mem;  // same PLL output
```

### B. 64-Write Hang — Wrong Address Window (Skid Path Bug)
```
W:0040 U:1 @:06000200  (exactly 64 writes, then stuck)
```
**Cause:** The old `mem_shim.sv` had **two different address formulas** — the FIFO path used `{4'b0011, addr, 3'b000}` (correct, window 3) but the skid buffer path used `{4'b0110, 2'b00, addr, 1'b0}` (window **6**, unmapped). When the skid path was exercised, writes targeted unmapped memory. The 64-entry AXI transaction queue filled before the HPS protection mechanism engaged, permanently blocking the bus.

**Fix:** Use a single consistent address formula for both paths: `{4'b0011, addr, 3'b000}`.

### C. SPARSE Formula 24 MB Boundary Crossing
```
M:D U:1 @:06300D90  (stuck waiting at addresses > 0x06300000)
```
**Cause:** The SPARSE formula `{4'b0011, addr, 3'b000}` shifts addresses left by 3 bits, creating a 64-byte stride that exceeds the Linux 24 MB allocation:

```verilog
// WRONG — SPARSE formula (crosses 24 MB boundary):
ram_address <= {4'b0011, addr, 3'b000};  // 64-byte stride, 128 MB total
                                          // Max addr 0x1EFFFF uses ~124 MB!

// CORRECT — DENSE formula (stays within 24 MB):
ram_address <= {7'b0011000, addr};       // 8-byte stride, 16 MB total
                                          // Max addr 0x1EFFFF uses ~15.5 MB
```

**The Critical Math:**
- Debug showed hang at `@:06300D90`
- With SPARSE formula, extract addr: `(0x06300D90 >> 3) & 0x3FFFFF = 0x0601B2`
- Addr `0x0601B2` = 393,650 decimal (valid! < max 0x1EFFFF)
- **But:** 393,650 words × 64 bytes/word = 25,193,600 bytes = **24.02 MB**
- **Crosses Linux 24 MB TrustZone boundary!**

**Why SPARSE fails:**
- The MPEG2 core requested a perfectly valid logical address (`0x0601B2`)
- But SPARSE formula's 64-byte stride stretched it to 24 MB physical address
- HPS AXI bridge detects out-of-bounds access, asserts permanent `waitrequest`

**Fix:** Use DENSE formula `{7'b0011000, addr}` which places padding **between** window and address (NOT after), creating 8-byte stride that fits the entire framebuffer (up to addr 0x1EFFFF) into ~15.5 MB.

---

## Avalon-MM Protocol Requirements (f2sdram)

The f2sdram bridge implements Avalon-MM. Critical protocol rules:

```verilog
// 1. Use combinational assigns from registered regs (NOT registered outputs directly)
assign DDRAM_RD  = ram_read;    // combinational
assign DDRAM_WE  = ram_write;   // combinational

// 2. Gate ALL state changes on !DDRAM_BUSY
always @(posedge clk) begin
    if (!DDRAM_BUSY) begin
        // Safe to change DDRAM_RD, DDRAM_WE, DDRAM_ADDR, DDRAM_DIN
    end
end

// 3. Fixed burst parameters
assign DDRAM_BURSTCNT = 8'd1;    // single transfer only
assign DDRAM_BE       = 8'hFF;   // all 8 bytes enabled
```

**DO NOT:**
- Change address or data while `DDRAM_BUSY=1` (bridge may latch wrong values)
- Issue burst transfers > 1 (core uses single 64-bit word transfers)
- Leave DDRAM_CLK undriven — tie to `'0` if unused, or assign to PLL clock

---

## ADDR_ERR → DDR3 Address Mapping

The MPEG2 core generates a sentinel address `ADDR_ERR = 22'h1EFFFF` when `mem_addr.v` receives an invalid macroblock/component combination. Using the proven address formula `{4'b0011, addr, 3'b000}`, this maps to:

```
DDRAM_ADDR = {4'b0011, 22'h1EFFFF, 3'b000} = 0x06F7FFF8
           = byte address 0x30000000 + 0xF7FFF8 ≈ 0x30F7FFF8 (≈128 MB into framebuffer region)
```

In UART debug: `@:06F7FFF8` means the decoder is generating ADDR_ERR accesses.

**If forwarded to DDR3:** The bridge asserts `waitrequest=1` permanently because 0x30F7FFF8 is beyond the typical HPS FPGA memory allocation (usually 16–32 MB starting at 0x30000000).

**Fix in mem_shim.sv:** Silently discard all WRITE/READ to `22'h1EFFFF`:
- WRITE to ADDR_ERR: drop, stay IDLE
- READ from ADDR_ERR: return synthetic `64'd0`, pulse `mem_res_wr_en`

This is expected behaviour during decoder startup (pipeline flush) and should not be treated as an error in normal operation.

---

## Debug Address Decoding

The `@:xxxxxxxx` UART field shows `DDRAM_ADDR[28:0]` as 8 hex characters.

Using the proven address formula `{7'b0011000, addr[21:0]}`:
- `word_addr[21:0] = DDRAM_ADDR[21:0]` — bits [21:0] of DDRAM_ADDR directly map to the word address natively!
- Equivalently: `word_addr = (DDRAM_ADDR & 0x003FFFFF)`

Key landmarks:
| `@:` value | Word addr | Meaning |
|-----------|-----------|---------|
| `@:06000000` | `0x000000` | FRAME_0_Y start (first frame init write) |
| `@:061EFFFE` | `0x1EFFFE` | VBUF_END (last normal init write) |
| `@:061EFFFF` | `0x1EFFFF` | **ADDR_ERR sentinel — decoder error!** |
| `@:06xxxxxx` | valid range | Normal framebuffer access |

**Proven address formula:** `DDRAM_ADDR = {7'b0011000, word_addr[21:0]}`
- `bits[28:25]` = `0011` (window selector — HPS maps window 3 to byte 0x30000000)
- `bits[24:22]` = `000` (alignment padding logic to prevent address shifting)
- `bits[21:0]`  = `word_addr[21:0]` (22-bit natively mapped word address tightly packed)
- All valid framebuffer addresses easily decode directly from the lower 22 bits.
