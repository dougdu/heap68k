# Design Review — HEAP_SMALL_ALLOC_DESIGN.md

**Reviewer:** GitHub Copilot  ·  **Date:** 2026-07-20  ·  **Doc reviewed:** [HEAP_SMALL_ALLOC_DESIGN.md](HEAP_SMALL_ALLOC_DESIGN.md)
**Scope:** Correctness and implementability of the Small Object Allocator (SOA) spec, verified against the current heap sources in this directory.
**Rounds:** Round 1 reviewed Draft v1.0. **Round 2 (below) reviews Draft v1.1**, which applied the round-1 findings.

---

## Round 2 — follow-up review of Draft v1.1 (current)

**Verdict.** Draft v1.1 applied **all ten** round-1 findings (S1–S5, N1–N5), most of them well. However, the S2 discriminator rework left the prose (§6.7) and the normative pseudocode (§9.4) **out of sync**, and §6.7 as written has a **cross-heap reporting bug**. Two high-priority items remain, plus three consistency nits.

### Round-1 resolution status (in v1.1)

| Item | Round-1 finding | Status in v1.1 | How addressed |
|------|-----------------|:--------------:|---------------|
| S1 | Arena free-tile tracking missing | ✅ Resolved | `arTileMap` bitmap at arena `$16`; `slab_create` claims first clear bit; `slab_maybe_release` clears it; `_HeapValidate` checks `popcount(arTileMap) == arSlabUse` |
| S2 | Discriminator wording overstated the guarantee | 🟨 Partial | §6.7/I1/R1 reworded to a load-bearing chain (`slArena`→`'AREN'` + arena-range); **but §9.4 pseudocode not updated** (see D2) |
| S3 | Same-class realloc-grow can't honor `ZERO_MEMORY` | ✅ Resolved | Documented divergence in §9.6 + §7 + Q3 |
| S4 | First-small-alloc footprint on small heaps | ✅ Resolved | Adaptive arena sizing (§6.4), R9, Q7 |
| S5 | Default-on alignment change broader than `_HeapSize` | ✅ Resolved | R10, §13 migration, Phase 6 audit broadened |
| N1 | §9.1 shift-precedence bug | ✅ Resolved | Parenthesized `((n+7)>>3)-1` + NB note |
| N2 | "Cells aligned to class size" false | ✅ Resolved | C8/§6.5 restated as ≥ 8-byte (longword) |
| N3 | Slab flags/ID layout ambiguous | ✅ Resolved | §6.5 shows a flags/ID **long** mirroring `hhFlags`/`hhId`, masked with `HEAP_ID_MASK` |
| N4 | `SLAB_HDR_SIZE` fixed vs per-class | ✅ Resolved | Pinned as a fixed multiple of 8 (§6.5/§8) |
| N5 | Double-free error code inconsistency | ✅ Resolved | §6.6 now reports `HEAP_ERROR_DOUBLE_FREE` (`$16`) |

### Remaining issues (both in the free discriminator)

**D1 (High) — §6.7 folds the heap-ID check into cell *recognition*, breaking cross-heap reporting.**
§6.7 step 2 ANDs `slab->slId == hHeap->hhId` into the condition that decides "→ SOA free path." A **cross-heap cell** (valid cell, wrong owner) therefore makes the condition false, falls through to the block probe (step 3), and ends at step 4 → `HEAP_ERROR_INVALID_BLOCK`. But the section's own closing sentence claims "a cross-heap cell is caught by the `slId` mismatch," §9.4 returns `HANDLE_BLOCK_MISMATCH`, and §12.2 tests for `HEAP_ERROR_HANDLE_BLOCK_MISMATCH`. The intended behavior matches the block path in `HeapFree.a68` (`_hfInvalidHeap` → `HEAP_ERROR_HANDLE_BLOCK_MISMATCH` for a valid block owned by another heap). **Fix:** separate ownership from recognition — recognize a cell via magic + arena-chain + modulus + range; *then* if `slId != hhId` return `HANDLE_BLOCK_MISMATCH` (as §9.4 does).

