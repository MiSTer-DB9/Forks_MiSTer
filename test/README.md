# Porting regression tests

Layered net protecting the DB9/SNAC porting contract. Canonical
`fork_ci_template/sys/*` is copied **verbatim** into every ported core, so the
software tiers protect every port at once.

## Fleet audit — `run_fleet_audit.sh` (start here)

> "Be sure every already-ported core is wired correctly, without hand-testing
> 140+ cores." Static analysis of all ~145 ported cores (`sys/joydb.sv`
> present), as-is, in seconds — no Quartus, no hardware, no network, zero
> manual work. Exit nonzero if any core fails.

Per core it runs:

1. **`lib/emu_portmap_check.py`** — the **generic** Arcade-Tecmo-class check.
   Arcade-Tecmo shipped with `sys/sys_top.v` missing `.USER_OSD(user_osd)`;
   `user_osd` was undriven and Start+C silently dead — game input + F12 still
   worked so nobody noticed (fixed only in commit `6f4bfd6`). The general
   law: **every fork-added (`[MiSTer-DB9*]`-wrapped) `emu` port in `<core>.sv`
   must be connected in the active build's `sys_top.v` `emu` instance**, and
   no connection may reference a non-existent port. Tokenizing, marker- and
   `define-aware (resolves `\`include "sys/emu_ports.vh"`, evaluates
   `\`ifdef` against the core's `VERILOG_MACRO` set, picks the build's real
   `.sv` from `*.qip`/`*.qsf`). **No hardcoded port names** — `.USER_OSD` is
   only an example; it equally catches a future missing `.USER_PP`/`.joy_raw`.
2. **`lib/step6.sh`** (`step6_verify`) — the per-`<core>.sv` Step-6 checklist.

DB15-only scope is sufficient: DB9MD/DB15/Saturn all ride the same `joydb.sv`
wrapper and the same `emu`/`sys_top` nets, so a wiring break breaks all three;
the wrapper logic itself is proven once by Tier 1.

```
Forks_MiSTer/test/run_fleet_audit.sh                 # all ported cores
Forks_MiSTer/test/run_fleet_audit.sh --core SMS_MiSTer
Forks_MiSTer/test/run_fleet_audit.sh --changed       # only git-dirty cores
```

Maintainer pre-sync gate (needs the umbrella working tree with sibling core
repos). Run before any canonical-`sys/` change and after any batch port.

**Baseline (2026-05): 141/145 PASS, 0 false positives, 4 genuine
previously-unnoticed findings** — `C64_MiSTer` (`joy_raw` declared as a
fork emu port but connected nowhere; every other core keeps it internal),
`MiSTer-Arcade-Gyruss` (`status[127:126]` joy_type but 64-bit `hps_io.v` →
UserIO Joystick selector silently dead), `SNES_MiSTer` (13/14 unbalanced
`[MiSTer-DB9]` markers), `Menu_MiSTer` (no Pro markers / divergent minimal
port). These are reported for maintainer triage, not auto-fixed.

---

| Tier | What it catches | Cost | CI |
|---|---|---|---|
| 0 `run_tier0.sh` | porter / framework regression, canonical-source drift, Step-6 violations | seconds | maintainer (needs full tree) |
| 1 `run_tier1.sh` | canonical HDL data-path logic (bit map, wrapper mux, dialect) | seconds | yes (`.github/workflows/regression_tests.yml`) |
| 2 `hil/run_hil.sh` | real silicon / electrical / timing | manual | no (needs DE10-Nano + MCU) |

DB15-first by design (simplest path: `USER_IO[1]`=CLK, `[0]`=LOAD,
`[5]`=DATA, 26-slot deterministic frame). Extend later with `tb_joydb9md.v`
/ Saturn.

## Tier 0 — porter golden / idempotency (`run_tier0.sh`)

Hermetic: takes a real, already-ported in-tree core as **both input and
golden**. Re-applying `apply_db9_framework.sh` must be a no-op (scripts are
documented idempotent); any diff = porter regression or canonical drift. Also
runs the factored Step-6 checklist (`lib/step6.sh`) and the existing
cross-fork audits.

```
Forks_MiSTer/test/run_tier0.sh                  # default golden: SMS_MiSTer
TIER0_CORE=NES_MiSTer TIER0_CORE_SV=NES.sv Forks_MiSTer/test/run_tier0.sh
```

Requires the full `~/dev/sources/mister/MiSTer-DB9/` working tree (sibling
core repos + top-level test/lib), so it is a **maintainer pre-sync
gate**, not Forks_MiSTer-repo CI. The `hps_io_width`, `status_collisions`,
and `gate_e2e` cross-fork audits all run as gating checks.

## Tier 1 — canonical HDL sim (`run_tier1.sh`)

Self-contained (only `fork_ci_template/sys/*` + `sim/`). Dialect-matched
lint of every canonical source (`.v`→`-g2005`, `.sv`→`-g2012`; mismatched
dialect silently accepts SV-only constructs Quartus rejects — see the fork docs),
then two self-checking testbenches:

- `sim/tb_joydb15.v` — DB15 decoder bit map + active-high inversion.
- `sim/tb_joydb_wrapper.sv` — `joydb.sv` mux: DB15 decode, `*_ena`,
  `USER_PP_DRIVE`/`USER_OUT_DRIVE` patterns, `joy_raw[15:14]` type,
  `USER_OSD` combo, Off-mode inert.

Both seed the inner `joydb15.v` `JCLOCKS` counter (no RTL initializer; FPGA
powers it to 0, sim leaves it `X` and `X+1` stays `X`) — white-box, sim-only.

```
Forks_MiSTer/test/run_tier1.sh
```

## Tier 2 — hardware-in-the-loop (`hil/`)

MCU emulates the DB15 splitter serial side; readout via evdev over SSH. See
`hil/README.md`. Run on demand with hardware attached.

## Verifying the harness itself bites

- Tier 1: mutate a slot in `fork_ci_template/sys/joydb15.v` → `run_tier1.sh`
  FAIL. Flip an expected vector in `tb_joydb15.v` → FAIL.
- Tier 0: inject a stray `JOY_FLAG` line into the staged core → Step-6 check 2
  FAIL. Any porter output change → golden diff FAIL.
