# MiSTer MPEG2 FPGA Porting - Implementation Notes

This document chronicles the major architectural migrations, common pitfalls, and "What worked vs. What didn't work" discoveries during the porting of the bare-metal `mpeg2fpga` core to the MiSTer Cyclone V Linux ecosystem.

Future AI Agents and human developers should review these guidelines before making fundamental changes to clocking, memory, or I/O.

---

## 1. Video Clocking & The HDMI PHY (`emu.sv`)

The original core may have utilized a monolithic high-speed clock (e.g., 108MHz) and a synthesized clock-enable signal (`ce_pixel` toggling every 4 cycles).

*   **What Didn't Work**: Feeding the MiSTer HDMI/VGA PHY with a high-speed clock (`clk_mem`) and setting `CE_PIXEL` to strobe every 4th cycle. The physical MiSTer display scaler scaler/PHY natively requires a continuous, accurate dot clock.
*   **What Worked**:
    *   Generating a dedicated, native `clk_sys` or `clk_vid` (e.g., 27 MHz for 480i NTSC) from the `sys_pll`.
    *   Routing this native clock directly to `CLK_VIDEO`.
    *   Hard-wiring `CE_PIXEL = 1'b1` so the PHY runs symmetrically at the target resolution frequency.
    *   Passing `clk_sys` to the video core instantiations (e.g., `mpeg2video`) as their `dot_clk` input.

## 2. DDR3 Interfacing & AXI Coherence (`mem_shim`)

Interfacing with the HPS via `sysmem` (specifically `f2sdram_safe_terminator`) revealed severe TrustZone bounds violations and AXI cache coherence deadlocks that manifested as permanent `waitrequest` hangs.

*   **What Didn't Work**:
    *   **Direct Byte Math**: Extrapolating the Byte address (e.g., `0x30000000`) mathematically to the bridge. The `f2sdram` bus is a 29-bit 64-bit-word address. The correct mapping formula is `{7'b0011000, addr}` (DENSE: window 3 + padding + address). *(See `MiSTer_DDR3_Memory_Mapping.md` for the exact bitwise translation).*
    *   **Issuing Writes while Reads are Pending**: Firing an AXI write request (`ram_write`) while a read request is traversing the HPS. This triggers a write-after-read coherence lockdown in the bridge.
    *   **Single-Cycle FIFOs**: Relying on the core's FIFO to push data directly into the bridge without catching a sudden `waitrequest` assertion, leading to dropped read commands.
*   **What Worked**:
    *   **Simple 2-state FSM + Skid Buffer**: A minimal FSM (IDLE/WAIT) with a 1-entry skid buffer to capture the standard-mode FIFO's 1-cycle latency output. The prior working config (which produced video) did NOT use `outstanding_reads` tracking or write-after-read blocking — the response path runs independently every cycle via `mem_res_wr_en <= ddr3_readdatavalid`.

## 3. Watchdog & Soft Resets vs. Physical Pipelines

The MiSTer framework provides multiple reset contexts (HPS warm reset, OSD resets, internal core watchdogs).

*   **What Didn't Work**: Tying the ` outstanding_reads` physical AXI pipeline tracker to the software/watchdog `rst_n`. If the watchdog fired while AXI reads were in flight, the FSM would reset the counter to `0`. When the "ghost" reads finally returned, the counter would underflow (`255`), permanently deadlocking the write logic (`255 != 0`).
*   **What Worked**:
    *   Isolating memory transaction trackers to a `hard_rst_n` pin wired directly to the PLL lock (`locked & ~RESET`).
    *   Allowing the core logic to reset on soft/watchdog trips while the `mem_shim` maintains mathematical synchronization with the physical silicon pipeline of the HPS.

## 4. File Ingestion & Data Streaming

The MiSTer provides an `ioctl` bus for handling simple firmware uploads and simple byte-level streams.