**D2 (High) — §9.4 pseudocode was not updated for the S2 strengthening.**
The point of S2 was to make the discriminator chain load-bearing, and §6.7/R1 now advertise `slArena->arMagic == 'AREN'` + arena-range containment as the safety mechanism. But the §9.4 `heap_free` pseudocode still has only the pre-review checks (`slMagic == 'SLAB'` + modulus + `cellIndex < slTotal`) — missing the `arMagic`/arena-range checks. Since §9.4 is the version an implementer follows, it must carry the same chain.

**Fix D1 + D2 together** so both sections read:

> **recognize** = `slMagic=='SLAB'` ∧ `slArena->arMagic=='AREN'` ∧ `arBase ≤ slab < arBase+arSlabs×SLAB_SIZE` ∧ `(pMem−firstCell) mod slCellSz == 0` ∧ `cellIndex < slTotal`;
> then **ownership** = `slId==hhId ? soa_free(...) : HANDLE_BLOCK_MISMATCH`.

### Minor consistency nits

- **Class-table name drift.** Renamed to `__HeapSoaClassTbl`, but stale `SOA_CLASS_TBL` remains in §10 step 3, §12.2, and the Phase 0 checklist. Unify the name — "one source of truth" should include the name.
- **`ARENA_SLABS equ 16 ; arena = 64 KB` (§8) contradicts the adaptive decision** (§6.4/Q7/R9). Update the value/comment, and reconcile **R2** ("amortize with large arenas (64 KB)"), which now pulls opposite to R9's small-default policy.
- **Confirm §8 pins `SLAB_HDR_SIZE = 32`** — §2.2's amortized-meta math assumes a 32-byte header, and 32 is the 30-byte header rounded up to a multiple of 8.

### Note

Phase 0 is now marked ✅ in the tracker — the doc references real artifacts (`HeapData.a68` `__HeapSoaClassTbl`, `HeapStats.a68`, `heap.inc` constants, makefile wiring), so implementation has begun. A code-vs-spec verification of those Phase 0 artifacts is recommended as a separate pass.

---

## Round 1 — original review (Draft v1.0)

> The sections below are the original v1.0 review, retained for the record. **Every item (S1–S5, N1–N5) was applied in Draft v1.1** — see the resolution table above.

## Verdict

Strong, well-researched design. The architecture — per-size-class **slabs** carved from `SLAB_SIZE`-aligned **arenas**, with free-path discrimination by masking the cell pointer to its slab header — is the right call. Phasing is sound, the public API and per-heap isolation model are respected, and the codebase-specific pitfalls it calls out are real.

There are **five substantive gaps** to close before Phase 1 and a handful of smaller spec bugs, all listed below.

---

## Verification performed

The spec's claims about the existing implementation were checked against source and found **accurate**:

| Claim in spec | Verified against | Result |
|---|---|---|
| `hhReserved` at `$3C`, zero-initialized on every heap | `HeapCreate.a68`, `HeapInitialize.a68` (both `clr.l hhReserved(a0)`) | ✅ |
| `_HeapFree` receives only `(hHeap, pMem)`; validates upper-byte+alignment then magic | `HeapFree.a68` | ✅ |
| Heap identity in high word of flags long; mask-and-compare (`HEAP_ID_MASK=$ffff0000`) | `heap.inc`, `HeapFree.a68` | ✅ |
| Heap header fixed at `$40`; only `hhReserved` free | `heap.inc` | ✅ |
| Flag bits 0–9 used; 10–15 free | `heap.inc` (`FLG_HEAP_TRAP_ON_ERROR=9` highest) | ✅ |
| Error codes end at `$14`; new codes append cleanly | `heap.inc` | ✅ |
| Build is `/Cx` (case-sensitive) | `makefile-elf` (`ELF_FLAGS=/Cx …`) | ✅ |
| `andi.b #NOT(BLK_HDR_SIZE-1)` byte-mask idiom (so `SLAB_SIZE-1=$FFF` needs `andi.l`) | `HeapAlloc.a68`, `HeapCreate.a68`, `HeapInitialize.a68` | ✅ (the §11 warning is a genuine, valuable catch) |
| Block path zeroes/`CD`-fills grown region on realloc using stored `bhRequestSize` | `HeapReAlloc.a68` | ✅ (drives issue **S3** below) |

