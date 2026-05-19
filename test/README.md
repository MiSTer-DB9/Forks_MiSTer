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
3. **`lib/joydb_map_check.py`** — joydb→joystick **mux mapping** correctness.
   `emu_portmap_check.py` proves the wrapper nets are *connected*; this proves
   the hand-written per-core mux *body* (`joydb_Nena ? <arm> : <fallback>`)
   maps them right. Balanced ternary-arm parse (handles `[hi:lo]` slices and
   nested `?:`; the `<fallback>` is exempt — it legitimately chains USB wires
   and other-player `joydb_Kena` *enables*). **FATAL** (gates): *P1/P2 leak* —
   the selected arm reads a different `joydb_K[...]` bus than its `joydb_Mena`
   gate (the ao486 `2b63c66` class, where player 2 mirrored player 1);
   *out-of-range bit* — a `joydb_X[≥14]` ref (bits 15:14 are never live);
   *missing `OSD_STATUS` guard* — a controller-data arm with no OSD mute
   (ghost inputs while the menu is open). **FINDING** (non-gating, reported
   for triage like the genuine findings below): *P1/P2 bit-set divergence* —
   P2 references a different *set* of joydb bits than P1 (a button dropped or
   added, not merely reordered: Arcade-Tecmo / SNES class). A pure P1↔P2
   *order* swap is **not** reported — that is the deliberate fleet-wide
   arcade convention (each player's `joydb[10]`=Start routes to that player's
   own Start line, at a different joystick bit for P1 vs P2; see
   Arcade-Galaga `// CO S2 S1`), correct by design on 60+ cores. Canonical
   `joydb_1`/`joydb_2` layout: `[3:0]`=URDL, `[4..9]`=A/B/C/X/Y/Z (DB15
   A..F), `[10]`=Start, `[11]`=Mode/Select/Coin (also Saturn R), `[12]`=Saturn
   L, `[13]` unused, `[15:14]` never live. Self-tested by
   `lib/test_joydb_map_check.py` (fixtures in `fixtures/joydb_map/`, run from
   Tier 1). Also gated regression-only by `merge_validate.sh` (a merge that
   introduces a new FATAL fails the unstable/stable canary ~12 h early).
4. **`lib/mt32_gate_check.py`** — MT32-pi USER_IO anti-contention
   **double-gate** (`the fork hazard notes`). Scoped to MT32-capable
   cores (token-detected: `mt32pi`/`USER_*_MT32`/`mt32_use`). **FATAL**:
   `USER_IN_MT32` whose RHS does not AND-include `mt32_disable` (Gate 1 —
   MT32 reads raw DB9 at boot), or a `USER_OUT ← USER_OUT_MT32`/`mt32_out`
   fallback not governed by `mt32_use`/`mt32_disable`/`mt32_on_primary`
   (Gate 2 — MT32 drives I2C onto USER_IO in the boot window). Recognises the
   always_comb (Minimig/AtariST/X68000), assign (ao486) and TRS-80
   `mt32_disable`-direct variants. **FINDING** (non-gating): MT32-capable but
   the expected gate anchor is absent (non-standard wiring, review).
   Self-tested by `lib/test_mt32_gate_check.py` (`fixtures/mt32_gate/`).
5. **`lib/snac_active_check.py`** — SNAC priority over UserJoy
   (`the fork hazard notes`). Table-keyed on core dir name. **FATAL**: a
   tabled SNAC core whose `wire snac_active` RHS is the inert `1'b0` default
   *or* that has no `snac_active` line at all (joy_type ungated → SNAC will
   not preempt the joydb wrapper → ghost OSD clicks). **FINDING**
   (non-gating): a non-tabled core with a non-default RHS (possibly
   newly-SNAC, not yet tabled — review). **n/a**: a non-tabled core with the
   line absent or inert — the common case (~133/145 cores gate joy_type
   directly off `status[127:126]`, no snac wrapper gate; absence there is
   normal, not a parse error). Gate is "RHS ≠ inert default" (exact-expr
   equality is fragile; the regression we must catch is a wired core reset
   to `1'b0`). Self-tested by `lib/test_snac_active_check.py`
   (`fixtures/snac_active/`).
6. **`lib/canonical_drift_check.sh`** — every per-core
   `sys/{joydb.sv,joydb15.v,joydb9md.v,joydb9saturn.v,db9_key_gate.sv,
   siphash24.v}` must be byte-identical to `fork_ci_template/sys/` canonical
   (`the merge-compat rule`: per-core copies are regenerated, never hand-edited).
   **FATAL** on any drift; `db9_key_secret.vh` mismatch is a non-gating
   **FINDING** (CI-materialised from a secret). Tier 0 only byte-checks the
   single golden core — this closes the gap fleet-wide. Umbrella-only
   (needs the canonical reference); **deliberately not in `merge_validate.sh`**
   (a fork repo carries no canonical to diff against).

Checks 4–5 reuse the `<core>.sv` `emu_portmap_check.py` already resolved
(no extra tree walk). `step6.sh` also gained **item 11** — Saturn-first
CONF_STR ordering (`the fork hazard notes`): a Saturn core whose
`UserIO Joystick` CONF_STR lists DB9MD before Saturn FAILs (OSD-cycle
ghost-input hazard); blocking in `merge_validate.sh`. Checks 4, 5 and
Step-6 #11 are also wired into `merge_validate.sh` as regression-only delta
gates (an upstream merge that introduces a new FATAL fails the canary).

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

### Focused sweep — `run_joydb_semantic.sh`

`lib/joydb_semantic_check.py` only, across the fleet, so the joydb role
mapping can be eyeballed without the other fleet checks in the way (same
single source of truth the fleet audit and `merge_validate.sh` use):

