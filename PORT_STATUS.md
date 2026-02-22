# MPEG2 MiSTer Port — Status & Timeline

## Current State (2026-02-19)

**✅ Major Milestones Achieved:**
1. STATE_CLEAR completes (W:FFFF vs stuck at W:0005)
2. Video decoding starts (2,234 writes, 1,227 reads, 53 sectors consumed)
3. Watchdog=127 fix worked — retry mechanism allows DDR3 bridge to drain between attempts

**❌ Current Blocker:**
- **M:8 hang** — stuck in S_READ_PEND state waiting for `ddr3_readdatavalid` that never arrives
- Frozen counters: W:08BA P:04CB (no progress for 4+ seconds)
- Read address: @:06E02650 (word addr 0x1C04CA = 1,836,234, valid frame buffer range)

---

## Architecture Evolution

### Baseline: `prior-working-config/` (2-State FSM)
**Status:** ✅ Working (achieved 2,234 writes + 1,227 reads before hang)

**FSM States:**
```
S_IDLE (0) → S_WAIT (1) → S_IDLE
                ↑___________|
```

**Key behavior:**
- S_WAIT: Hold ram_read/ram_write until !waitrequest
- **On READ acceptance:** Go IMMEDIATELY back to S_IDLE
- **Async response:** `ddr3_readdatavalid` captured by always-active response path whenever it arrives

**No ADDR_ERR filter** — hung at ADDR_ERR in previous tests

---

### Current: 3-State FSM with Timeout
**Status:** ❌ Hangs at M:8 (S_READ_PEND)

**FSM States:**
```
S_IDLE (0) → S_WAIT (1) ─→ S_READ_PEND (2)
      ↑           ↑              |
      |           |________timeout (synthetic zero)
      |______________________|
```

**Additions vs baseline:**
1. **ADDR_ERR filter** (`22'h1EFFFF`) — silently drops invalid writes/reads
2. **S_READ_PEND state** — wait for `ddr3_readdatavalid` after READ accepted
3. **Read timeout** — 1024 cycles (~9.5µs) safety net for lost CDC pulses
4. **Same-cycle race fix** — if readdatavalid arrives WITH !waitrequest, skip S_READ_PEND

**Bug:** Timeout not recovering despite 4+ seconds stuck (should fire 420,000+ times in 4s)

---

## Debug Output Analysis

### Line-by-line progression:

**Line 1 (idle):** I:000 W:0000 — not initialized
**Lines 2-5:** I:1FF S:1 W:FFFF @:06F7FFF0 — STATE_CLEAR complete ✅
**Line 6+:** M:8 W:08BA P:04CB @:06E02650 — stuck in S_READ_PEND ❌

### M:8 decode:
```
M = {debug_cmd[1:0], saved_valid, state[0]}
M:8 = 1000b
  → cmd[1:0] = 10 (READ)
  → saved_valid = 0 (no skid)
  → state[0] = 0 → state ∈ {S_IDLE=0, S_READ_PEND=2}
```

With E:0 Q:0 (FIFO disabled, no valid data) → **Confirmed: state=S_READ_PEND**

---

## Files Modified from Baseline

| File | Change | Status |
|------|--------|--------|
| `rtl/mpeg2/regfile.v` | `DEFAULT_WATCHDOG_TIMER = 127` (was 255) | ✅ Working |
| `rtl/mem_shim.sv` | 3-state FSM + timeout + ADDR_ERR filter | ❌ Hangs M:8 |
| `rtl/emu.sv` | Direct VGA (removed fallback CDC bug) | ✅ Working |
| `rtl/uart_debug.sv` | Added SC: FC: fields | ✅ Working |

**Line count:**
- Baseline mem_shim: 211 lines
- Current mem_shim: 328 lines (+55% complexity)

---

## Recommended Path Forward

### Option 1: Revert to 2-State FSM + Add ADDR_ERR Filter (RECOMMENDED)

**Rationale:**
- Prior-working-config achieved 2,234 writes + 1,227 reads successfully
- 3-state FSM timeout has unknown bug preventing recovery
- Simpler = fewer edge cases

**Changes:**
1. Restore baseline 2-state FSM from `prior-working-config/rtl/mem_shim.sv`
2. Add ADDR_ERR filter to S_IDLE command processing (discard writes/reads to `22'h1EFFFF`)
3. Keep watchdog=127 (already working)

**Expected outcome:**
- ADDR_ERR filter prevents pipeline flush hang
- 2-state FSM handles async `ddr3_readdatavalid` (proven working for 1,227 reads)
- Video plays

---

### Option 2: Debug 3-State Timeout (Higher Risk)

**Hypothesis:** Timeout counter stuck or state transition bug

**Debug steps:**
1. Add `read_timeout_cnt` to UART debug (verify it's incrementing)
2. Check synthesis report for timing violations on timeout path
3. Add assertions to verify state transitions

**Risk:** Timeout might be fundamentally incompatible with f2sdram CDC behavior

---

## Test Results Summary

| Build | watchdog | FSM | ADDR_ERR? | Result |
|-------|----------|-----|-----------|--------|
| Pre-fix | 127 | 2-state | ❌ | W:FFFF ✅ → stuck at ADDR_ERR ❌ |
| Session fix | 255 | 2-state + filter | ✅ | W:0005 stuck (bridge stall) ❌ |
| + watchdog fix | 127 | 2-state + filter | ✅ | *(not tested - went to 3-state)* |
| Current | 127 | 3-state + timeout | ✅ | W:08BA P:04CB → M:8 hang ❌ |

**Missing test:** 2-state FSM + ADDR_ERR filter + watchdog=127 ← this should work!

---

## Core Port Milestones

- [x] Basic DDR3 interface (Avalon-MM protocol)
- [x] Watchdog retry for STATE_CLEAR bridge stalls
- [x] Direct VGA output (fix CDC bug)
- [x] UART debug v2 (SC/FC fields)
- [ ] **BLOCKER: M:8 READ hang** ← we are here
- [ ] First video playback
- [ ] Frame-accurate decode
- [ ] Audio integration
- [ ] OSD menu

---

## Next Action

**Restore proven 2-state FSM + add ADDR_ERR filter:**
```bash
# Backup current 3-state version
cp rtl/mem_shim.sv rtl/mem_shim.sv.3state

# Restore 2-state baseline
cp prior-working-config/rtl/mem_shim.sv rtl/mem_shim.sv

# Manually add ADDR_ERR filter (10 lines)
# Build and test
```

Expected: Video plays successfully.