---

## Strengths

- Correctly identifies **both** waste sources (fixed 32-byte header + 32-byte granule rounding) and picks a design that attacks both while leaving the large-block path untouched.
- Constraint table **C1–C8** is accurate; the ABI / duplicate-label / byte-mask pitfalls in §11 match this codebase's real failure modes.
- **Lazy SCB creation** (zero cost for heaps that never make small allocations) and the **opt-in → opt-out** rollout are exactly right.
- Free-path discriminator is O(0) per-cell overhead, which is the whole point of the exercise.

---

## Substantive issues

### S1 (High) — Arena free-tile tracking is missing

The arena descriptor (§6.4) stores only `arSlabUse` (a **count**). Three operations need to know *which* tiles are live:

- `slab_create` (§9.5) must "find the next free `SLAB_SIZE` tile in ar" — impossible from a count once tiles are individually freed.
- §7 / Phase 5 `_HeapCompact` promises to "release fully-empty **slabs**" (individual tile reclamation).
- `_HeapValidate` step 3 (§10) walks "each slab tile **in use**."

A count cannot locate free tiles or drive the validation walk.

**Fix:** add a per-arena used/free **tile bitmap** (16 bits for `ARENA_SLABS=16` — one word) or a free-tile free-list threaded through released tiles. Alternatively adopt an explicit *bump-allocate + whole-arena-release-only* policy and drop the "release fully-empty slabs" promise. **Resolve in Phase 1** — it changes the SCB/arena/slab structures.

### S2 (Medium-High) — Free discriminator wording overstates its guarantee

§6.7 / invariant I1 justify the probe by saying "arenas are dedicated regions." But arenas are carved from the **same parent heap's block allocator** (an arena is a regular block of the private heap), so slabs and ordinary blocks share one address space. I1 guarantees a real cell masks to a real slab header — it does **not** guarantee a non-cell never masks to something that *looks* like one. Safety therefore rests entirely on the magic + modulus + range + heap-ID quad-check, which is probabilistic, not the address separation the text implies.

**Fix:** the slab header already carries `slArena`; chain the check one more hop — `slab->slArena->arMagic == 'AREN'` **and** the slab lies within `[arBase, arBase + arSlabs*SLAB_SIZE)`. That upgrades the discriminator from "four coincidences" to "a forged slab header *and* a consistent back-pointer to a forged arena descriptor," which is effectively unforgeable. Reword R1 / I1 to make clear the quad-check is load-bearing (or make it authoritative via the chained check).

### S3 (Medium) — Same-class realloc-grow can't honor `HEAP_ZERO_MEMORY` / debug-fill

`HeapReAlloc.a68` zeroes (or `CD`-fills) the region `[bhRequestSize_old, lBytes_new)` on grow — it relies on the **per-block stored request size**. The SOA deliberately stores **no per-cell request size**, so §9.6's "`class(n) == cur.class` → update nothing, return `pMem`" path silently diverges: a small realloc that grows within one class (e.g., 17 → 24) will not zero/fill the newly exposed bytes, whereas the block path would.

**Fix:** document this as an accepted divergence (honest option: "small-alloc realloc does not honor `ZERO_MEMORY` on same-class grow"). Precise zeroing is impossible without the old size. Tie this decision to Q3 — both stem from not storing per-cell size.

### S4 (Medium) — First-small-alloc footprint on small heaps

`ARENA_SLABS=16` ⇒ the **first** small request triggers a 64 KB arena (≈68 KB requested with alignment slack), carved from the *parent private heap*. A private heap smaller than ~68 KB cannot satisfy it, so `soa_alloc` fails and (per R7) falls back to the block path — silently losing the density win exactly where G1 promised it. Lazy SCB creation only helps the *zero*-small-alloc case. This footprint/UX consequence is not in the Risks table.