```
Forks_MiSTer/test/run_joydb_semantic.sh              # all ported cores
Forks_MiSTer/test/run_joydb_semantic.sh --core GnW_MiSTer
```

- **FATAL** — P1/P2 role transpose (same joydb bit-set, swapped concat
  order, a role bit `[10]`/`[11]` at a mismatched position, single shared
  role in CONF_STR — Arcade-ComputerSpace/GnW class). Gates
  `run_fleet_audit.sh` (hard) and `merge_validate.sh` (regression-only
  delta — a benign upstream CONF_STR rename cannot wedge it). Exit 1.
- **WARN** — advisory Start/Select/fire heuristics. Surfaced in
  `run_fleet_audit.sh` as GitHub `::warning::` + a `$GITHUB_STEP_SUMMARY`
  digest; never tokenised, never gates. Exit 0.

Same maintainer-umbrella requirement as the fleet audit (needs sibling
core repos checked out).

**Baseline (2026-05): 141/145 PASS, 0 false positives, 4 genuine
previously-unnoticed findings** — `C64_MiSTer` (`joy_raw` declared as a
fork emu port but connected nowhere; every other core keeps it internal),
`MiSTer-Arcade-Gyruss` (`status[127:126]` joy_type but 64-bit `hps_io.v` →
UserIO Joystick selector silently dead), `SNES_MiSTer` (13/14 unbalanced
`[MiSTer-DB9]` markers), `Menu_MiSTer` (no Pro markers / divergent minimal
port). These are reported for maintainer triage, not auto-fixed.

**joydb_map_check baseline (2026-05): 145/145 PASS, 0 FATAL, 2 non-gating
findings** (`Arcade-Tecmo_MiSTer`, `SNES_MiSTer` — P1/P2 bit-set divergence,
flagged for triage). Bringing-up the check found **11 genuine pre-existing
bugs**, all fixed in the same change: 3 P1/P2 leaks (`C16`, `VIC20`,
`Jupiter` — `joyb` read `joydb_1`, the ao486 class) and 8 missing OSD guards
(`Arcade-Finalizer/IremM72/IronHorse/Jailbreak/ScooterShooter/TimePilot84`,
`GnW`, `Arduboy` — `[15:0]`/non-`[31:0]` mux arms the porter's `[31:0]`-only
`wrap_joystick_mux` never guarded).

**mt32_gate / snac_active / drift baseline (2026-05): 145/145 PASS, 0 false
positives** (with git-clean working trees). MT32 double-gate verified on all
5 MT32 cores (Minimig, AtariST, X68000, ao486 assign-style, TRS-80 variant);
every tabled SNAC core matches its `the SNAC-priority rule` expression. During
bring-up the drift check fired a **true positive**: `Saturn_MiSTer` and
`MegaDrive_MiSTer` momentarily had *uncommitted local edits* to their
canonical-managed `sys/` helpers (an adaptive-poll latency block + Stunner
detection + a `.joy_2p` port + 16-bit `JCLOCKS`) diverging from
`fork_ci_template/sys/` — exactly the "never hand-edit a per-core copy; the
next BOT sync overwrites it" hazard from `the merge-compat rule`. Once those trees
were reset to the BOT-synced canonical state the check returned to PASS the
same run — a clean true-positive that arms and clears on the actual
condition, no standing finding.

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

Requires the full `~/dev/sources/mister/MiSTer-DB9/` working tree for the
sibling core repos (fleet audit + `apply_db9_framework.sh` idempotency), so
it is a **maintainer pre-sync gate**, not Forks_MiSTer-repo CI. The
`coresv_lint`, `hps_io_width`, `status_collisions`, and `gate_e2e` checks all
run as gating checks; all their scripts now live committed under
`test/`/`test/lib/` (no dependency on the unmanaged umbrella
test/lib).

## Tier 1 — canonical HDL sim (`run_tier1.sh`)

Self-contained (only `fork_ci_template/sys/*` + `sim/`). Dialect-matched
lint of every canonical source (`.v`→`-g2005`, `.sv`→`-g2012`; mismatched
dialect silently accepts SV-only constructs Quartus rejects — see the fork docs),
then two self-checking testbenches:

- `sim/tb_joydb15.v` — DB15 decoder bit map + active-high inversion.
- `sim/tb_joydb_wrapper.sv` — `joydb.sv` mux: DB15 decode, `*_ena`,
  `USER_PP_DRIVE`/`USER_OUT_DRIVE` patterns, `joy_raw[15:14]` type,
  `USER_OSD` combo, Off-mode inert.
- `lib/test_joydb_map_check.py` — `joydb_map_check.py` against
  `fixtures/joydb_map/` (good / leak / out-of-range / missing-OSD /
  divergence + the order-swap-not-misreported regression guard). Pure
  Python, no iverilog.
- `lib/test_mt32_gate_check.py` — `mt32_gate_check.py` against
  `fixtures/mt32_gate/` (good always_comb / good TRS-80 / Gate-1 defect /
  Gate-2 defect / non-MT32 n/a + no-false-FAIL guard).
- `lib/test_snac_active_check.py` — `snac_active_check.py` against
  `fixtures/snac_active/` (tabled-ok / tabled-reset-to-default FATAL /
  non-tabled-default n/a / non-tabled-nondefault FINDING).

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
- Fleet: drop `mt32_disable` from a core's `USER_IN_MT32` → `mt32gate` FATAL.
  Reset a SNAC core's `wire snac_active` to `1'b0` → `snac` FATAL. Touch any
  per-core `sys/joydb.sv` → `drift` FAIL. Reorder a Saturn CONF_STR to
  DB9MD-first → Step-6 #11 FAIL.
