# Heap Small-Allocation Efficiency — Architecture & Design Spec

**Status:** Implemented, SOA default-on; source-audited 2026-11-09.
**Target:** `out/lib/libheap.a` (m68k ELF). The original Draft v1.2 decisions
and completed phase history are retained below.
**Related docs:** [HEAP_API.md](HEAP_API.md), [heap.inc](../src/heap.inc)

**NM1 backing update (2026-10-05):** The aligned regular allocator and separately
owned arena descriptors are implemented. Section 6.4 describes the current
layout; the original phase history below remains historical.

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

The regular block path allocates each request as an independent block with a **32-byte
block header** (`BLK_HDR_SIZE`) and rounds every data area up to a **32-byte granule**. For
large allocations this overhead is negligible, but for the small allocations that dominate
most workloads (list nodes, string fragments, small structs, handles) the overhead is
catastrophic: a 1–32 byte request consumes **64 bytes** of heap, and a 33–64 byte request
consumes **96 bytes**.

The implemented SOA serves qualifying small requests without a per-cell block
header. This document describes the current architecture and algorithms and
retains the original options and
[phase history](#15-phased-implementation-plan--progress-tracker).
Public signatures and calling conventions are unchanged; alignment, size
queries, and same-class realloc initialization have the documented differences
in §7 and §13.

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

### 2.1 Regular-block footprint (SOA disabled, no debug flags)

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

**Takeaway:** header/granule waste is especially high for small requests
(a 1-byte request occupies 64 bytes). A regular-block workload dominated by
16-byte nodes uses only ~25% of that committed block space for requested data.

### 2.2 Dense-slab footprint (illustrative, not a whole-heap guarantee)

With a slab of `SLAB_SIZE = 4096`, a 32-byte slab header, and no per-cell header, the
metadata cost is `slab_header / cells_per_slab` per allocation, plus request→class rounding.

| Request | Class | Cell size | Amortized meta* | **Effective total** | vs. regular block |
|--------:|------:|----------:|----------------:|--------------------:|------------:|
| 1   | 8   | 8   | ~0.06 | **~8**   | 64 → 8   (8.0×) |
| 8   | 8   | 8   | ~0.06 | **~8**   | 64 → 8   (8.0×) |
| 16  | 16  | 16  | ~0.13 | **~16**  | 64 → 16  (4.0×) |
| 24  | 24  | 24  | ~0.19 | **~24**  | 64 → 24  (2.7×) |
| 48  | 48  | 48  | ~0.38 | **~48**  | 96 → 48  (2.0×) |
| 64  | 64  | 64  | ~0.50 | **~64**  | 96 → 64  (1.5×) |

*Amortized meta = `32 / (⌊(4096−32)/cell⌋)`. This table excludes slab-end
remainder, unused cells, the SCB, and arena descriptor/backing overhead.
Request-to-class rounding is bounded in **bytes** by the tier spacing (§6.2),
not by a universal percentage: 1 → 8 rounds up by 700% of the request.

**Interpretation:** dense 8/16/32/64-byte cells replace 64/64/64/96-byte
regular blocks before shared costs are counted: approximately 8×/4×/2×/1.5×,
respectively. First-use cost and low occupancy can outweigh those savings.

---

## 3. Goals & Non-Goals

### Goals

- **G1** Reduce repeated small-allocation overhead by amortizing metadata.
  Measure whole-workload commitment; no fixed reduction factor is guaranteed
  for every request size or occupancy level (§2.2).
- **G2** Preserve the entire public API surface and calling convention unchanged
  ([HEAP_API.md §5](HEAP_API.md)). Callers relying on exact small-request size
  reporting or 32-byte alignment must opt out or adapt (§13).
- **G3** Preserve `_HeapFree(hHeap, pMem)` semantics — free must work from the returned
  pointer **alone**, with no size argument and no caller-side bookkeeping.
- **G4** Preserve cross-heap ownership detection (heap-ID check) and per-heap flag isolation.
- **G5** Keep the cell pop/push and class-list transitions constant-time.
  Arena searches/creation/release, validation, and the tag-triggered bounded
  free-list membership check are not constant-time guarantees.
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
| C1 | Free receives only `(hHeap, pMem)`. The allocator kind and size class must be **recoverable from `pMem` alone**. | [HeapFree.a68](../src/HeapFree.a68) |
| C2 | The **upper byte of every valid address is zero**; a non-zero upper byte signals corruption. Pointer masking must preserve this. | [HeapFree.a68](../src/HeapFree.a68), [HEAP_API.md §2.1](HEAP_API.md) |
| C3 | Heap identity lives in the **high word of the flags longword** (`HEAP_ID_MASK = $FFFF0000`); ownership is a mask-and-compare. | [heap.inc](../src/heap.inc) |
| C4 | The heap header remains `$40` bytes; the former `hhReserved` (`$3C`) is now `hhSmallPool`. | [heap.inc](../src/heap.inc) |
| C5 | Per-call `HEAP_ZERO_MEMORY` enables zeroing; zero flags do not disable heap-level zeroing, and heap debug fill takes precedence. | [HeapAlloc.a68](../src/HeapAlloc.a68) |
| C6 | Build is **case-sensitive** (`/Cx`); labels differing only in case are distinct. | [makefile](../makefile) |
| C7 | 68K ABI in this codebase: **D0/D1/A0/A1 = caller-saved** (scratch); **D2–D7/A2–A6 = callee-saved**. `PROC`/`ENDP` `USES` lists enforce this. | [HEAP_API.md §8](HEAP_API.md) |
| C8 | Regular pointers are 32-byte aligned; SOA cells guarantee only **8-byte** alignment, enough for 68K word/long access, not class-size alignment. | [heap.inc](../src/heap.inc), [HeapSlab.a68](../src/HeapSlab.a68) |

**Design invariant added by this spec:**

- **I1 — Slab masking invariant:** every in-use SOA cell pointer `P` satisfies
  `(P & ~(SLAB_SIZE−1))` = the address of a live slab header whose `slMagic == 'SLAB'`.
  This is guaranteed by allocating slabs only inside `SLAB_SIZE`-aligned arenas (see §6.4).
  **The implication is one-way:** a real cell always masks to a real slab header, but arenas
  share the parent heap's address space with ordinary blocks, so this does **not** by itself
  prove that an arbitrary pointer masking to a `'SLAB'`-looking header is a cell. That
  direction is screened by the structural checks in §6.7, **not** by address
  separation. They are not an authenticity or arbitrary-pointer safety
  guarantee: callers must still pass valid, live allocation pointers.

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
keeps constant-time cell-list operations, and is additive to the regular path.

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

Arena descriptor (separate regular block) -> aligned regular backing block:
  ┌─────────── SLAB_SIZE ───────────┬─────────── SLAB_SIZE ───────────┬─ ...
  │ Slab header │ cell │ cell │ ...  │ Slab header │ cell │ cell │ ...  │
  └──────────────────────────────────┴──────────────────────────────────┘
       one size class per slab             a different (or same) class

Free path:  P & ~(SLAB_SIZE-1) ──► slab header ('SLAB', class, heapId, free list)
```

- Requests with `1 ≤ size ≤ SOA_MAX`, SOA enabled on the heap and call, and
  heap tail checking off attempt the SOA. `_HeapAlloc` falls back to regular
  allocation if that attempt fails; zero-byte requests bypass the SOA.
- All other requests use the existing segregated-bucket block allocator, **unchanged**.
- A **slab** serves exactly one size class. Cells have **no header**; a *free* cell stores
  its free-list link (and a free tag) in its own body, reused as user data when allocated.
- Slabs live inside `SLAB_SIZE`-aligned **arenas** so that free can recover the slab by
  masking the cell pointer (invariant I1).

### 6.2 Size Classes

`SOA_MAX = 256`. Classes are multiples of 8. Tier spacing limits added
rounding to 0–7 bytes for requests 1–64, 0–15 for 65–128, and 0–31 for
129–256. The relative percentage can be much larger than 25% for tiny requests.

| Idx | Class | Idx | Class | Idx | Class | Idx | Class |
|----:|------:|----:|------:|----:|------:|----:|------:|
| 0 | 8   | 4 | 40 | 8  | 80  | 12 | 160 |
| 1 | 16  | 5 | 48 | 9  | 96  | 13 | 192 |
| 2 | 24  | 6 | 56 | 10 | 112 | 14 | 224 |
| 3 | 32  | 7 | 64 | 11 | 128 | 15 | 256 |

- Tier 1 (idx 0–7): 8-byte spacing.  Tier 2 (idx 8–11): 16-byte spacing.
  Tier 3 (idx 12–15): 32-byte spacing.
- **16 classes.** `__HeapSoaSizeToClass` implements the shift formulas in
  §9.1 and is cross-checked against the class table. For example, 129 → 160
  adds 31 bytes (~24%); 1 → 8 adds 7 bytes (700%).
- The table is emitted once in [HeapData.a68](../src/HeapData.a68) as `__HeapSoaClassTbl` (with
  `SOA_NUM_CLASSES` in [heap.inc](../src/heap.inc)) so allocation, validation, and tests share a
  single source of truth.

### 6.3 SOA Control Block (SCB)

Pointed to by `hhReserved` (renamed `hhSmallPool`). Allocated **lazily** from the owning
heap's regular block allocator the first time a small request arrives (so heaps that never
make small allocations pay nothing). The current layout is:

| Offset | Field | Size | Description |
|-------:|-------|-----:|-------------|
| `$00` | `scbMagic` | long | `'SCB '` sanity magic |
| `$04` | `scbHeap` | long | Back-pointer to owning heap header |
| `$08` | `scbArenaHead` | long | Head of arena list (see §6.4) |
| `$0C` | `scbFlags` | long | Reserved SOA-local flags |
| `$10` | `scbPartial[0..15]` | 16×long | Per-class head of **partial** slabs (have ≥ 1 free cell) |
| `$50` | `scbFull[0..15]` | 16×long | Per-class head of **full** slabs (0 free cells) |
| `$90` | `scbLiveCells` | long | Live caller cells |
| `$94` | `scbLiveCellBytes` | long | Sum of live usable class bytes, not original requests |
| `$98` | `scbSlabCount` | long | Live slab tiles |
| `$9C` | `scbArenaCount` | long | Backing arenas |

> The full/partial split lets allocation find a slab with a free cell in O(1) (head of the
> partial list) and lets free promote a slab from full→partial in O(1).

`SCB_HDR_SIZE = $A0` (160 bytes), normally 192 committed bytes including
its regular block header. The SCB is explicitly zeroed after allocation,
regardless of debug-fill precedence, and remains allocated after all cells,
slabs, and arenas have been released. Destruction of its owning private heap
reclaims it with the containing storage.

### 6.4 Arenas

An **arena** provides `SLAB_SIZE`-aligned backing storage for slabs.

- An arena owns a **regular backing block** and a separate compact descriptor.
  The backing request is an exact multiple of `SLAB_SIZE`.
  **Arena size is adaptive, not a fixed 64 KB:** it starts small
  (`ARENA_SLABS_DFLT = 4` tiles), and if that backing request fails retries
  **one** tile, not a 4→2→1 search. Normal slab creation does not automatically
  scale arena requests upward on larger heaps. A fixed 64 KB arena would make the *first* small allocation
  fail on any private heap smaller than ~68 KB (arena + alignment slack), silently dropping to
  the block path and losing the density win exactly where G1 promised it (review S4).
  The internal arena helper accepts explicit tile counts clamped to 1–32.
- **Alignment:** `__HeapAllocAligned` returns a regular-block data pointer
  aligned to `SLAB_SIZE`. It searches before mutating, returns legal
  prefix/suffix fragments to the existing buckets, and reports any retained
  zero-to-32-byte suffix. The descriptor is a separate non-SOA regular block:

  | Offset | Field | Size | Description |
  |-------:|-------|-----:|-------------|
  | `$00` | `arMagic` | long | `'AREN'` |
  | `$04` | `arBlock` | long | Backing data pointer, not its block header |
  | `$08` | `arNext` | long | Next separately owned arena descriptor |
  | `$0C` | `arBase` | long | Aligned first tile, equal to `arBlock` |
  | `$10` | `arSlabs` | word | Reserved tile count, 1 through 32 |
  | `$12` | `arSlabUse` | word | Live tiles; final release frees backing and descriptor |
  | `$14` | `arTileMap` | long | Live-tile bitmap; drives claiming and reclamation |
  | `$18` | `arPadding` | long | Retained unusable backing suffix, zero through 32 bytes |

- A new slab is needed when its class has no partial slab. Existing arenas
  are searched for a free tile before creating another arena. The last cell
  free releases its slab eagerly, and an arena is released when its last live
  tile goes; `_HeapCompact` also sweeps empty slabs. `_HeapDestroy` invalidates
  metadata and reclaims the entire containing private heap.
- **Tile allocation & reclamation** are driven by `arTileMap`: `slab_create` claims the first
  clear bit (formatting that tile as a slab); releasing a fully-empty slab clears its bit and
  decrements `arSlabUse`; when it reaches zero, release captures the next/backing
  pointers, unlinks and invalidates the descriptor, and frees backing then
  descriptor. A bare count could neither locate a free tile nor enumerate live tiles.
- Requests are clamped to the bitmap's 32-tile capacity. Four-tile creation still
  retries one tile; final failure frees the unpublished descriptor and preserves
  the out-of-memory diagnostic. If the SCB already existed, descriptor/backing
  rollback restores physical-block accounting; an SCB created during the attempt
  remains allocated. The aligned allocator itself does not mutate chains on failure.

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
    whose body shows `freeTag` **and whose index is on the free list** is reported as
    `HEAP_ERROR_DOUBLE_FREE` (§8; already free).
- Every class is ≥ 8 bytes, so the 4-byte free control always fits.
- Allocation pops `slFreeHd`; free pushes onto `slFreeHd`. Those updates are
  O(1), but a matching tag triggers a membership walk bounded by `slTotal`.
  This avoids treating matching live user data as a double-free. Once an
  empty slab is released, its magic is invalidated and a stale pointer need
  not produce `HEAP_ERROR_DOUBLE_FREE`.

### 6.7 Pointer → Slab Discrimination (the free discriminator)

`_HeapFree(hHeap, pMem)` resolves the allocator kind as follows (see §9.4 for full pseudocode):

1. Perform configured heap validation; after success, `pMem == NULL` is a no-op.
2. **SOA recognition** (is `pMem` a cell at all?): `slab = pMem & ~(SLAB_SIZE−1)`. `pMem` is a
   recognized candidate when all of these checks pass:
   - `slab->slMagic == 'SLAB'`
   - `slab->slArena->arMagic == 'AREN'`
   - `arBlock == arBase`, `1 ≤ arSlabs ≤ ARENA_MAX_SLABS`
   - `arBase ≤ slab < arBase + arSlabs×SLAB_SIZE`
   - the slab's tile bit in `arTileMap` is live
   - `slClass < SOA_NUM_CLASSES` and `slCellSz != 0` before division
   - `pMem ≥ firstCell`
   - `(pMem − firstCell) mod slCellSz == 0`
   - `cellIndex < slTotal`
3. **If recognized as a cell, check ownership *separately*:** if `slab->slId == hHeap->hhId`
   take the **SOA free path**; otherwise return `HEAP_ERROR_HANDLE_BLOCK_MISMATCH` (a valid
   cell owned by another heap — mirrors the block path's `_hfInvalidHeap`). Ownership is **not**
   part of recognition: folding `slId` into step 2 would misreport a cross-heap cell as
   `HEAP_ERROR_INVALID_BLOCK`.
4. **Else — regular path:** validate `pMem − BLK_HDR_SIZE` for alignment,
   block magic, allocated state, and heap-ID ownership.
5. Otherwise → `HEAP_ERROR_INVALID_BLOCK`.

Recognition is tried **first**. A genuine cell pointer always masks to a live slab header
(invariant I1). Because arenas are **not** address-separated from ordinary blocks, safety does
**not** rest on address separation — it rests on the recognition chain: a false positive would
require a forged `'SLAB'` header **and** a consistent `slArena` back-pointer to a forged
`'AREN'` descriptor whose range contains the slab, **and** exact cell modulus / range
agreement. These are consistency checks, not a guarantee against forged or
unmapped addresses. Ownership is a **separate** step, so a
valid cell of another heap is reported as `HEAP_ERROR_HANDLE_BLOCK_MISMATCH` (preserving G4),
not silently rejected as an invalid block.

### 6.8 Heap Header & Flag Changes

- `hhReserved` (`$3C`) → **`hhSmallPool`**: pointer to the SCB, or `0` if no small alloc has
  occurred. Header size unchanged (C4 satisfied). `_HeapCreate`/`_MachineHeapInitialize`
  already zero this field, so existing heaps start with the SOA dormant.
- SOA flag bit in the low word of `hhFlags` (bits 0–10 are defined; 11–15 remain free):
  - **`FLG_HEAP_DISABLE_SMALL_POOL` = 10**, mask `HEAP_DISABLE_SMALL_POOL = 1 shl 10`.
  - When set, `_HeapAlloc` skips the SOA entirely — exact legacy behavior. Used for A/B
    measurement and as a safety valve.
- The SOA is **on by default** (opt-out), so existing builds benefit without code changes.
  `SOA_ROUTE = 1` is current. Phases 1–5 historically used zero while primitives
  were tested; Phase 6 enabled public routing.

---

## 7. API Behavior Changes

| API | Change | Notes |
|-----|--------|-------|
| `_HeapAlloc` | If `1 ≤ lBytes ≤ SOA_MAX`, pool enabled on heap/call, and heap tail checking off → attempt `__HeapSoaAlloc`. | Zero/debug-fill honoured (§10); regular fallback on SOA failure. Zero-byte requests are regular allocations. |
| `_HeapFree` | Discriminate cell vs. block (§6.7); route to `soa_free` or existing path. | NULL still succeeds. Cross-heap still detected. |
| `_HeapReAlloc` | Cell origin: same-class keep, cross-class cell move, or zero/large replacement. Regular origin: existing regular grow/shrink path, even below 256 bytes. | In-place-only allows any successful regular in-place resize and same-class cell reuse; it rejects a required move. Same-class cells do not initialize a changed request subrange (§9.6). |
| `_HeapSize` | For a cell, return the **class (usable) size**, not the original request. | Documented semantic (like `malloc_usable_size`). Callers relying on exact request for small allocs must not; API already returns "requested" only for blocks. See §16 Q3. |
| `_HeapValidate` | Whole-heap checks include SOA arena/slab/free-list checks. A non-NULL `pBlock` remains regular-only. | Public validators return status in CCR.Z and preserve D0; the internal SOA validator returns an error code in D0. §10. |
| `_HeapValidateHandle` | Also sanity-check `hhSmallPool` (if non-NULL, `scbMagic == 'SCB '`). | Cheap. |
| `_HeapWalk` | Unchanged regular-block walk: includes SCB, separate descriptors, backing blocks, and free blocks. | It does not enumerate cells. `__HeapSoaWalk` is the implemented internal companion. |
| `_HeapCompact` | Additionally release fully-empty slabs and fully-empty arenas back to the block allocator. | Improves post-burst footprint. |
| `_HeapDestroy` | Invalidates the private heap's slab/arena magics, clears its header, and frees the containing machine-heap allocation. | SCB/descriptors/backing inside that private heap are reclaimed with it; no per-allocation destructor is called. |
| `_GetMachineHeaps` | Still scans regular machine-heap allocations for data starting with `'HEAP'`. | Not a registry: matching user data can be a false positive, and tiny SOA-backed private heaps are missed. |

---

## 8. Data Structures & New Constants

Defined in [heap.inc](../src/heap.inc):

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
SCB_HDR_SIZE       equ  $A0           ; 160 bytes
AREN_HDR_SIZE      equ  $1C           ; 28-byte separate descriptor, including arPadding
SOA_WALK_CURSOR_SIZE equ $0C          ; swArena, swTile, swCell
SOA_ROUTE          equ  1             ; public SOA routing enabled

; --- New error codes (append; do not renumber existing) ---
HEAP_ERROR_SLAB_CORRUPT       equ  $15   ; Slab header/free-list inconsistent
HEAP_ERROR_DOUBLE_FREE        equ  $16   ; Tagged cell found on its slab free list
HEAP_ERROR_SOA_ARENA_CORRUPT  equ  $17   ; Arena descriptor inconsistent
```

The class table is emitted once (data, not in the shared include) in
[HeapData.a68](../src/HeapData.a68) as a public symbol so every consumer shares one copy;
[heap.inc](../src/heap.inc) carries only the scalar tunables (`SOA_MAX`, `SOA_NUM_CLASSES`, …):

```asm
	public 	__HeapSoaClassTbl
__HeapSoaClassTbl:  dc.w  8,16,24,32,40,48,56,64,80,96,112,128,160,192,224,256
```

SOA implementation modules (several contain multiple helpers):

| File | Contents |
|------|----------|
| `HeapSmallAlloc.a68`  | `__HeapSoaAlloc`, cell pop, fill, and live-cell counters |
| `HeapSmallFree.a68`   | `__HeapSoaFree`, cell push, slab full↔partial↔empty |
| `HeapSlab.a68`        | `__HeapSlabCreate`, `__HeapSlabFromPtr`, `__HeapSlabRelease` |
| `HeapArena.a68`       | `__HeapArenaCreate`, `__HeapArenaRelease` |
| `HeapSmallCtl.a68`    | `__HeapScbGetOrCreate`, class list helpers, `__HeapSoaSizeToClass` |
| `HeapSmallReAlloc.a68` | `__HeapSoaReAlloc` |
| `HeapSmallValidate.a68` | `__HeapSoaValidate` |
| `HeapSmallCompact.a68` | `__HeapSoaCompact` |
| `HeapSmallWalk.a68` | `__HeapSoaWalk` |

`HeapAlloc.a68` also supplies the internal `__HeapAllocAligned` backing
allocator. `HeapStats.a68` supplies regular-block accounting, not cell-request
statistics.

Each is added to the Windows `HEAP_ELF_OBJS` and macOS `HEAP_OBJS` lists in the
ELF makefiles, with the same `src/heap.inc` dependency line as existing objects.

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
    scb = scb_get_or_create(hHeap)
    if scb == 0: return 0
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
    fill_or_zero(cell, slab->slCellSz, flags)      ; whole class size, §10
    stats: scbLiveCells++, scbLiveCellBytes += slab->slCellSz
    return cell
```

### 9.4 free discrimination + soa_free

```
heap_free(hHeap, pMem):
    if automatic_heap_validation_fails: return FALSE
    if pMem == 0: return TRUE
    slab = pMem & ~SLAB_SIZE_MASK
    ; --- recognition: is pMem a slab cell? (load-bearing chain, S2/§6.7) ---
    if slab->slMagic == 'SLAB'
       and slab->slArena->arMagic == 'AREN'
       and slab->slArena->arBlock == slab->slArena->arBase
       and 1 <= slab->slArena->arSlabs <= 32
       and slab->slArena->arBase <= slab < slab->slArena->arBase + slab->slArena->arSlabs*SLAB_SIZE
       and the corresponding arTileMap bit is live
       and slab->slClass < SOA_NUM_CLASSES and slab->slCellSz != 0
       and pMem >= firstCell(slab)
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
    cellBytes = slab->slCellSz                    ; capture before a possible release
    i = (cell - firstCell(slab)) / slab->slCellSz
    if freeTag(cell) == SOA_FREE_TAG and on_free_list(slab, i): return DOUBLE_FREE
    if debug_fill: fill(cell, BAADFOOD)          ; then write control word (§10)
    nextIndex(cell) = slab->slFreeHd; freeTag(cell)=SOA_FREE_TAG
    slab->slFreeHd  = i; slab->slFree += 1
    was_full = (slab->slFree == 1)
    if was_full: move slab Full->Partial
    if slab->slFree == slab->slTotal: slab_maybe_release(hHeap, slab)   ; empty
    stats: scbLiveCells--, scbLiveCellBytes -= cellBytes
    return TRUE
```

### 9.5 slab_create / arena_create (sketch)

```
slab_create(hHeap, cls):
    ar = arena in scb->scbArenaHead whose arTileMap has a clear bit
    if none: ar = arena_create(hHeap)            ; separate descriptor + aligned backing; adaptive
        if ar == 0: return 0
    t    = index of first clear bit in ar->arTileMap
    tile = ar->arBase + t*SLAB_SIZE
    set bit t in ar->arTileMap; ar->arSlabUse++
    format slab header: magic,'SLAB'; slId=hHeap->hhId; slClass=cls;
        slCellSz=__HeapSoaClassTbl[cls]; slTotal=(SLAB_SIZE-SLAB_HDR_SIZE)/slCellSz;
        build free list 0..slTotal-1; slFreeHd=0; slFree=slTotal; slArena=ar
    return tile

arena_create(hHeap, requestedTiles):
    scb = scb_get_or_create(hHeap)
    if scb == 0: return 0
    tiles = clamp(requestedTiles, 1, ARENA_MAX_SLABS)
    descriptor = heap_alloc(hHeap, HEAP_DISABLE_SMALL_POOL, AREN_HDR_SIZE)
    if descriptor == 0: return 0
    backing = aligned_regular_alloc(tiles*SLAB_SIZE, SLAB_SIZE, &padding)
    if backing == 0 and tiles != 1:
        tiles = 1
        backing = aligned_regular_alloc(SLAB_SIZE, SLAB_SIZE, &padding)
    if backing == 0:
        free descriptor; set OUT_OF_MEMORY; return 0
    format descriptor: arBlock=arBase=backing; arPadding=padding
    link descriptor into scbArenaHead; scbArenaCount++
    return descriptor

slab_maybe_release(hHeap, slab):                 ; when a slab becomes fully empty (§9.4)
    ar = slab->slArena
    unlink slab from its class partial list
    slab->slMagic = 0
    t  = (slab - ar->arBase) / SLAB_SIZE
    clear bit t in ar->arTileMap; ar->arSlabUse--
    scbSlabCount--
    if ar->arSlabUse == 0: arena_release(hHeap, ar)   ; backing + descriptor back to parent
```

### 9.6 realloc transitions

```
heap_realloc(hHeap, flags, pMem, n):
    perform automatic heap validation
    if pMem == 0: return INVALID_BLOCK
    kind, cur = classify_and_check_ownership(pMem)
    if kind == SOA:
        if 1 <= n <= SOA_MAX and class(n) == cur.class: return pMem
        if IN_PLACE_ONLY on heap or call: return OUT_OF_MEMORY
        if 1 <= n <= SOA_MAX:
            q = soa_alloc(hHeap, flags, n)       ; no regular fallback here
        else:
            q = heap_alloc(hHeap, flags, n)      ; zero or large -> regular
        if q == 0: return 0                     ; original remains live
        copy min(n, cur.classSize) bytes to q
        soa_free(pMem)
        return q
    else:
        run regular in-place grow/shrink logic, even for n <= SOA_MAX
        if a move is required:
            if IN_PLACE_ONLY on heap or call: return OUT_OF_MEMORY
            q = heap_alloc(hHeap, flags, n)     ; replacement uses public routing
            if q == 0: return 0
            copy old requested bytes; free old regular block; return q
```

> **Same-class grow does not honor `HEAP_ZERO_MEMORY` / debug-fill (accepted divergence).**
> The block path zeroes/`CD`-fills the newly exposed region using the per-block stored request
> size. The SOA stores **no per-cell request size** (§16 Q3), so a small realloc that grows
> *within one class* (e.g. 17 → 24) cannot tell which bytes are "new" and leaves them as-is.
> This is an explicit, documented divergence from the block path; callers needing zeroed
> growth on a small allocation should allocate at the final size up front (review S3).

On a moving cell grow, the preserved range is the old **class** size, not
the unrecorded original request. Initialization therefore applies beyond the
old class, not necessarily every byte beyond the old request.
Regular-to-small shrink stays regular. Zero-size realloc is a minimal live
regular allocation on success, not free. The current regular debug-shrink
partial-longword limitation is documented in [HEAP_API.md §5.6](HEAP_API.md#56-_heaprealloc).

---

## 10. Debug, Fill & Validation Semantics

- **Zero / debug fill on alloc:** honored per cell exactly as [`__FillBlock`](../src/HeapAlloc.a68)
  does for blocks — `HEAP_ENABLE_DEBUG_FILL` → `$CDCDCDCD` over the class size;
  else `HEAP_ZERO_MEMORY` (per-call or per-heap) → zero. Fill spans the whole **cell** (class
  size), which is ≥ request, when a fill option is enabled. With neither
  option, cell contents are unspecified, including old free-list control bytes.
- **Debug fill on free:** fill the cell with `$BAADF00D`, **then** overwrite the first 4 bytes
  with the free-list control word (`nextIndex`,`freeTag`). Ordering matters: the control word
  must survive the fill.
- **Tail checking:** `HEAP_TAIL_CHECKING_ENABLED` adds a 32-byte guard, which would obliterate
  small-cell density. **Rule:** when tail-check is enabled for a heap, small requests are
  served by the **block path** (not the SOA), preserving overrun detection. Documented in
  [HEAP_API.md](HEAP_API.md) §3/§5.4. This is a deliberate exception to G6.
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
  5. Walk each class's partial/full **forward** list: slab magic/class match,
     partial slabs have `0 < slFree ≤ slTotal`, full slabs have `slFree == 0`,
     and each walk is bounded by `scbSlabCount`.

The current validator does not prove one-to-one live-tile/class-list
membership, validate all reverse links, or recompute all SCB running counters.
Whole-heap `_HeapValidate` invokes it; single-block validation does not accept
cells. Both public validators preserve D0 and return status in CCR.Z.

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

### 12.1 Measurement helpers
The implemented internal [`__HeapStats`](../src/HeapStats.a68) reports regular
physical-block accounting and a request-size histogram in `HEAP_STATS`.
It counts the SOA's internal allocations, not caller cell requests.
`scbLiveCells` / `scbLiveCellBytes` separately track live cell count / usable
class bytes; exact requested bytes require workload-side bookkeeping.

[HeapTest.a68](../test/HeapTest.a68) retains its scripted mix and snapshot but
requires a CP/M base page. The headless
[aligned suite](../test/test_aligned.a68) uses `__HeapStats` to check allocation
and failure rollback. Neither is a measured universal SOA density benchmark.

### 12.2 Correctness tests
- **Unit:** `soa_size_to_class` vs. `__HeapSoaClassTbl` for all `n` in `1..256`;
  detailed slab checks for 8/16/256-byte classes plus an allocation sweep over
  all 16 classes; `__HeapSlabFromPtr` for the first,
  middle, last cell of a slab and for **near-miss** pointers (interior, off-by-one, foreign).
- **Round-trip:** alloc→write pattern→free→re-alloc; verify no aliasing across cells; verify
  a repeat free with a same-slab anchor reports `HEAP_ERROR_DOUBLE_FREE`.
- **Ownership:** regular-block cross-heap API checks and the SOA slab-ID
  ownership proxy; see the [coverage gaps](HEAP_TEST_SUITE_DESIGN.md#911-known-coverage-gaps)
  for missing focused public cell-path regressions.
- **Realloc:** same-class reuse, cross-class and cell-to-large moves,
  in-place-only rejection/reuse, regular shrink/grow, and selected zero-fill
  checks; the suite is not every transition × flag combination.
- **Fill/validate:** debug-fill patterns present; `_HeapValidate` passes on healthy heaps and
  **fails** on deliberately corrupted slab headers/free lists/counts.
- **Regular path:** per-heap opt-out preserves regular size/alignment semantics;
  internal control allocations exercise the per-call disable flag.

### 12.3 Stress / soak
[`test_stress.a68`](../test/test_stress.a68) runs 3,000 fixed-seed xorshift-32
iterations across 64 slots, machine/SOA and private/regular heaps, with sizes
1..4096 and validation every 256 iterations. Drain checks verify zero live
cells/slabs/arenas while the SCB remains. A 12 KB heap verifies the four-to-one
arena retry. Its goldens are **live requested bytes/count**, not committed
memory or an SOA-versus-regular comparison.

### 12.4 Build/CI
ELF is the only supported object format; the COFF build has been retired.
The Windows `makefile` and macOS `makefile.macos` carry the same library objects.
`nmake test` builds and runs the automated ELF suite using the bundled Windows tools.
The macOS makefile has no `tests`/`test` targets; its toolchain is external and
native macOS build/run validation remains outstanding.
**Rebuild everything** when touching `src/heap.inc` (a shared header change invalidates
all objects).

### 12.5 Observability — sid68k `!heap -p`
The historical sid68k integration provided `!heap -p` pool views. sid68k is
external, is not bundled or built here, and is not part of this repository's
validated test workflow. An external extension must understand the current
separate NM1 descriptors, `arBlock` data-pointer meaning, and `arPadding`;
an older descriptor/block-aliasing implementation is not compatible.

**Counters vs. walked totals.** `__HeapSlabCreate` increments `scbSlabCount`
without linking the slab; `__HeapSoaAlloc` / `__HeapSoaFree` update live-cell
count and class bytes and maintain the class lists. Primitive tests can create
unlinked slabs, so running slab counters can legitimately exceed class-list
walk totals. On normal public workloads a discrepancy warrants investigation;
it must not automatically be dismissed as either harmless or a proven leak.
The current automated runner uses GDB and integrity reports (§12.4).

---

## 13. Backward Compatibility & Migration

- **Binary/handle layout:** unchanged. Heap header stays `$40`; only the semantic of the
  reserved slot changes, and it is already zero-initialized on every existing heap.
- **API/ABI:** no prototype changes; no new required parameters. `heap.inc` only **adds**
  symbols and appends error codes (existing codes keep their values).
- **Behavioral:** disabling the SOA restores regular-path size and alignment
  semantics. When the SOA is **on** there are deliberate changes for small
  allocations: (a) `_HeapSize` returns class (usable) size (§7, §16 Q3); and (b) pointers are
  only **≥ 8-byte** aligned, not 32-byte aligned (C8). Change (b) breaks any caller that
  **tags the low 5 bits** of a heap pointer; consumer audits must cover
  pointer-alignment assumptions, not just `_HeapSize` callers.
  Same-class realloc does not initialize a changed request subrange (§9.6).
- **Rollout:** Phases 1–5 used `SOA_ROUTE=0`; Phase 6 enabled routing. The
  current default is 1, with per-heap/per-allocation opt-out.

---

## 14. Risks & Mitigations

| # | Risk | Impact | Mitigation |
|---|------|--------|-----------|
| R1 | Free misclassifies a block as a cell (or vice-versa) | Corruption / crash | Load-bearing discriminator chain (slab magic → `slArena`→`'AREN'` back-pointer + arena-range containment → cell modulus/range → heap-ID) — **not** address separation (arenas share the parent heap); extensive near-miss tests (§12.2). |
| R2 | Alignment placement and low arena occupancy increase commitment/fragmentation | Reduced net win | NM1 uses exact aligned backing plus a separate descriptor; legal prefix/suffix blocks remain reusable and only a ≤32-byte suffix is retained. Alignment can still make a particular free block unsuitable. |
| R3 | Double-free of a cell silently reused | Data corruption | `freeTag` guard + free-list membership check on free; `_HeapValidate` free-list walk. |
| R4 | `_HeapSize` semantic change breaks a caller | Latent bug | Document loudly; provide `HEAP_DISABLE_SMALL_POOL`; audit in-tree callers. |
| R5 | Register-clobber / duplicate-label asm bugs | Heisenbugs | §11 guidelines; unique labels; strict `USES`; unit-test helpers in isolation. |
| R6 | Tail-check users lose overrun detection on small allocs | Reduced debug coverage | By design small+tail-check routes to the block path (§10); documented. |
| R7 | SCB/arena allocation fails under pressure | Small alloc fails | `soa_alloc` returns 0 → `_HeapAlloc` falls back to the block path transparently. |
| R8 | Fragmentation: many half-empty slabs pin arenas | Footprint regression | Partial lists favour existing slabs; free/compact release empties but cannot relocate live cells. Slab caps and empty-slab caching are not implemented. |
| R9 | First small alloc needs a whole arena; a fixed 64 KB arena fails on small private heaps (< ~68 KB) → silent fallback to the block path, no density win | Missed G1 on small heaps | Adaptive/small default arena size — single-slab arenas allowed (§6.4); tuning knob (§16 Q7); `soa_alloc` still falls back safely (R7). |
| R10 | Default-on changes small-alloc **alignment** (cells ≥ 8-byte vs blocks 32-byte); callers tagging the low 5 bits of a heap pointer break | Latent bug / corruption | Broaden the Phase 6 audit and §13 migration notes to pointer-alignment assumptions (not just `_HeapSize`); `HEAP_DISABLE_SMALL_POOL` restores 32-byte-aligned blocks. |

---

## 15. Phased Implementation Plan & Progress Tracker

This is the historical implementation record, not a list of unfinished
features or current manual debugger addresses. Current behaviour is in
§6–§10; Windows build/run commands are in the [test guide](HEAP_TEST_SUITE_DESIGN.md#104-running-the-suite-quick-start).
The original density targets were overclaimed; see the corrected analysis in §2.2.

**Status legend:** ⬜ Not started · 🟨 In progress · ✅ Done · ⛔ Blocked

| Phase | Title | Status | Exit criteria |
|------:|-------|:------:|---------------|
| A | Analysis & this spec | ✅ | Spec reviewed & accepted |
| 0 | Measurement baseline & constants | ✅ | Constants/flag/errors + `HEAP_STATS` layout in `heap.inc`, `__HeapStats` implementation; ELF builds green & `heaptest.elf` links; macOS not host-buildable |
| 1 | SOA data structures & primitives | ✅ | SCB/arena/slab create + `__HeapSlabFromPtr` unit-tested (`heapsmalltest.elf` passes under sim68k); no API routing yet |
| 2 | Allocation path | ✅ | `_HeapAlloc` routes small (gated `SOA_ROUTE`, off in P2-5); fill/zero correct; falls back on failure; `heapsmalltest.elf` Phase 6 passes |
| 3 | Free path | ✅ | `_HeapFree` discriminates & frees cells; double-free & cross-heap detected; `heapsmalltest.elf` Phase 7 passes |
| 4 | ReAlloc & Size | ✅ | All four realloc transitions pass; `_HeapSize` returns class size for cells; `heapsmalltest.elf` Phase 8 passes |
| 5 | Validation, Walk, Compact | ✅ | `_HeapValidate` covers SOA; `__HeapSoaWalk` enumerates cells; `_HeapCompact` releases empties; `heapsmalltest.elf` Phase 9 passes |
| 6 | Default-on, docs, tooling, tuning | ✅ | Opt-out default and API docs; historical external sid68k integration. Density estimates are illustrative, not universal measured guarantees. |

### Phase 0 — Measurement baseline & constants  ✅ (ELF; macOS deferred)
- [x] Add SOA constants, magics, `FLG_HEAP_DISABLE_SMALL_POOL`, `__HeapSoaClassTbl`, and appended
      error codes to [heap.inc](../src/heap.inc) (values only; no behavior). Class table emitted in
      [HeapData.a68](../src/HeapData.a68) as `__HeapSoaClassTbl` (data, not the shared include).
- [x] `hhReserved` → `hhSmallPool` alias at the same offset `$3C`; create/init already zero it.
- [x] Implement [`__HeapStats`](../src/HeapStats.a68): block-chain walk → committed vs. requested bytes,
      free/overhead totals, largest free block, and a request-size histogram (`HEAP_STATS`).
- [x] Extend [HeapTest.a68](../test/HeapTest.a68) with a scripted small-allocation mix + `__HeapStats` snapshot.
- [x] `makefile` builds clean; `out/lib/libheap.a` + `out/bin/heaptest.elf` produced (nmake).
- [~] `makefile.macos`: corrected `-Cu` → `-Cx`; not buildable on the Windows host (macOS toolchain).

> Historical note: the retired COFF backend assembled its objects, but
> `m68k-coff-ar.exe` (GNU ar 2.16.1) crashed (`0xC0000005`) on the multi-object
> list, including without the new object. COFF support is no longer pending work.

### Phase 1 — SOA data structures & primitives  ✅ (2026-07-21)
- [x] Create `HeapSmallCtl.a68`: `__HeapScbGetOrCreate`, class list head helpers (`__HeapClassListPush`/`__HeapClassListUnlink`).
- [x] Create `HeapArena.a68`: adaptive arena creation/release. The original
      over-allocation backing was superseded by NM1's separate descriptor and
      checked aligned allocation (§6.4).
- [x] Create `HeapSlab.a68`: `__HeapSlabCreate`, `__HeapSlabFromPtr`, `__HeapSlabRelease`.
- [x] Implement `__HeapSoaSizeToClass` (table reference + shift optimization, cross-checked against `__HeapSoaClassTbl`).
- [x] Unit-test primitives via `HeapSmallTest.a68` (no public-API routing): size→class (n=1..256), SCB create,
      arena create, slab create + free-list walk, and `__HeapSlabFromPtr` recognition (valid / mid-cell / out-of-range /
      foreign) passed (`tResult=0`). Historical sid68k addresses are not stable
      run instructions. Current standalone check: build with `nmake`, then
      `pwsh -File test\run-heap-tests.ps1 -NoBuild -Modules heapsmalltest`.
- [x] Add new objects to both ELF makefiles (Windows ELF green; macOS carries the same Phase 0 caveat).

### Phase 2 — Allocation path  ✅ (2026-07-21)
- [x] Create [`HeapSmallAlloc.a68`](../src/HeapSmallAlloc.a68): `__HeapSoaAlloc` (§9.3) — get/create SCB, pick a
      partial slab (create + link one on demand), pop a cell, move the slab Partial→Full when it fills.
- [x] Route `_HeapAlloc` small requests to the SOA, gated on SOA-enabled and tail-check-not-set. The gate
      is the assembly switch `SOA_ROUTE` in [heap.inc](../src/heap.inc): **0** in Phases 1–5 (the routing block is
      conditionally assembled out so `_HeapFree`/`_HeapSize`/`_HeapValidate` stay legacy and the existing
      `heaptest.elf` is byte-for-byte unchanged); flipped to **1** in Phase 6. Verified the routing block
      assembles clean at `SOA_ROUTE=1`.
- [x] Honor `HEAP_ZERO_MEMORY` (per-call or per-heap) / `HEAP_ENABLE_DEBUG_FILL` per cell, filling the
      **whole cell** (class size, §10) so no uninitialized bytes are exposed.
- [x] Fall back to the block path when `__HeapSoaAlloc` returns 0 (slab/arena creation failed).
- [x] Tests: `HeapSmallTest.a68` Phase 6 — basic alloc + `__HeapSlabFromPtr` recognition + class, adjacent
      cells + live-cell stats, whole-cell zero-fill (free-list control word preserved), fill-to-full →
      Partial→Full + new slab, and a 16-class sweep. All pass (`tResult=0`) under sim68k.
- [x] Add `HeapSmallAlloc.o` to both ELF makefiles (also back-filled the Phase 1
      SOA objects into `makefile.macos` for consistency).

### Phase 3 — Free path  ✅ (2026-07-21)
- [x] Create [`HeapSmallFree.a68`](../src/HeapSmallFree.a68): `__HeapSoaFree` (§9.4) — compute cell index, push
      the cell back on the slab free list, and drive the full→partial (unlink `scbFull`→push `scbPartial`)
      and partial→empty (unlink `scbPartial` + `__HeapSlabRelease`) transitions.
- [x] Add the discriminator to `_HeapFree` (gated `SOA_ROUTE`): probe `__HeapSlabFromPtr` first — a hit
      takes the SOA free path (after the `slId`↔`hhId` ownership check), otherwise fall through to the
      legacy block free path. Verified the gated block assembles clean at `SOA_ROUTE=1`.
- [x] Double-free (`freeTag` + bounded free-list membership walk → `HEAP_ERROR_DOUBLE_FREE`) and
      cross-heap (`slId` vs `hhId`) detection.
- [x] Debug-fill-on-free ordering: fill the **whole cell** with `BAADF00D` **then** write the control
      word (`nextIdx`/`freeTag`), so the free-list linkage survives the poison fill (§10).
- [x] Decrement `scbLiveCells` and subtract the captured class size from
      `scbLiveCellBytes` on free; exact per-cell request size is not stored.
- [x] Tests: `HeapSmallTest.a68` Phase 7 — round-trip alloc/free/re-alloc-reuse, double-free rejection,
      debug-fill-on-free (control word survives, body poisoned; anchor cell keeps the slab alive so the
      free does not release+refill the arena), full→partial + empty-slab release on a private heap, and a
      cross-heap `slId` ownership proxy. All pass (`tResult=0`) under sim68k.

### Phase 4 — ReAlloc & Size  ✅ (2026-07-21)
- [x] `_HeapSize`: gated cell path — recognize the cell via `__HeapSlabFromPtr`, verify
      ownership (`slId`↔`hhId`, else `HANDLE_BLOCK_MISMATCH`), and return `slCellSz` (the
      class/usable size, §16 Q3).  Falls through to the block path otherwise.
- [x] Create [`HeapSmallReAlloc.a68`](../src/HeapSmallReAlloc.a68): `__HeapSoaReAlloc` implements the
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
- [x] Create [`HeapSmallValidate.a68`](../src/HeapSmallValidate.a68): `__HeapSoaValidate` performs the full
      §10 sweep — SCB magic/back-pointer; per-arena magic, `arBase` alignment, `arSlabUse ≤ arSlabs`,
      `popcount(arTileMap) == arSlabUse`; both descriptor and `arBlock - BLK_HDR_SIZE`
      carry live owned `'BLKH'` headers; exact tile request and padding accounting;
      per live-tile slab magic/`slId`/
      class/`slCellSz`/`slTotal`/`slFree` bounds; free-list length == `slFree` with in-range indices,
      `freeTag` present and a cycle bound; and class-list consistency (partial ⇒ `slFree>0`, full ⇒
      `slFree==0`).  Wired into `_HeapValidate` (gated) for a whole-heap check only (`pBlock==NULL`).
- [x] `_HeapValidateHandle`: gated SCB sanity check — if `hhSmallPool != 0` it must carry `'SCB '`.
- [x] Create [`HeapSmallWalk.a68`](../src/HeapSmallWalk.a68): `__HeapSoaWalk(hHeap, pCursor)` enumerates live
      cells one per call via a 3-longword cursor `{swArena, swTile, swCell}` (a cell is reported when
      it is not on its slab's free list).  This is the design's companion option; `_HeapWalk`'s coarse
      mode already reports arena/SCB blocks since those are ordinary parent-heap blocks.
- [x] Create [`HeapSmallCompact.a68`](../src/HeapSmallCompact.a68): `__HeapSoaCompact` releases every fully
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
      [heap.inc](../src/heap.inc). Fixed the SCB-alloc recursion this exposed — `SCB_HDR_SIZE`=$A0 ≤
      `SOA_MAX`, so `__HeapScbGetOrCreate`'s own `_HeapAlloc(160)` would re-enter the SOA. Broke it
      by (a) allocating the SCB with `HEAP_DISABLE_SMALL_POOL` as `lFlags` in
      [HeapSmallCtl.a68](../src/HeapSmallCtl.a68), and (b) honoring the per-**call** disable flag in the
      [HeapAlloc.a68](../src/HeapAlloc.a68) gate. `heapsmalltest.elf` passes all 9 phases at `SOA_ROUTE=1`
      (`tResult=0`). (`heaptest.elf` is a CP/M base-page harness and
      cannot run under a bare simulator launch — its base-page access fails before a heap call,
      identically at `SOA_ROUTE=0`; not a regression. `heapsmalltest` is the authoritative test.)
- [x] The original rollout recorded a caller audit of sibling projects for
      `_HeapSize` and pointer-tagging assumptions. That historical result is
      not a guarantee about current external consumers; this repository's
      tests now explicitly exercise `_HeapSize`. Integrators must audit their
      own alignment/size assumptions or use the opt-out flag.
- [x] Updated [HEAP_API.md](HEAP_API.md): `HEAP_DISABLE_SMALL_POOL` flag (bit 10, per-heap and
      per-call), error codes `$15`-`$17`, `hhReserved`→`hhSmallPool`, `_HeapAlloc` SOA routing note,
      `_HeapSize` class-size semantics, new §2.7 *Small Object Allocator (SOA)* section, TOC entry, and
      moved the implemented "per-allocation size classes" item out of §10 Future Enhancements.
- [x] The original rollout recorded an external sid68k `!heap -p` integration.
      That external build is not reproduced here and is not a current
      compatibility guarantee for NM1's later descriptor layout (§12.5).
- [x] Tuning: kept `SOA_MAX=256`, `SLAB_SIZE=4096`, `ARENA_SLABS_DFLT=4`, and the 16-class table.
      Rationale — 4096-byte slabs bound alignment slack while giving 500+ cells/slab at the small end
      (slab-header share < 0.1 B at the 8-byte class). Tier spacings bound
      rounding in bytes, not a universal <25% percentage. Constants remain
      unchanged; tuning needs measured workloads (Q1/Q2/Q6).
- [x] Structural density analysis: 8/16/32/64-byte cells replace
      64/64/64/96-byte regular blocks before shared costs, yielding approximate
      8×/4×/2×/1.5× ratios. The original ≥4× for all ≤32-byte and ≥2× for
      nearly all ≤256-byte claims were not supported. Whole-workload commitment
      depends on metadata, occupancy, and release behaviour; no universal
      runtime density benchmark is implemented (§12.1).

---

## 16. Open Questions & Tuning Parameters

These record the chosen implementation and remaining tuning opportunities,
not pending Phase 1 prerequisites.

- **Q1 `SLAB_SIZE`.** 4096 balances cells-per-slab against alignment slack. Smaller slabs
  raise per-cell metadata share and slab churn. The current value is 4096.
- **Q2 `SOA_MAX` / class table.** Current maximum 256, with 16 classes and
  byte-rounding bounds in §6.2. Workload measurements may justify other
  boundaries or classes (for example 12 or 20 bytes).
- **Q3 Per-cell request size & `_HeapSize` semantics.** **Decision (lock before Phase 1): the
  per-cell request size is *not* stored** (storing it costs per-cell bytes, defeating density).
  Two accepted consequences: `_HeapSize` returns **class (usable) size**, and same-class
  realloc-grow cannot honor `ZERO_MEMORY`/debug-fill (S3/§9.6). Revisit only if a real caller
  needs the exact request size for small allocations.
- **Q4 Arena alignment.** Resolved by NM1: `__HeapAllocAligned` is implemented
  and used with separate descriptors, reusable legal fragments, and ≤32
  retained suffix bytes (§6.4).
- **Q5 Double-free strength.** `freeTag` + free-list membership (chosen) vs. a per-slab
  in-use bitmap (stronger, costs slab-header space). Add a bitmap only if soak testing shows
  the tag insufficient.
- **Q6 Per-class slab cap / empty-slab retention.** Current policy releases
  empty slabs eagerly; there is no slab cap or empty-slab cache. The SCB is
  retained. Caching is a possible future measured trade-off.
- **Q7 Arena sizing policy (lock before Phase 1).** Fixed 64 KB vs. adaptive/small (single-slab
  arenas allowed). **Chosen: four tiles, retry one on failure.** This improves
  availability on small heaps but cannot guarantee a density win when only
  a few cells are live.
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
| 2026-07-21 | Phase 6 | **Default-on:** `SOA_ROUTE=1` with SCB recursion fixed by per-call opt-out. Updated API docs and recorded an external caller/debugger audit. Constants retained; `heapsmalltest.elf` passed its nine phases. Original universal density claims were estimates and are corrected in §2.2 and the 2026-11-09 audit. |
| 2026-07-21 | Review fixes | Code-review F1–F3: **F1** — `scbLiveReqBytes` (add-on-alloc only, monotonic) reworked into a symmetric **live** gauge and **renamed `scbLiveCellBytes`** — alloc adds `slCellSz`, free subtracts it (captured before any slab/arena release); `-p` label → "Live cell bytes". Validated: 39 live cells → 5880 = Σ(class size × live cells). **F2** — `__HeapSlabFromPtr` now rejects `slClass ≥ SOA_NUM_CLASSES` or `slCellSz == 0` **before** the `divu`, closing a ÷0-trap path in the "reject arbitrary pointers" gate. **F3** — `__HeapSlabCreate` first-clear-bit tile scan is now **bounded by `arSlabs`** (no bit-index wrap on a map/count desync). No regression (`heapsmalltest.elf` 9 phases pass). |
| 2026-10-05 | NM1 | Separate 28-byte arena descriptors, checked aligned regular backing, retained-padding accounting, and aligned regression module. |
| 2026-11-09 | Source audit | Synchronized actual realloc/routing, CCR returns, structures/counters, arena fallback and rollback, retained SCB, validation limits, test coverage, Windows/macOS status, and density/complexity claims; kept earlier design/review events explicitly historical. |