**Fix:** make arena size adaptive (default `ARENA_SLABS` = 1–4, or size relative to heap size / allow single-slab arenas), and add it as an explicit risk + tuning knob (currently only `SLAB_SIZE` is called out in Q1).

### S5 (Medium) — Default-on alignment change is broader than `_HeapSize`

R4 and §13 flag the `_HeapSize` semantic change, but the **alignment** change is a wider hazard when the SOA flips to default-on in Phase 6: cells are 8-byte aligned, blocks are 32-byte aligned. Any caller that tags the low 5 bits of a heap pointer (common on embedded 68K) breaks.

**Fix:** broaden the Phase 6 audit and R4/§13 migration notes to cover pointer-alignment assumptions, not just `_HeapSize` callers.

---

## Minor / spec bugs

- **N1 — pseudocode precedence (§9.1):** `return (n + 7) >> 3 - 1` binds as `(n+7) >> (3-1)` under C precedence (`>>` looser than `-`), which is wrong. Needs `((n + 7) >> 3) - 1` (and likewise in the tier-2/tier-3 lines). The arithmetic is otherwise correct; implementers copy pseudocode, so parenthesize it.
- **N2 — "cells aligned to their class size" is false for non-power-of-two classes.** With a 4 KB-aligned slab base, classes 24/40/48/56/80/96/112/160/192/224 don't divide 4096, so cells are only guaranteed **8-byte** aligned. That is all 68K needs (even alignment for word/long access), so restate C8 / §6.6 as "≥ 8-byte (longword) aligned" rather than class-size aligned.
- **N3 — slab header flags/ID layout (§6.5):** `slFlags` and `slId` both listed as "word" at `$04` is ambiguous. Mirror the existing `hhFlags`/`hhId` convention exactly (a long at `$04` with the heap **ID in the high word**, compared with `HEAP_ID_MASK`) so the cross-heap check is bit-identical to the block path. Putting the ID in the wrong half would break G4 (cross-heap detection) silently.
- **N4 — `SLAB_HDR_SIZE` fixed vs. per-class:** §6.5 says "rounded up to the class alignment" (implying per-class) but §8 lists it as a single constant. Clarify. Simplest: one fixed constant that is a multiple of 8 → cells stay 8-aligned (also resolves N2).
- **N5 — double-free error code inconsistency:** §6.6 says a double-free is reported as `HEAP_ERROR_INVALID_BLOCK`, but §8 / §9.4 / §10 define and use a dedicated `HEAP_ERROR_DOUBLE_FREE = $16`. Pick one (the dedicated code is better) and fix §6.6.
- **N6 — makefile casing (informational):** `makefile-elf` does `copy Heap.inc` while sources `include heap.inc`. Harmless on Windows (case-insensitive filesystem); `/Cx` affects label case, not filenames. No action.

---

## Questions to lock before Phase 1

1. **Per-cell size: confirmed *not* stored?** This single decision determines both `_HeapSize` semantics (Q3) *and* the realloc-zero divergence (**S3**). State it once, explicitly.
2. **Free-tile tracking mechanism** (**S1**) — bitmap vs. bump-only? Drives the arena/slab structs.
3. **Arena sizing policy** (**S4**) — fixed 64 KB vs. adaptive/small default?

---

## Suggested doc edits (low-risk)

If accepted, these can be applied directly to the design document:

- Parenthesize the §9.1 shift formulas (N1).
- Restate C8 / §6.6 alignment as "≥ 8-byte" (N2).
- Clarify the slab flags/ID layout to mirror `hhFlags`/`hhId` (N3).
- Fix `SLAB_HDR_SIZE` wording (N4) and the double-free error code (N5).
- Reword R1 / I1 to make the quad-check load-bearing and add the `slArena->arMagic` chained check (S2).
- Add S1 (free-tile tracking), S4 (arena sizing) and S5 (alignment audit) to the Risks table, and add the three "lock before Phase 1" questions to §16.