*   **What Didn't Work**: Pushing gigabytes of MPEG2 video via the `ioctl` interface. It is a slow, byte-by-byte register interface intended for configuration data and small ROMs, completely choking the decoder's required bandwidth.
*   **What Worked**:
    *   Implementing a sector-based asynchronous streamer (`mpg_streamer.sv`) leveraging the MiSTer's native `sd_*` block interface. This behaves similarly to CDi/MegaCD core implementations, pulling large SD card logical block chunks directly into an intermediate FIFO asynchronously.

*   **Hardware-verified (2026-02-21):** The streamer successfully loads test files (Z:157C = 5500 sectors = 2.8 MB). The streamer uses `img_mounted` events to detect file selection and reads sectors sequentially via `sd_lba`/`sd_rd`/`sd_ack`. Debug fields: T=streamer_active, D=sd_rd, C=sd_ack, H=cache_has_data, Z=total_sectors, J=next_lba.

## 5. Simulation Verification Discrepancies

Always correlate purely logical bugs (like black screen output) with the RTL primitives if Quartus synthesizes cleanly but simulation breaks.

*   **What Didn't Work**: In `yuv2rgb.v`, a latching `else` case assigned `g_1 <= r_1` and `b_1 <= r_1` across non-updating cycles instead of holding their previous outputs (`g_1 <= g_1`, etc.).
    *   This passed Quartus syntax/synthesis silently but caused corrupted, black frames during ModelSim/Icarus simulation. Always verify color output logic independently of timing.

---

## 6. Clock Domain Crossing (CDC) — Critical Rules

The decoder has three clock domains. Mixing them causes subtle, hard-to-reproduce hangs.

*   **What Didn't Work**: Connecting `mpeg2video.mem_clk` to a different oscillator than `mpeg2video.clk`. Even if the frequencies are numerically close (e.g., 108 MHz PLL vs 100 MHz HPS-derived), they are truly asynchronous. When write rate > read rate, the dual-clock `mem_request_fifo` fills faster than it drains, permanently filling the f2sdram 4-entry write buffer and asserting `waitrequest` forever (after exactly 4 writes).

*   **What Worked**: Using the **same PLL** for all three signals:
    ```verilog
    assign DDRAM_CLK          = clk_mem;   // PLL output
    mpeg2video.clk            = clk_sys;   // same PLL, different ratio
    mpeg2video.mem_clk        = clk_mem;   // same PLL
    mem_shim.clk              = clk_mem;   // same PLL
    ```
    After this fix: `mem_request_fifo` wr_clk=27MHz, rd_clk=108MHz → read-faster = safe CDC (FIFO can drain 4× faster than it fills).

*   **Also wrong**: Sampling `core_v_sync` (in `dot_clk/clk_mem` domain) with a `posedge clk_vid` always block. This is a CDC violation — `clk_vid` (25.175 MHz) is a third oscillator output, not phase-locked to `clk_mem`. Fix: move the edge counter to `posedge clk_mem`.

*   **Current architecture (2026-02-21):** `dot_clk = clk_sys` (27 MHz), `CLK_VIDEO = clk_sys` (27 MHz), `CE_PIXEL = 1'b1`. The vsync edge counter runs on `posedge clk_mem` since `dot_clk = clk_sys` and `clk_mem` share the same PLL. VGA outputs are directly wired from the core (no fallback mux).

---

## 7. ADDR_ERR Sentinel — Decoder Startup Flush

*   **What Didn't Work**: Forwarding all memory requests from `mem_req_rd_*` directly to the DDR3 bridge. On decoder startup, `mem_addr.v`'s pixel address pipeline flushes with invalid `{frame, component}` combinations, generating `ADDR_ERR = 22'h1EFFFF`. Forwarding this to the bridge immediately causes a permanent `waitrequest=1` stall.

    Debug signature: `@:06F7FFF8 M:D U:1` appearing within 1 second of the first video select.

