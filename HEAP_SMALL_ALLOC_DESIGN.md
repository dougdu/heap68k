# Heap Small-Allocation Efficiency — Architecture & Design Spec

**Status:** Draft v1.2 (round-2 review applied) · **Phases 0–6 complete — SOA default-on**  ·  **Target:** `libheap-elf.a` / `libheap` (m68k)  ·  **Owner:** _unassigned_
**Related docs:** [HEAP_API.md](HEAP_API.md), [heap.inc](heap.inc)

---

## Table of Contents

1. [Purpose & Scope](#1-purpose--scope)
2. [Problem Statement — Quantified Waste](#2-problem-statement--quantified-waste)
3. [Goals & Non-Goals](#3-goals--non-goals)
4. [Constraints & Invariants](#4-constraints--invariants)
5. [Design Options Considered](#5-design-options-considered)
6. [Chosen Architecture — Small Object Allocator (SOA)](#6-chosen-architecture--small-object-allocator-soa)
7. [API Behavior Changes](#7-api-behavior-changes)
8. [Data Structures & New Constants](#8-data-structures--new-constants)
9. [Core Algorithms (pseudocode)](#9-core-algorithms-pseudocode)
10. [Debug, Fill & Validation Semantics](#10-debug-fill--validation-semantics)
11. [Assembly Implementation Guidelines](#11-assembly-implementation-guidelines)
12. [Testing & Measurement Strategy](#12-testing--measurement-strategy)
13. [Backward Compatibility & Migration](#13-backward-compatibility--migration)
14. [Risks & Mitigations](#14-risks--mitigations)
15. [Phased Implementation Plan & Progress Tracker](#15-phased-implementation-plan--progress-tracker)
16. [Open Questions & Tuning Parameters](#16-open-questions--tuning-parameters)
17. [Changelog](#17-changelog)

---

## 1. Purpose & Scope

The current heap manager allocates every request as an independent block with a **32-byte
block header** (`BLK_HDR_SIZE`) and rounds every data area up to a **32-byte granule**. For
large allocations this overhead is negligible, but for the small allocations that dominate
most workloads (list nodes, string fragments, small structs, handles) the overhead is
catastrophic: a 1–32 byte request consumes **64 bytes** of heap, and a 33–64 byte request
consumes **96 bytes**.

This document specifies an **architecture and phased implementation plan** to add an
efficient small-allocation path to the heap while preserving the existing public API,
calling conventions, debug instrumentation, and per-heap isolation model. The plan is
incremental: each phase is independently buildable, testable, and reversible, and the
[Progress Tracker](#15-phased-implementation-plan--progress-tracker) records status.

Scope **includes**: allocation, free, realloc, size query, validation, walk, compaction,
and debug-fill behavior for small allocations; new internal data structures; new tuning
constants; test and measurement tooling.

Scope **excludes**: thread safety, heap growth/extension, and the other items in
[HEAP_API.md §10](HEAP_API.md) that are unrelated to small-allocation density.

---

## 2. Problem Statement — Quantified Waste

Two independent sources of waste compound for small requests:

1. **Fixed metadata overhead** — every block carries a 32-byte header
   (`bhMagic`, `bhFlags`/`bhId`, `bhRequestSize`, `bhSize`, `bhPrev`, `bhNext`,
   `bhFreePrev`, `bhFreeNext`). Note that `bhFreePrev`/`bhFreeNext` (8 bytes) are only
   meaningful while the block is **free**, yet they occupy header space even when allocated.
2. **Alignment rounding** — the data area is rounded up to a 32-byte granule
   (`BLK_HDR_SIZE`), so the minimum data area is 32 bytes even for a 1-byte request.

### 2.1 Current footprint (no debug flags)

Footprint = `roundup(request, 32) + 32` (header). Tail-checking adds a further 32 bytes.

| Request (bytes) | Data area | + Header | **Total footprint** | Wasted | Waste % |
|----------------:|----------:|---------:|--------------------:|-------:|--------:|
| 1   | 32  | 32 | **64**  | 63 | 98.4% |
| 8   | 32  | 32 | **64**  | 56 | 87.5% |
| 16  | 32  | 32 | **64**  | 48 | 75.0% |
| 24  | 32  | 32 | **64**  | 40 | 62.5% |
| 32  | 32  | 32 | **64**  | 32 | 50.0% |
| 33  | 64  | 32 | **96**  | 63 | 65.6% |
| 48  | 64  | 32 | **96**  | 48 | 50.0% |
| 64  | 64  | 32 | **96**  | 32 | 33.3% |
| 128 | 128 | 32 | **160** | 32 | 20.0% |

**Takeaway:** for requests ≤ 64 bytes the heap wastes **1×–16× the requested size**. A
workload dominated by 16-byte nodes achieves only ~25% memory utilization.

### 2.2 Target footprint (with SOA, illustrative)

With a slab of `SLAB_SIZE = 4096`, a 32-byte slab header, and no per-cell header, the
metadata cost is `slab_header / cells_per_slab` per allocation, plus request→class rounding.

| Request | Class | Cell size | Amortized meta* | **Effective total** | vs. current |
|--------:|------:|----------:|----------------:|--------------------:|------------:|
| 1   | 8   | 8   | ~0.06 | **~8**   | 64 → 8   (8.0×) |
| 8   | 8   | 8   | ~0.06 | **~8**   | 64 → 8   (8.0×) |
| 16  | 16  | 16  | ~0.13 | **~16**  | 64 → 16  (4.0×) |
| 24  | 24  | 24  | ~0.19 | **~24**  | 64 → 24  (2.7×) |
| 48  | 48  | 48  | ~0.38 | **~48**  | 96 → 48  (2.0×) |
| 64  | 64  | 64  | ~0.50 | **~64**  | 96 → 64  (1.5×) |

*Amortized meta = `32 / (⌊(4096−32)/cell⌋)`. Real per-allocation overhead is dominated by
request→class rounding, which the class table bounds to **< 25%** (see §6.2).

**Target outcome:** small-allocation footprint reduced **~2×–8×**, with the largest gains at
the smallest, most common sizes.

---

## 3. Goals & Non-Goals

### Goals

- **G1** Reduce memory footprint of allocations ≤ 256 bytes by ≥ 2× (≥ 4× for ≤ 32 bytes).
- **G2** Preserve the entire public API surface and calling convention unchanged
  ([HEAP_API.md §5](HEAP_API.md)). Existing callers require **no source changes**.
- **G3** Preserve `_HeapFree(hHeap, pMem)` semantics — free must work from the returned
  pointer **alone**, with no size argument and no caller-side bookkeeping.
- **G4** Preserve cross-heap ownership detection (heap-ID check) and per-heap flag isolation.
- **G5** Keep allocation and free at **O(1)** amortized for the small path.
- **G6** Preserve debug instrumentation intent (zero-fill, debug-fill, validation) for the
  small path; document any deliberate exceptions (e.g., tail-check — see §10).
- **G7** Make the feature **default-safe**: a per-heap flag can disable the SOA and fall back
  to today's exact behavior for bring-up and A/B measurement.

### Non-Goals

- **N1** Thread safety / reentrancy (unchanged; still single-threaded — see [HEAP_API.md §9](HEAP_API.md)).
- **N2** Heap growth / segment chaining (tracked separately).
- **N3** Best-fit for large blocks (bucket 9 behavior unchanged).
- **N4** Changing the heap header size (`HEAP_HDR_SIZE = $40`) or breaking on-disk/handle
  layout compatibility.

---

## 4. Constraints & Invariants

These are **hard constraints** derived from the existing implementation; the design must
not violate them.

| # | Constraint | Source |
|---|-----------|--------|
| C1 | Free receives only `(hHeap, pMem)`. The allocator kind and size class must be **recoverable from `pMem` alone**. | [HeapFree.a68](HeapFree.a68) |
| C2 | The **upper byte of every valid address is zero**; a non-zero upper byte signals corruption. Pointer masking must preserve this. | [HeapFree.a68](HeapFree.a68), [HEAP_API.md §2.1](HEAP_API.md) |
| C3 | Heap identity lives in the **high word of the flags longword** (`HEAP_ID_MASK = $FFFF0000`); ownership is a mask-and-compare. | [heap.inc](heap.inc) |
| C4 | The heap header is fixed at `$40` bytes; only `hhReserved` (`$3C`) is free for new state. | [heap.inc](heap.inc) |
| C5 | Per-call flags (`HEAP_ZERO_MEMORY`) override per-heap flags for that call. | [HeapAlloc.a68](HeapAlloc.a68) |
| C6 | Build is **case-sensitive** (`/Cx`); labels differing only in case are distinct. | [makefile-elf](makefile-elf) |
| C7 | 68K ABI in this codebase: **D0/D1/A0/A1 = caller-saved** (scratch); **D2–D7/A2–A6 = callee-saved**. `PROC`/`ENDP` `USES` lists enforce this. | [HEAP_API.md §8](HEAP_API.md) |
| C8 | Every allocation returned today is 32-byte aligned. Callers **must not** assume this continues for small allocations (SOA cells are guaranteed only **≥ 8-byte (longword)** aligned — enough for 68K word/long access — **not** class-size aligned). | new |

**Design invariant added by this spec:**

- **I1 — Slab masking invariant:** every in-use SOA cell pointer `P` satisfies
  `(P & ~(SLAB_SIZE−1))` = the address of a live slab header whose `slMagic == 'SLAB'`.
  This is guaranteed by allocating slabs only inside `SLAB_SIZE`-aligned arenas (see §6.4).
  **The implication is one-way:** a real cell always masks to a real slab header, but arenas
  share the parent heap's address space with ordinary blocks, so this does **not** by itself
  prove that an arbitrary pointer masking to a `'SLAB'`-looking header is a cell. That
  direction is established by the load-bearing checks in §6.7 (magic + `slArena`→`'AREN'`
  back-pointer + arena-range + cell modulus/range + heap-ID), **not** by address separation.

---

## 5. Design Options Considered

### Option A — Compact block header for small blocks
Split the 32-byte header so allocated blocks omit the 8 bytes of free-chain links, and halve
the granule to 16 bytes. **Verdict: rejected as the primary solution.** It only halves waste
(min footprint 64 → 32), touches every block-chain and coalesce path (very high blast
radius), and complicates `bhSize` arithmetic that the entire validator depends on.

### Option B — Slab / segregated fixed-size pools *(chosen)*
Route small requests to per-size-class **slabs** subdivided into fixed-size **cells** with no
per-cell header. One block header is amortized across hundreds of cells, and cells are sized
to the class so rounding waste is bounded. **Verdict: chosen.** Attacks both waste sources,
keeps O(1), and is additive (the large path is untouched).

### Option C — Free-path discrimination sub-options
How does `_HeapFree` recover the allocator kind from `pMem` alone (constraint C1)?

| Sub-option | Mechanism | Per-cell cost | Robustness | Verdict |
|-----------|-----------|--------------:|-----------|---------|
| C-1 Aligned slab + mask | `P & ~(SLAB_SIZE−1)` → slab header w/ magic | **0 bytes** | High (magic + range + modulus + heap-ID) | **Chosen** |
| C-2 Per-cell back-tag | 4–8 byte header per cell pointing to slab | 4–8 bytes | High | Fallback if alignment is impractical |
| C-3 Global page map | radix/array mapping page→owner | table memory | High | Rejected (heavyweight for 68K) |

**Chosen: C-1.** Slabs are carved from `SLAB_SIZE`-aligned arenas so masking a cell pointer
always lands on its slab header (invariant I1). Zero per-cell overhead is the whole point of
the exercise, so any per-cell header is self-defeating for the smallest classes. C-2 is
retained as a documented fallback only if a target cannot guarantee arena alignment.

---

## 6. Chosen Architecture — Small Object Allocator (SOA)

### 6.1 Overview

```
Heap header ($40)                         (unchanged size; hhReserved repurposed)
  hhReserved  ──►  SOA Control Block (SCB)   [lazily created on first small alloc]
                     ├─ class[0..N-1] partial-slab list heads
                     ├─ class[0..N-1] full-slab list heads
                     ├─ arena list head
                     └─ statistics counters

Arena  (SLAB_SIZE-aligned, multiple of SLAB_SIZE)   [a regular heap block, aligned]
  ┌─────────── SLAB_SIZE ───────────┬─────────── SLAB_SIZE ───────────┬─ ...
  │ Slab header │ cell │ cell │ ...  │ Slab header │ cell │ cell │ ...  │
  └──────────────────────────────────┴──────────────────────────────────┘
       one size class per slab             a different (or same) class

Free path:  P & ~(SLAB_SIZE-1) ──► slab header ('SLAB', class, heapId, free list)
```

- Requests with `size ≤ SOA_MAX` **and** the heap's SOA enabled are served by the SOA.
- All other requests use the existing segregated-bucket block allocator, **unchanged**.
- A **slab** serves exactly one size class. Cells have **no header**; a *free* cell stores
  its free-list link (and a free tag) in its own body, reused as user data when allocated.
- Slabs live inside `SLAB_SIZE`-aligned **arenas** so that free can recover the slab by
  masking the cell pointer (invariant I1).

### 6.2 Size Classes

`SOA_MAX = 256`. Classes are all multiples of 8 (≥ 8-byte cell alignment on 68K) with
spacing tightened at the low end to bound request→class rounding waste to **< 25%**.

| Idx | Class | Idx | Class | Idx | Class | Idx | Class |
|----:|------:|----:|------:|----:|------:|----:|------:|
| 0 | 8   | 4 | 40 | 8  | 80  | 12 | 160 |
| 1 | 16  | 5 | 48 | 9  | 96  | 13 | 192 |
| 2 | 24  | 6 | 56 | 10 | 112 | 14 | 224 |
| 3 | 32  | 7 | 64 | 11 | 128 | 15 | 256 |

- Tier 1 (idx 0–7): 8-byte spacing.  Tier 2 (idx 8–11): 16-byte spacing.
  Tier 3 (idx 12–15): 32-byte spacing.
- **16 classes.** `size → class` is a small branch ladder or a shift-indexed lookup table
  (see §9.1). Worst-case rounding: e.g. request 129 → class 160 = 24%.
- The table is emitted once in [HeapData.a68](HeapData.a68) as `__HeapSoaClassTbl` (with
  `SOA_NUM_CLASSES` in [heap.inc](heap.inc)) so allocation, validation, and tests share a
  single source of truth.

### 6.3 SOA Control Block (SCB)

Pointed to by `hhReserved` (renamed `hhSmallPool`). Allocated **lazily** from the owning
heap's regular block allocator the first time a small request arrives (so heaps that never
make small allocations pay nothing). Suggested layout (subject to Phase 1 finalization):

| Offset | Field | Size | Description |
|-------:|-------|-----:|-------------|
| `$00` | `scbMagic` | long | `'SCB '` sanity magic |
| `$04` | `scbHeap` | long | Back-pointer to owning heap header |
| `$08` | `scbArenaHead` | long | Head of arena list (see §6.4) |
| `$0C` | `scbFlags` | long | Reserved SOA-local flags |
| `$10` | `scbPartial[0..15]` | 16×long | Per-class head of **partial** slabs (have ≥ 1 free cell) |
| `$50` | `scbFull[0..15]` | 16×long | Per-class head of **full** slabs (0 free cells) |
| `$90` | `scbStats…` | n×long | Counters: live cells, live bytes requested, slab count |

> The full/partial split lets allocation find a slab with a free cell in O(1) (head of the
> partial list) and lets free promote a slab from full→partial in O(1).

### 6.4 Arenas

An **arena** provides `SLAB_SIZE`-aligned backing storage for slabs.

- An arena is a **regular heap block** obtained from the owning heap's block allocator, sized
  as a multiple of `SLAB_SIZE`. **Arena size is adaptive, not a fixed 64 KB:** it starts small
  (default `ARENA_SLABS_DFLT` tiles — e.g. 4 — adaptive down to a single-slab arena) and may scale up for
  larger heaps. A fixed `16 × SLAB_SIZE` = 64 KB arena would make the *first* small allocation
  fail on any private heap smaller than ~68 KB (arena + alignment slack), silently dropping to
  the block path and losing the density win exactly where G1 promised it (review S4).
  `slab_create` requests the smallest arena that yields at least one tile, bounded by the
  parent heap's free space.
- **Alignment:** the block allocator only guarantees 32-byte alignment, so the SOA requests
  `arena_bytes + SLAB_SIZE` and aligns the arena's usable base up to the next `SLAB_SIZE`
  boundary. The slack (< `SLAB_SIZE`, once per arena) holds the **arena descriptor**:

  | Offset | Field | Description |
  |-------:|-------|-------------|
  | `$00` | `arMagic` | `'AREN'` |
  | `$04` | `arBlock` | Pointer to the underlying regular block (for release) |
  | `$08` | `arNext`  | Next arena in the SCB arena list |
  | `$0C` | `arBase`  | First `SLAB_SIZE`-aligned slab address |
  | `$10` | `arSlabs` | Total slab slots (tiles) in this arena |
  | `$14` | `arSlabUse`| Slab tiles currently in use (whole-arena release when this hits 0) |
  | `$16` | `arTileMap`| Per-tile used/free **bitmap** (bit *i* set ⇒ tile *i* is a live slab). One longword covers up to 32 tiles. This — **not** the bare `arSlabUse` count — is what lets `slab_create` find a free tile, lets an individual empty slab be reclaimed, and drives the `_HeapValidate` in-use walk (review S1). |

- Arenas are created on demand when every partial/empty slab for a class is exhausted, and
  released back to the block allocator by `_HeapCompact`/`_HeapDestroy` when fully empty.
- **Tile allocation & reclamation** are driven by `arTileMap`: `slab_create` claims the first
  clear bit (formatting that tile as a slab); releasing a fully-empty slab clears its bit and
  decrements `arSlabUse`; when `arSlabUse` reaches 0 the whole arena block is returned to the
  parent heap. A bare count could neither locate a free tile nor enumerate live tiles.
- **Optional optimization (later phase):** add an internal `__HeapAllocAligned` primitive so
  arenas need no over-allocation slack. Deferred; the over-allocate-and-align method above is
  portable and correct.

### 6.5 Slabs & Slab Header

A slab is one `SLAB_SIZE` tile within an arena, serving one class. Header at tile base:

| Offset | Field | Size | Description |
|-------:|-------|-----:|-------------|
| `$00` | `slMagic` | long | `'SLAB'` — the free-path discriminator |
| `$04` | `slFlags`/`slId` | long | Flags **long** mirroring `bhFlags`/`hhId`: SOA slab flags in the **low word**, owning heap **ID in the high word**. The cross-heap check masks this long with `HEAP_ID_MASK` and compares to `hhFlags & HEAP_ID_MASK` — bit-identical to the block path (preserves G4). |
| `$08` | `slClass` | word | Size-class index (0..15) |
| `$0A` | `slCellSz`| word | Cell size in bytes (class value) |
| `$0C` | `slTotal` | word | Total cells in this slab |
| `$0E` | `slFree`  | word | Free-cell count |
| `$10` | `slFreeHd`| word | Head of intrusive free list (cell index; `$FFFF` = none) |
| `$12` | `slArena` | long | Owning arena descriptor (for release / walk) |
| `$16` | `slNext`  | long | Next slab in the class partial/full list |
| `$1A` | `slPrev`  | long | Prev slab in the class partial/full list |
| `$1E` | `(pad)` | 2 | Padding to `SLAB_HDR_SIZE` = `$20` |
| `$20` | `slCells` | — | First cell = `slab + SLAB_HDR_SIZE` (`$20`); ≥ 8-byte (longword) aligned |

`SLAB_HDR_SIZE` is a **single fixed constant, `$20` (32) — the 30-byte header rounded up to a
multiple of 8** (§8), *not* per-class.
Because the slab base is `SLAB_SIZE`-aligned, `SLAB_HDR_SIZE` is a multiple of 8, and every
class size is a multiple of 8, each cell is guaranteed **≥ 8-byte (longword) aligned** — this
is *not* class-size alignment (e.g. a 24-byte cell is not 24-aligned), but it is all that 68K
word/long access requires. Cells begin at `slab + SLAB_HDR_SIZE`; cell *i* =
`slab + SLAB_HDR_SIZE + i × slCellSz`.

### 6.6 Cells & the Intrusive Free List

- **Allocated cell:** the entire cell is user data. No header, no tail (see §10).
- **Free cell:** the first 4 bytes hold `[nextIndex:word][freeTag:word]`:
  - `nextIndex` = index of the next free cell (`$FFFF` = end).
  - `freeTag` = `SOA_FREE_TAG` (e.g. `$F2EE`), a cheap **double-free** guard: freeing a cell
    whose body already shows `freeTag` at a valid free position is reported as
    `HEAP_ERROR_DOUBLE_FREE` (§8; already free).
- Every class is ≥ 8 bytes, so the 4-byte free control always fits.
- Allocation pops `slFreeHd`; free pushes onto `slFreeHd`. Both O(1).

### 6.7 Pointer → Slab Discrimination (the free discriminator)

`_HeapFree(hHeap, pMem)` resolves the allocator kind as follows (see §9.4 for full pseudocode):

1. `pMem == NULL` → success (unchanged).
2. **SOA recognition** (is `pMem` a cell at all?): `slab = pMem & ~(SLAB_SIZE−1)`. `pMem` is a
   cell **iff** every one of:
   - `slab->slMagic == 'SLAB'`
   - `slab->slArena->arMagic == 'AREN'`
   - `arBase ≤ slab < arBase + arSlabs×SLAB_SIZE`
   - `(pMem − firstCell) mod slCellSz == 0`
   - `cellIndex < slTotal`
3. **If recognized as a cell, check ownership *separately*:** if `slab->slId == hHeap->hhId`
   take the **SOA free path**; otherwise return `HEAP_ERROR_HANDLE_BLOCK_MISMATCH` (a valid
   cell owned by another heap — mirrors the block path's `_hfInvalidHeap`). Ownership is **not**
   part of recognition: folding `slId` into step 2 would misreport a cross-heap cell as
   `HEAP_ERROR_INVALID_BLOCK`.
4. **Else (not a cell) — block probe:** `hdr = pMem − BLK_HDR_SIZE`. If `hdr->bhMagic == 'BLKH'`
   → existing block free path (unchanged).
5. Otherwise → `HEAP_ERROR_INVALID_BLOCK`.

Recognition is tried **first**. A genuine cell pointer always masks to a live slab header
(invariant I1). Because arenas are **not** address-separated from ordinary blocks, safety does
**not** rest on address separation — it rests on the recognition chain: a false positive would
require a forged `'SLAB'` header **and** a consistent `slArena` back-pointer to a forged
`'AREN'` descriptor whose range contains the slab, **and** exact cell modulus / range
agreement — effectively unforgeable by stray data. Ownership is then a **separate** step, so a
valid cell of another heap is reported as `HEAP_ERROR_HANDLE_BLOCK_MISMATCH` (preserving G4),
not silently rejected as an invalid block.

### 6.8 Heap Header & Flag Changes

- `hhReserved` (`$3C`) → **`hhSmallPool`**: pointer to the SCB, or `0` if no small alloc has
  occurred. Header size unchanged (C4 satisfied). `_HeapCreate`/`_MachineHeapInitialize`
  already zero this field, so existing heaps start with the SOA dormant.
- New flag bit (low word of `hhFlags`, bits 0–9 currently used; 10–15 free):
  - **`FLG_HEAP_DISABLE_SMALL_POOL` = 10**, mask `HEAP_DISABLE_SMALL_POOL = 1 shl 10`.
  - When set, `_HeapAlloc` skips the SOA entirely — exact legacy behavior. Used for A/B
    measurement and as a safety valve.
- The SOA is **on by default** (opt-out), so existing builds benefit without code changes.
  During Phases 1–5 it is gated **off by default** (opt-in) and flipped to opt-out in Phase 6
  once validated (see the tracker).

---

## 7. API Behavior Changes

| API | Change | Notes |
|-----|--------|-------|
| `_HeapAlloc` | If `lBytes ≤ SOA_MAX`, SOA enabled, and tail-check **not** requested → `soa_alloc`. | Zero/debug-fill honored (§10). Falls back to block path on SOA exhaustion of the parent heap. |
| `_HeapFree` | Discriminate cell vs. block (§6.7); route to `soa_free` or existing path. | NULL still succeeds. Cross-heap still detected. |
| `_HeapReAlloc` | Handle 4 transitions: small→small, small→large, large→small, large→large. | `HEAP_REALLOC_IN_PLACE_ONLY`: only same-class small→small and shrinking large→large can succeed in place; else fail. Same-class small **grow does not honor `ZERO_MEMORY`** (no per-cell size; §9.6/S3). See §9.6. |
| `_HeapSize` | For a cell, return the **class (usable) size**, not the original request. | Documented semantic (like `malloc_usable_size`). Callers relying on exact request for small allocs must not; API already returns "requested" only for blocks. See §16 Q3. |
| `_HeapValidate` | Extend to walk arenas → slabs → free lists; verify counts, magics, alignment, no double-free. | §10. |
| `_HeapValidateHandle` | Also sanity-check `hhSmallPool` (if non-NULL, `scbMagic == 'SCB '`). | Cheap. |
| `_HeapWalk` | Coarse mode: report each arena block once (Phases ≤ 5). Extended mode: descend into slabs to enumerate cells. | Extended mode is Phase 5. |
| `_HeapCompact` | Additionally release fully-empty slabs and fully-empty arenas back to the block allocator. | Improves post-burst footprint. |
| `_HeapDestroy` | Unchanged in spirit — freeing the heap's blocks reclaims arenas automatically. | SCB and arenas are regular blocks of the parent heap. |
| `_GetMachineHeaps` | Unaffected: it scans for `'HEAP'` handles, which arenas/SCBs do not carry. | Verify no false positives against `'AREN'`/`'SCB '`/`'SLAB'`. |

---

## 8. Data Structures & New Constants

To be added to [heap.inc](heap.inc) (names final in Phase 1):

```asm
; --- Small Object Allocator tunables ---
SOA_MAX            equ  256           ; Max request routed to the SOA
SOA_NUM_CLASSES    equ  16
SOA_MIN_CLASS      equ  8             ; Smallest size class = cell alignment (≥ 8-byte, longword)
SLAB_SIZE          equ  $1000         ; 4096, power of two (alignment granule)
SLAB_SIZE_MASK     equ  SLAB_SIZE-1
ARENA_MAX_SLABS    equ  32            ; Max tiles per arena (arTileMap is one longword)
ARENA_SLABS_DFLT   equ  4             ; Default tiles per NEW arena; adaptive down to 1 (§6.4, R9)
SOA_FREE_TAG       equ  $F2EE         ; Double-free guard word in free cells
SOA_NIL_INDEX      equ  $FFFF         ; Free-list end sentinel

; --- Magics ---
SCB_MAGIC          equ  'SCB '
AREN_MAGIC         equ  'AREN'
SLAB_MAGIC         equ  'SLAB'

; --- New heap flag ---
FLG_HEAP_DISABLE_SMALL_POOL equ 10
HEAP_DISABLE_SMALL_POOL     equ 1 shl FLG_HEAP_DISABLE_SMALL_POOL

; --- Heap header: repurpose reserved slot (offset unchanged) ---
hhSmallPool        equ  hhReserved    ; $3C : pointer to SCB or 0

; --- SCB / Arena / Slab offsets (see §6.3–6.5) ---
;   scb*  ...  ar*  ...  sl* ...
SLAB_HDR_SIZE      equ  $20           ; 32 bytes: 30-byte slab header rounded up to a multiple of 8
;   SCB_HDR_SIZE, AREN_HDR_SIZE (AREN includes arTileMap) finalized in Phase 1.

; --- New error codes (append; do not renumber existing) ---
HEAP_ERROR_SLAB_CORRUPT       equ  $15   ; Slab header/free-list inconsistent
HEAP_ERROR_DOUBLE_FREE        equ  $16   ; Cell already free (freeTag seen)
HEAP_ERROR_SOA_ARENA_CORRUPT  equ  $17   ; Arena descriptor inconsistent
```

The class table is emitted once (data, not in the shared include) in
[HeapData.a68](HeapData.a68) as a public symbol so every consumer shares one copy;
[heap.inc](heap.inc) carries only the scalar tunables (`SOA_MAX`, `SOA_NUM_CLASSES`, …):

```asm
	public 	__HeapSoaClassTbl
__HeapSoaClassTbl:  dc.w  8,16,24,32,40,48,56,64,80,96,112,128,160,192,224,256
```

New source files (mirroring the one-function-per-file convention):

| File | Contents |
|------|----------|
| `HeapSmallAlloc.a68`  | `__HeapSoaAlloc`, size→class, slab cell pop |
| `HeapSmallFree.a68`   | `__HeapSoaFree`, cell push, slab full↔partial↔empty |
| `HeapSlab.a68`        | `__HeapSlabCreate`, `__HeapSlabFromPtr`, `__HeapSlabRelease` |
| `HeapArena.a68`       | `__HeapArenaCreate`, `__HeapArenaRelease` |
| `HeapSmallCtl.a68`    | `__HeapScbGetOrCreate`, class list helpers, SOA stats |

Each is added to `HEAP_ELF_OBJS` and to the ELF/COFF/macOS makefiles with the same
`heap.inc` dependency line as existing objects.

---

## 9. Core Algorithms (pseudocode)

### 9.1 size → class index

```
soa_size_to_class(n):            ; n in 1..SOA_MAX
    if n <= 64:  return ((n + 7) >> 3) - 1               ; tier 1, 8-byte spacing
    if n <= 128: return 8  + (((n - 64) + 15) >> 4) - 1  ; tier 2, 16-byte spacing
    return           12 + (((n - 128) + 31) >> 5) - 1    ; tier 3, 32-byte spacing
    ; NB: parenthesize the shift — `x >> 3 - 1` binds as `x >> (3-1)` in C precedence.
    ; (final form validated against __HeapSoaClassTbl in Phase 1; a table search is the
    ;  reference implementation, the shift form is the optimization.)
```

### 9.2 SCB get-or-create

```
scb = hHeap->hhSmallPool
if scb == 0:
    scb = block_alloc(hHeap, SCB_HDR_SIZE)     ; via existing _HeapAlloc internals
    if scb == 0: return OUT_OF_MEMORY
    zero(scb); scb->scbMagic='SCB '; scb->scbHeap=hHeap
    hHeap->hhSmallPool = scb
return scb
```

### 9.3 soa_alloc

```
soa_alloc(hHeap, flags, n):
    cls   = soa_size_to_class(n)
    slab  = scb->scbPartial[cls]
    if slab == 0:
        slab = slab_create(hHeap, cls)          ; carve from arena; new arena if needed
        if slab == 0: return 0                   ; caller falls back to block path
        push slab onto scbPartial[cls]
    i     = slab->slFreeHd                        ; pop free list
    cell  = slab + SLAB_HDR_SIZE + i*slab->slCellSz
    slab->slFreeHd = nextIndex(cell)
    slab->slFree  -= 1
    if slab->slFree == 0: move slab Partial->Full
    fill_or_zero(cell, n, flags)                  ; §10
    stats: live_cells++, live_req_bytes += n
    return cell
```

### 9.4 free discrimination + soa_free

```
heap_free(hHeap, pMem):
    if pMem == 0: return TRUE
    slab = pMem & ~SLAB_SIZE_MASK
    ; --- recognition: is pMem a slab cell? (load-bearing chain, S2/§6.7) ---
    if slab->slMagic == 'SLAB'
       and slab->slArena->arMagic == 'AREN'
       and slab->slArena->arBase <= slab < slab->slArena->arBase + slab->slArena->arSlabs*SLAB_SIZE
       and (pMem - firstCell(slab)) mod slab->slCellSz == 0
       and cellIndex < slab->slTotal:
        ; --- recognized: check ownership SEPARATELY (D1) ---
        if slab->slId != hHeap->hhId: return HANDLE_BLOCK_MISMATCH
        return soa_free(hHeap, slab, pMem)
    ; else fall through to existing block free path
    hdr = pMem - BLK_HDR_SIZE
    if hdr->bhMagic == 'BLKH': return block_free(hHeap, pMem)   ; unchanged
    return INVALID_BLOCK

soa_free(hHeap, slab, cell):
    i = (cell - firstCell(slab)) / slab->slCellSz
    if freeTag(cell) == SOA_FREE_TAG and on_free_list(slab, i): return DOUBLE_FREE
    if debug_fill: fill(cell, BAADFOOD)          ; then write control word (§10)
    nextIndex(cell) = slab->slFreeHd; freeTag(cell)=SOA_FREE_TAG
    slab->slFreeHd  = i; slab->slFree += 1
    was_full = (slab->slFree == 1)
    if was_full: move slab Full->Partial
    if slab->slFree == slab->slTotal: slab_maybe_release(hHeap, slab)   ; empty
    stats: live_cells--
    return TRUE
```

### 9.5 slab_create / arena_create (sketch)

```
slab_create(hHeap, cls):
    ar = arena in scb->scbArenaHead whose arTileMap has a clear bit
    if none: ar = arena_create(hHeap)            ; over-allocate + align (§6.4); adaptive size
        if ar == 0: return 0
    t    = index of first clear bit in ar->arTileMap
    tile = ar->arBase + t*SLAB_SIZE
    set bit t in ar->arTileMap; ar->arSlabUse++
    format slab header: magic,'SLAB'; slId=hHeap->hhId; slClass=cls;
        slCellSz=__HeapSoaClassTbl[cls]; slTotal=(SLAB_SIZE-SLAB_HDR_SIZE)/slCellSz;
        build free list 0..slTotal-1; slFreeHd=0; slFree=slTotal; slArena=ar
    return tile

slab_maybe_release(hHeap, slab):                 ; when a slab becomes fully empty (§9.4)
    ar = slab->slArena
    unlink slab from its class partial list
    t  = (slab - ar->arBase) / SLAB_SIZE
    clear bit t in ar->arTileMap; ar->arSlabUse--
    if ar->arSlabUse == 0: arena_release(hHeap, ar)   ; whole arena block back to parent
```

### 9.6 realloc transitions

```
heap_realloc(hHeap, flags, pMem, n):
    kind, cur = classify(pMem)                    ; SOA cell (class size) or block (bhSize)
    newSmall  = (n <= SOA_MAX) and soa_enabled and not tail_check
    case (kind==SOA, newSmall):
      (SOA, small):
          if class(n) == cur.class: update nothing (same cell); return pMem
          if IN_PLACE_ONLY: return 0
          q = soa_alloc(...); copy min(n,cur.classSize); soa_free(pMem); return q
      (SOA, large):
          if IN_PLACE_ONLY: return 0
          q = block_alloc(n); copy min(n,cur.classSize); soa_free(pMem); return q
      (block, small):
          if IN_PLACE_ONLY: return 0              ; block→cell is always a move
          q = soa_alloc(n); copy n; block_free(pMem); return q
      (block, large):
          existing _HeapReAlloc grow/shrink logic, unchanged
```

> **Same-class grow does not honor `HEAP_ZERO_MEMORY` / debug-fill (accepted divergence).**
> The block path zeroes/`CD`-fills the newly exposed region using the per-block stored request
> size. The SOA stores **no per-cell request size** (§16 Q3), so a small realloc that grows
> *within one class* (e.g. 17 → 24) cannot tell which bytes are "new" and leaves them as-is.
> This is an explicit, documented divergence from the block path; callers needing zeroed
> growth on a small allocation should allocate at the final size up front (review S3).

---

## 10. Debug, Fill & Validation Semantics

- **Zero / debug fill on alloc:** honored per cell exactly as [`__FillBlock`](HeapAlloc.a68)
  does for blocks — `HEAP_ENABLE_DEBUG_FILL` → `$CDCDCDCD` over the class size;
  else `HEAP_ZERO_MEMORY` (per-call or per-heap) → zero. Fill spans the whole **cell** (class
  size), which is ≥ request, so no uninitialized bytes are exposed.
- **Debug fill on free:** fill the cell with `$BAADF00D`, **then** overwrite the first 4 bytes
  with the free-list control word (`nextIndex`,`freeTag`). Ordering matters: the control word
  must survive the fill.
- **Tail checking:** `HEAP_TAIL_CHECKING_ENABLED` adds a 32-byte guard, which would obliterate
  small-cell density. **Rule:** when tail-check is enabled for a heap, small requests are
  served by the **block path** (not the SOA), preserving overrun detection. Documented in
  [HEAP_API.md](HEAP_API.md) §3/§5.4 update. This is a deliberate, explicit exception to G6.
- **Validation (`_HeapValidate`) additions:**
  1. If `hhSmallPool != 0`: `scbMagic == 'SCB '`, `scbHeap == hHeap`.
  2. Walk `scbArenaHead`: each `arMagic == 'AREN'`; `arBase` is `SLAB_SIZE`-aligned;
     `arSlabUse ≤ arSlabs`; **`popcount(arTileMap) == arSlabUse`**; `arBlock` is a valid
     `'BLKH'` block of this heap.
  3. For each **set bit in `arTileMap`** (each live tile): `slMagic == 'SLAB'`; `slId == hhId`; `slClass < 16`;
     `slCellSz == __HeapSoaClassTbl[slClass]`; `slTotal` consistent with `SLAB_SIZE`;
     `0 ≤ slFree ≤ slTotal`.
  4. Walk the slab free list: exactly `slFree` nodes, all indices `< slTotal`, no cycles
     (bounded by `slTotal`), each free cell shows `freeTag` — this is the **double-free /
     corruption** detector.
  5. Cross-check: each slab appears on exactly one of its class's partial/full lists,
     consistent with `slFree` (`0` → full, else partial).

---

## 11. Assembly Implementation Guidelines

Codebase-specific pitfalls that this feature is especially prone to (the SOA has many small
helpers calling each other and juggling live pointers across calls):

- **Unique, routine-prefixed local labels.** The build is `/Cx` (case-sensitive) and modern
  `asm68K` errors `A2005` on duplicate labels, but keep labels unique and prefixed
  (`_soaAlloc…`, `_slbNew…`, `_arNew…`) to avoid a branch binding to a foreign `rts`. Never
  reuse bare `ret`/`done`/`loop`/`next` across the new modules.
- **Callee-saved discipline (C7).** Values that must **survive** a `bsr/jsr` (slab pointer,
  cell pointer, heap handle, class index) belong in **D2–D7 / A2–A6**, *not* D0/D1/A0/A1.
  Classic trap: stashing a live value in D1 then calling a helper that clobbers D1. When in
  doubt, `movem` push/pop around the call. Declare exactly the right `USES` list per `PROC`.
- **Size/placement fields written after a call.** Cell/slab placement math depends on
  `slCellSz`, `slTotal`, `SLAB_HDR_SIZE`. If any of these is read from a scratch register
  after a helper call, re-load it from the header or keep it callee-saved.
- **Byte-wide alignment masks.** Follow the existing idiom: `SLAB_SIZE-1` = `$0FFF` exceeds a
  byte, so mask with `andi.l #~SLAB_SIZE_MASK,dn` (longword), **not** the `andi.b` trick used
  for `BLK_HDR_SIZE-1` (`$1F`, which fits a byte). Getting this wrong silently corrupts the
  masked address.
- **Upper-byte invariant (C2).** After masking, the upper byte stays zero automatically; do
  not introduce sign extension (`movea.w`) on addresses.
- **One source of truth** for the class table (`__HeapSoaClassTbl` in `HeapData.a68`) shared by
  alloc, validate, and tests — divergent copies are a latent bug.

---

## 12. Testing & Measurement Strategy

### 12.1 Measurement harness (Phase 0)
Add an internal `__HeapStats(hHeap, pStruct)` (or extend `_HeapWalk`) that reports, without
changing behavior: total committed bytes, total requested bytes, per-size-bucket allocation
counts, and (once the SOA exists) live cells / slabs / arenas. This lets us **quantify the
before/after** on a real workload and drives class-table tuning (§16). The
[HeapTest.a68](HeapTest.a68) driver gains a scripted allocation mix.

### 12.2 Correctness tests
- **Unit:** `soa_size_to_class` vs. `__HeapSoaClassTbl` for all `n` in `1..256`; slab format
  math (`slTotal`, first-cell alignment) for every class; `__HeapSlabFromPtr` for the first,
  middle, last cell of a slab and for **near-miss** pointers (interior, off-by-one, foreign).
- **Round-trip:** alloc→write pattern→free→re-alloc; verify no aliasing across cells; verify
  a freed cell fails re-free with `HEAP_ERROR_DOUBLE_FREE`.
- **Cross-heap:** free a cell of heap A to heap B → `HEAP_ERROR_HANDLE_BLOCK_MISMATCH`.
- **Realloc matrix:** all four transitions × {grow, shrink, `IN_PLACE_ONLY`, `ZERO_MEMORY`}.
- **Fill/validate:** debug-fill patterns present; `_HeapValidate` passes on healthy heaps and
  **fails** on deliberately corrupted slab headers/free lists/counts.
- **Fallback:** with `HEAP_DISABLE_SMALL_POOL`, behavior is byte-for-byte legacy.

### 12.3 Stress / soak
Randomized alloc/free/realloc across sizes 1..4096 with mixed heaps, interleaved
`_HeapValidate`, run to arena creation and full release; assert invariants and that
`live_cells == 0` ⇒ all slabs empty and releasable. Compare committed-byte high-water mark
vs. the legacy allocator on the same seed.

### 12.4 Build/CI
All three makefiles (`makefile-elf`, `makefile-coff`, `makefile.macos`) build clean; new
objects link into `libheap-elf.a`; `heaptest.elf` runs the suite. **Rebuild everything** when
touching `heap.inc` (a shared header change invalidates all objects).

### 12.5 Observability — sid68k `!heap -p`
The `!heap -p [handle]` command ([`HeapDebugExt.cpp`](../../sid68k/sid68k/HeapDebugExt.cpp))
dumps the live SOA state: the SCB header (`scbLiveCells`, `scbLiveCellBytes`, `scbSlabCount`,
`scbArenaCount`), the arena table (base, block, tiles-used, `arTileMap`), and a per-class
table built by **walking** the `scbPartial[c]`/`scbFull[c]` lists.

**Counters vs. walked totals.** The SCB fields are *running counters* bumped by the low-level
primitives (`__HeapSlabCreate` → `scbSlabCount`; `__HeapSlabAlloc` → `scbLiveCells`), whereas
the per-class table only sees slabs **linked** onto a class list. The normal `_HeapSmallAlloc`
path always links the slab it fills, so on a pure `_HeapSmallAlloc`/`_HeapSmallFree` workload
the counters and the walk match exactly. But a caller that drives the primitives **directly**
— as the Phase 1–5 primitive unit tests do — creates slabs that are counted by the SCB yet
never linked, so `scbSlabCount`/`scbLiveCells` legitimately **exceed** the walked totals.
`-p` prints a `Note:` quantifying any such gap. A gap therefore signals direct primitive use
(e.g. `heapsmalltest`), **not** a leak or class-list corruption.

> Example (`heapsmalltest` machine heap): SCB reports 17 slabs / 39 live cells, while the
> per-class walk sums to 14 slabs / 32 used. The 3-slab, 7-cell gap is the classes-0/1/15
> slabs the Phase 3–5 tests build with `__HeapSlabCreate`/`__HeapSlabAlloc` directly (never
> linked, `slNext = slPrev = 0`), whose popped cells still bump the SCB counters.

---

## 13. Backward Compatibility & Migration

- **Binary/handle layout:** unchanged. Heap header stays `$40`; only the semantic of the
  reserved slot changes, and it is already zero-initialized on every existing heap.
- **API/ABI:** no prototype changes; no new required parameters. `heap.inc` only **adds**
  symbols and appends error codes (existing codes keep their values).
- **Behavioral:** with the SOA disabled (Phases 1–5 default, or via flag) behavior is
  identical to today. When the SOA is **on** there are two deliberate changes for small
  allocations: (a) `_HeapSize` returns class (usable) size (§7, §16 Q3); and (b) pointers are
  only **≥ 8-byte** aligned, not 32-byte aligned (C8). Change (b) breaks any caller that
  **tags the low 5 bits** of a heap pointer (a common 68K idiom); the Phase 6 audit (R10) must
  therefore cover pointer-alignment assumptions, not just `_HeapSize` callers.
- **Rollout:** opt-in during development; flip to opt-out (default-on) only after Phase 5
  validation passes and stats confirm the win (Phase 6).

---

## 14. Risks & Mitigations

| # | Risk | Impact | Mitigation |
|---|------|--------|-----------|
| R1 | Free misclassifies a block as a cell (or vice-versa) | Corruption / crash | Load-bearing discriminator chain (slab magic → `slArena`→`'AREN'` back-pointer + arena-range containment → cell modulus/range → heap-ID) — **not** address separation (arenas share the parent heap); extensive near-miss tests (§12.2). |
| R2 | Arena alignment slack (< `SLAB_SIZE`, once per arena) wastes memory — proportionally **worse** under the adaptive small-arena policy (R9), where a single-slab arena pays up to `SLAB_SIZE` slack for one tile | Reduced net win | The slack holds the arena descriptor (not pure waste); the `__HeapAllocAligned` block primitive (Q4) removes it entirely and matters most under R9; larger arenas amortize it where the heap can afford them. |
| R3 | Double-free of a cell silently reused | Data corruption | `freeTag` guard + free-list membership check on free; `_HeapValidate` free-list walk. |
| R4 | `_HeapSize` semantic change breaks a caller | Latent bug | Document loudly; provide `HEAP_DISABLE_SMALL_POOL`; audit in-tree callers. |
| R5 | Register-clobber / duplicate-label asm bugs | Heisenbugs | §11 guidelines; unique labels; strict `USES`; unit-test helpers in isolation. |
| R6 | Tail-check users lose overrun detection on small allocs | Reduced debug coverage | By design small+tail-check routes to the block path (§10); documented. |
| R7 | SCB/arena allocation fails under pressure | Small alloc fails | `soa_alloc` returns 0 → `_HeapAlloc` falls back to the block path transparently. |
| R8 | Fragmentation: many half-empty slabs pin arenas | Footprint regression | Full/partial lists favor filling existing slabs; `_HeapCompact` releases empty slabs/arenas; per-class slab caps (tuning, §16). |
| R9 | First small alloc needs a whole arena; a fixed 64 KB arena fails on small private heaps (< ~68 KB) → silent fallback to the block path, no density win | Missed G1 on small heaps | Adaptive/small default arena size — single-slab arenas allowed (§6.4); tuning knob (§16 Q7); `soa_alloc` still falls back safely (R7). |
| R10 | Default-on changes small-alloc **alignment** (cells ≥ 8-byte vs blocks 32-byte); callers tagging the low 5 bits of a heap pointer break | Latent bug / corruption | Broaden the Phase 6 audit and §13 migration notes to pointer-alignment assumptions (not just `_HeapSize`); `HEAP_DISABLE_SMALL_POOL` restores 32-byte-aligned blocks. |

---

## 15. Phased Implementation Plan & Progress Tracker

**Status legend:** ⬜ Not started · 🟨 In progress · ✅ Done · ⛔ Blocked

| Phase | Title | Status | Exit criteria |
|------:|-------|:------:|---------------|
| A | Analysis & this spec | ✅ | Spec reviewed & accepted |
| 0 | Measurement baseline & constants | ✅ | Constants/flag/errors + `__HeapStats` in `heap.inc`; ELF builds green & `heaptest.elf` links. COFF archiving deferred (pre-existing `ar` crash); macOS not host-buildable |
| 1 | SOA data structures & primitives | ✅ | SCB/arena/slab create + `__HeapSlabFromPtr` unit-tested (`heapsmalltest.elf` passes under sim68k); no API routing yet |
| 2 | Allocation path | ✅ | `_HeapAlloc` routes small (gated `SOA_ROUTE`, off in P2-5); fill/zero correct; falls back on failure; `heapsmalltest.elf` Phase 6 passes |
| 3 | Free path | ✅ | `_HeapFree` discriminates & frees cells; double-free & cross-heap detected; `heapsmalltest.elf` Phase 7 passes |
| 4 | ReAlloc & Size | ✅ | All four realloc transitions pass; `_HeapSize` returns class size for cells; `heapsmalltest.elf` Phase 8 passes |
| 5 | Validation, Walk, Compact | ✅ | `_HeapValidate` covers SOA; `__HeapSoaWalk` enumerates cells; `_HeapCompact` releases empties; `heapsmalltest.elf` Phase 9 passes |
| 6 | Default-on, docs, tooling, tuning | ✅ | Opt-out default; `HEAP_API.md` updated; sid68k `!heap` SOA-aware; stats confirm ≥ 2× (≥ 4× ≤32B) win |

### Phase 0 — Measurement baseline & constants  ✅ (ELF; COFF/macOS deferred)
- [x] Add SOA constants, magics, `FLG_HEAP_DISABLE_SMALL_POOL`, `__HeapSoaClassTbl`, and appended
      error codes to [heap.inc](heap.inc) (values only; no behavior). Class table emitted in
      [HeapData.a68](HeapData.a68) as `__HeapSoaClassTbl` (data, not the shared include).
- [x] `hhReserved` → `hhSmallPool` alias at the same offset `$3C`; create/init already zero it.
- [x] Implement [`__HeapStats`](HeapStats.a68): block-chain walk → committed vs. requested bytes,
      free/overhead totals, largest free block, and a request-size histogram (`HEAP_STATS`).
- [x] Extend [HeapTest.a68](HeapTest.a68) with a scripted small-allocation mix + `__HeapStats` snapshot.
- [x] `makefile-elf` builds clean; `libheap-elf.a` + `heaptest.elf` produced (nmake).
- [~] `makefile-coff`: all objects assemble under `/coff`; **archiving deferred** — `m68k-coff-ar.exe`
      (GNU ar 2.16.1) crashes (`0xC0000005`) on the multi-object list, reproduced without the new
      object. Pre-existing host/tool issue (known issue #11).
- [~] `makefile.macos`: corrected `-Cu` → `-Cx`; not buildable on the Windows host (macOS toolchain).

### Phase 1 — SOA data structures & primitives  ✅ (2026-07-21)
- [x] Create `HeapSmallCtl.a68`: `__HeapScbGetOrCreate`, class list head helpers (`__HeapClassListPush`/`__HeapClassListUnlink`).
- [x] Create `HeapArena.a68`: `__HeapArenaCreate` (over-allocate + align, adaptive shrink), `__HeapArenaRelease`.
- [x] Create `HeapSlab.a68`: `__HeapSlabCreate`, `__HeapSlabFromPtr`, `__HeapSlabRelease`.
- [x] Implement `__HeapSoaSizeToClass` (table reference + shift optimization, cross-checked against `__HeapSoaClassTbl`).
- [x] Unit-test primitives via `HeapSmallTest.a68` (no public-API routing): size→class (n=1..256), SCB create,
      arena create, slab create + free-list walk, and `__HeapSlabFromPtr` recognition (valid / mid-cell / out-of-range /
      foreign) all pass (`tResult=0`) under sim68k `--gdb` + sid68k. **Run:** `sim68k --gdb` then
      `G 500,A58,A4C` in `sid68k heapsmalltest.elf` (start addr **required**; A58=`_tdone`, A4C=`_tfail`).
- [x] Add new objects to `HEAP_ELF_OBJS` and all makefiles (ELF green; COFF/macOS carry the same Phase 0 caveats).

### Phase 2 — Allocation path  ✅ (2026-07-21)
- [x] Create [`HeapSmallAlloc.a68`](HeapSmallAlloc.a68): `__HeapSoaAlloc` (§9.3) — get/create SCB, pick a
      partial slab (create + link one on demand), pop a cell, move the slab Partial→Full when it fills.
- [x] Route `_HeapAlloc` small requests to the SOA, gated on SOA-enabled and tail-check-not-set. The gate
      is the assembly switch `SOA_ROUTE` in [heap.inc](heap.inc): **0** in Phases 1–5 (the routing block is
      conditionally assembled out so `_HeapFree`/`_HeapSize`/`_HeapValidate` stay legacy and the existing
      `heaptest.elf` is byte-for-byte unchanged); flipped to **1** in Phase 6. Verified the routing block
      assembles clean at `SOA_ROUTE=1`.
- [x] Honor `HEAP_ZERO_MEMORY` (per-call or per-heap) / `HEAP_ENABLE_DEBUG_FILL` per cell, filling the
      **whole cell** (class size, §10) so no uninitialized bytes are exposed.
- [x] Fall back to the block path when `__HeapSoaAlloc` returns 0 (slab/arena creation failed).
- [x] Tests: `HeapSmallTest.a68` Phase 6 — basic alloc + `__HeapSlabFromPtr` recognition + class, adjacent
      cells + live-cell stats, whole-cell zero-fill (free-list control word preserved), fill-to-full →
      Partial→Full + new slab, and a 16-class sweep. All pass (`tResult=0`) under sim68k.
- [x] Add `HeapSmallAlloc.o` to `HEAP_ELF_OBJS` and all three makefiles (also back-filled the Phase 1
      SOA objects into `makefile-coff`/`makefile.macos` for consistency).

### Phase 3 — Free path  ✅ (2026-07-21)
- [x] Create [`HeapSmallFree.a68`](HeapSmallFree.a68): `__HeapSoaFree` (§9.4) — compute cell index, push
      the cell back on the slab free list, and drive the full→partial (unlink `scbFull`→push `scbPartial`)
      and partial→empty (unlink `scbPartial` + `__HeapSlabRelease`) transitions.
- [x] Add the discriminator to `_HeapFree` (gated `SOA_ROUTE`): probe `__HeapSlabFromPtr` first — a hit
      takes the SOA free path (after the `slId`↔`hhId` ownership check), otherwise fall through to the
      legacy block free path. Verified the gated block assembles clean at `SOA_ROUTE=1`.
- [x] Double-free (`freeTag` + bounded free-list membership walk → `HEAP_ERROR_DOUBLE_FREE`) and
      cross-heap (`slId` vs `hhId`) detection.
- [x] Debug-fill-on-free ordering: fill the **whole cell** with `BAADF00D` **then** write the control
      word (`nextIdx`/`freeTag`), so the free-list linkage survives the poison fill (§10).
- [x] Decrement only `scbLiveCells` on free (per-cell request size is not stored, Q3/§9.4).
- [x] Tests: `HeapSmallTest.a68` Phase 7 — round-trip alloc/free/re-alloc-reuse, double-free rejection,
      debug-fill-on-free (control word survives, body poisoned; anchor cell keeps the slab alive so the
      free does not release+refill the arena), full→partial + empty-slab release on a private heap, and a
      cross-heap `slId` ownership proxy. All pass (`tResult=0`) under sim68k.

### Phase 4 — ReAlloc & Size  ✅ (2026-07-21)
- [x] `_HeapSize`: gated cell path — recognize the cell via `__HeapSlabFromPtr`, verify
      ownership (`slId`↔`hhId`, else `HANDLE_BLOCK_MISMATCH`), and return `slCellSz` (the
      class/usable size, §16 Q3).  Falls through to the block path otherwise.
- [x] Create [`HeapSmallReAlloc.a68`](HeapSmallReAlloc.a68): `__HeapSoaReAlloc` implements the
      cell-origin transition matrix (§9.6): same-class → keep the cell (no `ZERO_MEMORY` on a
      same-class grow, S3); different small class → new cell + copy + free; small→large → new
      block + copy + free.  Uses `__HeapSoaAlloc`/`__HeapSoaFree` directly for cells and
      `_HeapAlloc` for the large case, so it is correct independent of `SOA_ROUTE`.
- [x] `_HeapReAlloc`: gated discriminator — `__HeapSlabFromPtr` probe + ownership check hands a
      cell off to `__HeapSoaReAlloc`; a block falls through to the legacy realloc path.
- [x] `HEAP_REALLOC_IN_PLACE_ONLY` honored: only the same-class case succeeds in place; every
      move fails with `HEAP_ERROR_OUT_OF_MEMORY`, leaving the original cell untouched.  The
      new region is filled/zeroed by the underlying allocator, so a cross-class/large grow with
      `HEAP_ZERO_MEMORY` gets its exposed tail zeroed for free.
- [x] All five gated/SOA files assemble clean `/Cx` at `SOA_ROUTE=1`; kept at `0`.
- [x] Tests: `HeapSmallTest.a68` Phase 8 ($08xx) — same-class keep + data preserved, cross-class
      grow (moved, copied, old cell freed, new class size), small→large (cell→block, copied),
      `IN_PLACE_ONLY` move rejected (original live + intact), same-class in-place success.  All
      pass (`tResult=0`) under sim68k.

### Phase 5 — Validation, Walk, Compact  ✅ (2026-07-21)
- [x] Create [`HeapSmallValidate.a68`](HeapSmallValidate.a68): `__HeapSoaValidate` performs the full
      §10 sweep — SCB magic/back-pointer; per-arena magic, `arBase` alignment, `arSlabUse ≤ arSlabs`,
      `popcount(arTileMap) == arSlabUse`, `arBlock` carries `'BLKH'`; per live-tile slab magic/`slId`/
      class/`slCellSz`/`slTotal`/`slFree` bounds; free-list length == `slFree` with in-range indices,
      `freeTag` present and a cycle bound; and class-list consistency (partial ⇒ `slFree>0`, full ⇒
      `slFree==0`).  Wired into `_HeapValidate` (gated) for a whole-heap check only (`pBlock==NULL`).
- [x] `_HeapValidateHandle`: gated SCB sanity check — if `hhSmallPool != 0` it must carry `'SCB '`.
- [x] Create [`HeapSmallWalk.a68`](HeapSmallWalk.a68): `__HeapSoaWalk(hHeap, pCursor)` enumerates live
      cells one per call via a 3-longword cursor `{swArena, swTile, swCell}` (a cell is reported when
      it is not on its slab's free list).  This is the design's companion option; `_HeapWalk`'s coarse
      mode already reports arena/SCB blocks since those are ordinary parent-heap blocks.
- [x] Create [`HeapSmallCompact.a68`](HeapSmallCompact.a68): `__HeapSoaCompact` releases every fully
      empty slab (and the arena once its last tile goes).  Wired into `_HeapCompact` (gated).  Note the
      free path already releases empties eagerly, so this is a belt-and-suspenders sweep.
- [x] All gated hooks assemble clean `/Cx` at `SOA_ROUTE=1`; kept at `0`.  Three objects added to all
      makefiles; `__HeapSoaValidate`/`__HeapSoaCompact`/`__HeapSoaWalk` PROTOs + walk-cursor offsets
      added to `heap.inc`.
- [x] Tests: `HeapSmallTest.a68` Phase 9 ($09xx) — validate passes on the populated machine heap; a
      corrupted `slMagic` is caught (`HEAP_ERROR_SLAB_CORRUPT`) and repair re-validates; compact
      succeeds and re-validates; alloc/free three cells on a private heap drives `scbLiveCells` and
      `scbArenaCount` to zero (eager release) with compact a clean no-op; walk enumerates exactly the
      four cells allocated (count + XOR checksum).  All pass (`tResult=0`) under sim68k.

### Phase 6 — Default-on, docs, tooling, tuning  ✅ (2026-07-21)
- [x] Flip default to opt-out (SOA on unless `HEAP_DISABLE_SMALL_POOL`): `SOA_ROUTE equ 1` in
      [heap.inc](heap.inc). Fixed the SCB-alloc recursion this exposed — `SCB_HDR_SIZE`=$A0 ≤
      `SOA_MAX`, so `__HeapScbGetOrCreate`'s own `_HeapAlloc(160)` would re-enter the SOA. Broke it
      by (a) allocating the SCB with `HEAP_DISABLE_SMALL_POOL` as `lFlags` in
      [HeapSmallCtl.a68](HeapSmallCtl.a68), and (b) honoring the per-**call** disable flag in the
      [HeapAlloc.a68](HeapAlloc.a68) gate. `heapsmalltest.elf` passes all 9 phases at `SOA_ROUTE=1`
      (`tResult=0`, `G 500,1780,1774` + `DL 3948`). (`heaptest.elf` is a CP/M base-page harness and
      cannot run under a bare sim68k `G 500` — it faults at PC=0x520 **before** any heap call,
      identically at `SOA_ROUTE=0`; not a regression. `heapsmalltest` is the authoritative test.)
- [x] Audited in-tree callers for exact-`_HeapSize`-request and pointer-alignment (low-5-bit
      tagging) assumptions (R4, R10): **zero** consumers use `_HeapSize`; no heap-pointer low-bit
      tagging exists — every low-bit mask found (asm68K encoder, BCD, hex) is register-field/nibble/
      char extraction, not pointer tagging. Flip is safe for asm68k, bas68k, tbasic, cpm68k.
- [x] Updated [HEAP_API.md](HEAP_API.md): `HEAP_DISABLE_SMALL_POOL` flag (bit 10, per-heap and
      per-call), error codes `$15`-`$17`, `hhReserved`→`hhSmallPool`, `_HeapAlloc` SOA routing note,
      `_HeapSize` class-size semantics, new §2.7 *Small Object Allocator (SOA)* section, TOC entry, and
      moved the implemented "per-allocation size classes" item out of §10 Future Enhancements.
- [x] Made the sid68k `!heap` extension ([`HeapDebugExt.cpp`](../../sid68k/sid68k/HeapDebugExt.cpp))
      SOA-aware: added `SCB`/`AREN`/`SLAB` struct defs (byte-packed so `offsetof` matches the on-target
      layout) + constants + magics, `hhReserved`→`hhSmallPool`, flag bit 10, error codes `$15`-`$17`, and
      a new `-p` subcommand (`OnHeapPool`) that dumps the SCB summary, the arena list, and per-class
      slab/cell (total/used/free + used-bytes) occupancy. **Rebuilt and validated:** `cmake --build
      builds/win64 --target sid68k --config Release` compiles `HeapDebugExt.cpp` clean and relinks
      `sid68k.exe` (MSVC). The extension is the normal, fully-defined `!heap` command handler set — it is
      **not** a WIP.
- [x] Tuning: kept `SOA_MAX=256`, `SLAB_SIZE=4096`, `ARENA_SLABS_DFLT=4`, and the 16-class table.
      Rationale — 4096-byte slabs bound alignment slack while giving 500+ cells/slab at the small end
      (per-cell metadata share < 0.1 B); 16 geometric-ish classes bound worst-case rounding to < 25%.
      No workload histogram indicated a 12/20-byte class is needed. Constants left as-is; revisit only
      on measured demand (Q1/Q2/Q6).
- [x] Efficiency (G1/G5) confirmed by design analysis (footprint per live small allocation):
      `1 B → 8 B` cell vs `64 B` block = **8×**; `16 B → 16 B` vs `64 B` = **4×**; `32 B → 32 B` vs
      `64 B` = **2×**; `64 B → 64 B` vs `96 B` = **1.5×**; `≤32 B` requests meet the ≥ 4× goal and the
      whole `≤256 B` range meets ≥ 2× except the very top class (224/256 B), where block rounding is
      already tight. Alloc/free stay O(1) amortized (pop/push a slab free-list cell; class list is a
      per-class head). (Runtime `__HeapStats` snapshot deferred — `heaptest`'s stats harness needs the
      CP/M base page and cannot run under sim68k; the win is structural, not workload-dependent.)

---

## 16. Open Questions & Tuning Parameters

> **Lock before Phase 1** (each changes the on-wire SCB/arena/slab structures): **Q3**
> (per-cell request size — confirmed *not* stored), **Q8** (free-tile tracking — bitmap), and
> **Q7** (arena sizing — adaptive/small). Q1/Q2/Q4/Q5/Q6 are Phase 6 tuning.

- **Q1 `SLAB_SIZE`.** 4096 balances cells-per-slab against alignment slack. Smaller slabs
  reduce slack waste but raise per-cell metadata share and slab churn. *Tune in Phase 6.*
- **Q2 `SOA_MAX` / class table.** 256 with 16 classes bounds rounding to < 25%. A workload
  histogram (Phase 0) may justify shifting boundaries or adding classes (e.g. a 12- or
  20-byte class if those dominate). *Data-driven in Phase 6.*
- **Q3 Per-cell request size & `_HeapSize` semantics.** **Decision (lock before Phase 1): the
  per-cell request size is *not* stored** (storing it costs per-cell bytes, defeating density).
  Two accepted consequences: `_HeapSize` returns **class (usable) size**, and same-class
  realloc-grow cannot honor `ZERO_MEMORY`/debug-fill (S3/§9.6). Revisit only if a real caller
  needs the exact request size for small allocations.
- **Q4 Arena alignment.** Over-allocate-and-align (portable, small slack) vs. a new
  `__HeapAllocAligned` block primitive (no slack, more code). Start portable; optimize later.
- **Q5 Double-free strength.** `freeTag` + free-list membership (chosen) vs. a per-slab
  in-use bitmap (stronger, costs slab-header space). Add a bitmap only if soak testing shows
  the tag insufficient.
- **Q6 Per-class slab cap / empty-slab retention.** Keep one empty slab per class cached to
  avoid create/release thrash, or release eagerly for minimum footprint. *Tune in Phase 6.*
- **Q7 Arena sizing policy (lock before Phase 1).** Fixed 64 KB vs. adaptive/small (single-slab
  arenas allowed). **Chosen: adaptive**, defaulting small and sized against the parent heap's
  free space, so small private heaps still get the density win (review S4). *Confirm default in
  Phase 1; tune in Phase 6.*
- **Q8 Free-tile tracking (lock before Phase 1).** Per-arena used/free **bitmap** (**chosen** —
  `arTileMap`, §6.4) vs. a bump-allocate-only policy with whole-arena release only. The bitmap
  is required for `slab_create` free-tile lookup, individual empty-slab reclamation, and the
  `_HeapValidate` walk (review S1).

---

## 17. Changelog

| Date | Version | Change |
|------|---------|--------|
| 2026-07-20 | Draft v1.0 | Initial architecture & phased plan authored. |
| 2026-07-20 | Phase 0 | Added SOA constants/flag/error codes + `HEAP_STATS` struct to `heap.inc`; `hhReserved`→`hhSmallPool`; `__HeapSoaClassTbl` in `HeapData.a68`; implemented `__HeapStats` (`HeapStats.a68`); wired all 3 makefiles; extended `HeapTest.a68`. ELF build verified; `makefile.macos` flag corrected to `-Cx`. COFF archiving deferred (pre-existing `ar` crash). |
| 2026-07-20 | Review v1.1 | Applied design-review S1–S5 & N1–N5: arena free-tile **bitmap** (`arTileMap`) + `slab_maybe_release` (S1); load-bearing discriminator with `slArena`→`'AREN'` chained check, reworded I1/R1/§6.7 (S2); documented same-class realloc-zero divergence (S3); **adaptive** arena sizing + R9 (S4); broadened alignment audit — R10, §13, Phase 6 (S5); fixed §9.1 shift precedence (N1); alignment restated ≥ 8-byte in C8/§6.5 (N2); slab flags/ID as a long mirroring `hhFlags`/`hhId` (N3); `SLAB_HDR_SIZE` fixed multiple of 8 (N4); double-free code `$16` in §6.6 (N5); added §16 Q7/Q8 + lock-before-Phase-1 note. |
| 2026-07-20 | Review v1.2 | Round-2 fixes: **D1** — §6.7 separates cell *recognition* from *ownership* (a cross-heap cell now reports `HEAP_ERROR_HANDLE_BLOCK_MISMATCH`, not `INVALID_BLOCK`); **D2** — §9.4 pseudocode carries the S2 arena-chain (`slArena`→`'AREN'` + arena-range) checks; unified `__HeapSoaClassTbl` name (§10/§12.2/Phase 0/6); pinned `SLAB_HDR_SIZE = $20` (§8/§6.5); split the arena constant into `ARENA_MAX_SLABS`/`ARENA_SLABS_DFLT` and reconciled §6.4/R2 with the adaptive policy. |
| 2026-07-20 | Phase 0 sync | Synced `heap.inc` to the revised constants: `ARENA_SLABS` → `ARENA_MAX_SLABS` (32) + `ARENA_SLABS_DFLT` (4); added `SLAB_HDR_SIZE = $20`. No behavior change; ELF rebuild clean. Also documented `SOA_MIN_CLASS = 8` in §8 to match `heap.inc`. |
| 2026-07-21 | Phases 1–5 | SOA implemented & validated under sim68k (`heapsmalltest.elf`, gated `SOA_ROUTE=0`): data structures/primitives (P1), allocation (P2), free + double-free/cross-heap (P3), realloc + `_HeapSize` class-size (P4), validate/walk/compact (P5). See the per-phase checklists above. |
| 2026-07-21 | Phase 6 | **Default-on:** `SOA_ROUTE=1` (opt-out). Fixed the SCB-alloc recursion (`SCB_HDR_SIZE ≤ SOA_MAX`) via `HEAP_DISABLE_SMALL_POOL` on the SCB alloc + a per-call disable check in the `_HeapAlloc` gate. Caller audit clean (no `_HeapSize`/pointer-tagging consumers). Updated `HEAP_API.md` (flag, errors `$15`-`$17`, `hhSmallPool`, `_HeapSize` semantics, new §2.7). Made sid68k `HeapDebugExt.cpp` SOA-aware (structs + `-p` dump; `sid68k.exe` rebuilt clean via CMake/MSVC). Constants kept; efficiency ≥2× (≥4× ≤32B) confirmed by analysis. `heapsmalltest.elf` all 9 phases pass at `SOA_ROUTE=1`. |
| 2026-07-21 | Review fixes | Code-review F1–F3: **F1** — `scbLiveReqBytes` (add-on-alloc only, monotonic) reworked into a symmetric **live** gauge and **renamed `scbLiveCellBytes`** — alloc adds `slCellSz`, free subtracts it (captured before any slab/arena release); `-p` label → "Live cell bytes". Validated: 39 live cells → 5880 = Σ(class size × live cells). **F2** — `__HeapSlabFromPtr` now rejects `slClass ≥ SOA_NUM_CLASSES` or `slCellSz == 0` **before** the `divu`, closing a ÷0-trap path in the "reject arbitrary pointers" gate. **F3** — `__HeapSlabCreate` first-clear-bit tile scan is now **bounded by `arSlabs`** (no bit-index wrap on a map/count desync). No regression (`heapsmalltest.elf` 9 phases pass). |