*   **What Worked**: Adding an ADDR_ERR filter in `mem_shim.sv`:
    - **WRITE** to ADDR_ERR (`22'h1EFFFF`): silently drop the command, stay in S_IDLE
    - **READ** from ADDR_ERR: return a synthetic `64'd0` response to the decoder, skip DDR3 entirely

    This is safe because ADDR_ERR is a sentinel — no valid data should ever be read from or written to it.

---

## 8. mem_shim FSM Design — Lessons Learned

The memory shim FSM between the decoder's dual-clock FIFOs and the Avalon-MM DDR3 interface has been through several iterations. Key lessons:

*   **mem_req_rd_en is NOT a per-command pulse.** It is the continuous `rd_en` of the dual-clock FIFO. It should be HIGH whenever the memory controller can accept work. Setting it low for a cycle drops a FIFO word silently.

*   **Standard-mode FIFO timing**: `mem_req_rd_valid` appears **1 cycle after** `rd_en` is asserted. The controller must be designed for this 1-cycle latency (NOT first-word-fall-through).

*   **S_READ_PEND deadlock**: A 3-state FSM that waits in a dedicated READ_PEND state until `ddr3_readdatavalid` arrives can deadlock if the bridge drops a response. Hardware confirmed: one read out of 2,165 had no matching response, causing permanent S_READ_PEND hang. The response path (`mem_res_wr_en <= ddr3_readdatavalid`) must run every cycle regardless of FSM state, and the FSM must not block on it.

*   **Skid buffer**: When `rd_en` is de-asserted for one cycle in standard mode, the word at the FIFO output is "lost" to the controller (though not lost from the FIFO — `rd_en` re-assertion will re-present it). A skid buffer captures this word. However, hardware testing showed that an incorrect skid capture condition (triggering when it shouldn't) can cause command replay and permanent `waitrequest` hangs (M:D U:1 after only 55 reads).

---

## 9. Quartus Tool-Specific Pitfalls

*   **`function automatic` in SystemVerilog files causes Quartus to hang** during elaboration with no error message. Use plain `function` instead (remove the `automatic` qualifier).

*   **Rewriting `uart_tx.v` with SystemVerilog constructs causes Quartus elaboration hang.** Revert to the original Verilog-2001 version (TangNano-9K reference implementation).

*   **Quartus hangs give no progress indication** — if elaboration takes more than 5 minutes with no log output, it is almost certainly hung, not working. Kill and check for the above issues.

---

## 10. Verilog Bit Concatenation Order — CRITICAL PITFALL

**Bit concatenation operand order creates fundamentally different stride values:**

```verilog
// WRONG — SPARSE formula (64-byte stride, crosses 24 MB boundary):
ram_address <= {4'b0011, addr, 3'b000};  // Padding AFTER addr → left-shifts by 3

// CORRECT — DENSE formula (8-byte stride, fits within 24 MB):
ram_address <= {7'b0011000, addr};       // = {4'b0011, 3'b000, addr}
```

**Why SPARSE fails on MiSTer:**
- The padding `3'b000` **after** the address left-shifts it by 3 bits
- Creates a 64-byte stride instead of 8-byte stride
- Max addr `0x1EFFFF` × 64 bytes = ~124 MB total framebuffer size
- But Linux only allocates **24 MB** for FPGA at `0x30000000`
- Any access beyond 24 MB triggers TrustZone protection → permanent `waitrequest=1`

**The Critical Debug Case:**
```
@:06300D90 → addr = 0x0601B2 (valid logical address!)
            → 0x0601B2 × 64 bytes = 24.02 MB (crosses boundary!)
```

**Debug signature:**
```
M:D U:1 @:06300D90  (addresses > 0x06300000, stuck waiting)
```

**Fix:** Use DENSE formula `{7'b0011000, addr}` with padding **between** window and address. This creates `bits[28:25]=0011 (window), bits[24:0]=addr (directly placed, no shift)`, resulting in 8-byte stride. Max addr `0x1EFFFF` × 8 bytes = ~15.5 MB, safely within the 24 MB allocation.
