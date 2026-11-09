# Heap API Reference

**Source audit:** 2026-11-09. This reference describes the current implementation,
including its limitations; the SOA design documents retain a separate phase history.

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture and Internal Structures](#2-architecture-and-internal-structures)
   - 2.1 [Memory Model](#21-memory-model)
   - 2.2 [Heap Header](#22-heap-header)
   - 2.3 [Block Header](#23-block-header)
   - 2.4 [End-of-Heap Marker](#24-end-of-heap-marker)
   - 2.5 [Segregated Free Lists](#25-segregated-free-lists)
   - 2.6 [Global Data](#26-global-data)
   - 2.7 [Small Object Allocator (SOA)](#27-small-object-allocator-soa)
3. [Heap Flags](#3-heap-flags)
4. [Error Codes](#4-error-codes)
5. [Public API](#5-public-api)
   - 5.1 [_MachineHeapInitialize](#51-_machineheapinitialize)
   - 5.2 [_HeapCreate](#52-_heapcreate)
   - 5.3 [_HeapDestroy](#53-_heapdestroy)
   - 5.4 [_HeapAlloc](#54-_heapalloc)
   - 5.5 [_HeapFree](#55-_heapfree)
   - 5.6 [_HeapReAlloc](#56-_heaprealloc)
   - 5.7 [_HeapSize](#57-_heapsize)
   - 5.8 [_HeapCompact](#58-_heapcompact)
   - 5.9 [_HeapValidate](#59-_heapvalidate)
   - 5.10 [_HeapValidateHandle](#510-_heapvalidatehandle)
   - 5.11 [_HeapWalk](#511-_heapwalk)
   - 5.12 [_GetMachineHeap](#512-_getmachineheap)
   - 5.13 [_GetMachineHeaps](#513-_getmachineheaps)
   - 5.14 [_HeapGetError](#514-_heapgeterror)
6. [Internal Functions](#6-internal-functions)
   - 6.1 [__HeapAutoValidateFlagCheck](#61-__heapautovalidateflagcheck)
   - 6.2 [__HeapCoalesce](#62-__heapcoalesce)
   - 6.3 [__HeapUnlinkFromBlockChain](#63-__heapunlinkfromblockchain)
   - 6.4 [__HeapUnlinkFromFreeBlockChain](#64-__heapunlinkfromfreeblockchain)
   - 6.5 [__HeapGetBucketOffset](#65-__heapgetbucketoffset)
   - 6.6 [__HeapDebugFillOnFree](#66-__heapdebugfillonfree)
   - 6.7 [__HeapInvalidateBlockHeader](#67-__heapinvalidateblockheader)
   - 6.8 [__HeapStats](#68-__heapstats)
   - 6.9 [SOA Helpers](#69-soa-helpers)
7. [Usage Guide](#7-usage-guide)
   - 7.1 [Initialization Sequence](#71-initialization-sequence)
   - 7.2 [Private Heaps](#72-private-heaps)
   - 7.3 [Allocating and Freeing Memory](#73-allocating-and-freeing-memory)
   - 7.4 [Heap Enumeration](#74-heap-enumeration)
   - 7.5 [Debugging with Heap Flags](#75-debugging-with-heap-flags)
   - 7.6 [Using INVOKE with the Heap API](#76-using-invoke-with-the-heap-api)
8. [Design Notes](#8-design-notes)
9. [Limitations and Known Issues](#9-limitations-and-known-issues)
10. [Possible Future Enhancements](#10-possible-future-enhancements)

---

## 1. Overview

The Heap API is a dynamic memory management library for the Motorola 68000 family processor, written in 68000 assembly language. It provides a `malloc`/`free`-style heap manager with the following key characteristics:

- **Two-tier heap hierarchy**: a single *machine heap* (backed by a raw block of memory) acts as the system-wide pool. Zero or more *private heaps* are carved out of the machine heap on demand.
- **Segregated free lists**: ten size-class buckets narrow a first-fit search. Bucket selection is constant-time, but finding a fitting free block can require a linear scan.
- **Block coalescing**: adjacent free blocks are merged on `HeapFree` (unless disabled) to control long-term fragmentation.
- **In-place reallocation**: `HeapReAlloc` first attempts to grow or shrink a block without moving it by consuming or releasing the adjacent free block.
- **Configurable debug instrumentation**: each heap can independently enable debug fill patterns, buffer-overrun tail guards, free-check validation, parameter validation, and full per-call validation.
- **Heap identity**: every heap and every block carries a 16-bit ID in the high word of their flags field so cross-heap frees are detected at runtime.
- **Calling convention**: parameters are passed on the 68K stack and the caller removes them. Most functions return in D0; `_HeapValidate` and `_HeapValidateHandle` instead preserve D0 and report success in CCR.Z. Internal helpers have their own documented contracts.

The implementation lives in `src/`: 31 `.a68` modules, some containing several
functions, are assembled into `out/lib/libheap.a`. Public constants, structures,
and 13 public PROTO declarations are in `src/heap.inc`, copied to
`out/include/heap.inc` when built. The fourteenth public entry point,
`_HeapGetError`, is a leaf symbol declared with `extern` by callers. Library
objects and listings are placed in `out/lib/`; test objects, listings, and
executables are placed in `out/bin/`. The entire `out/` directory is excluded
from Git. The library uses the [MIT license](../LICENSE); bundled tools retain
their [upstream terms](../toolchain/README.md#notices).

ELF is the only supported object format. Build with [makefile](../makefile)
on Windows using the bundled tools. [makefile.macos](../makefile.macos) retains
an external-toolchain library/legacy-driver build, but has no automated suite
targets and has not been validated on a native macOS host.

---

## 2. Architecture and Internal Structures

### 2.1 Memory Model

```
Low address
┌───────────────────────────────────┐
│  Heap Header   (HEAP_HDR_SIZE=$40)│
│  • magic, flags/id, sizes         │
│  • hhHeapHead pointer             │
│  • 10 × hhFreeHeadN pointers      │
│  • hhSmallPool (SCB pointer)       │
├───────────────────────────────────┤  ← hhHeapHead points here
│  Block Header  (BLK_HDR_SIZE=$20) │
│  Block data area                  │
├───────────────────────────────────┤
│  Block Header                     │
│  Block data area                  │
├───────────────────────────────────┤
│  ...                              │
├───────────────────────────────────┤
│  End-of-Heap Marker (BLK_HDR_SIZE)│
│  PAEH × (BLK_HDR_SIZE/4) longs   │
└───────────────────────────────────┘
High address
```

Regular block headers and data pointers are aligned to `BLK_HDR_SIZE`
(32 bytes); SOA cells are guaranteed only 8-byte alignment (§2.7). The heap
must reside in readable/writable memory below `$01000000`: regular handle and
block checks reject a nonzero upper address byte. Validation is not a safe
probe of arbitrary or unmapped addresses; callers must supply valid storage
and live handles/pointers.

### 2.2 Heap Header

Defined at offset 0 from the heap handle. Size: `HEAP_HDR_SIZE` = `$40` (64 bytes).

| Offset | Symbol | Size | Description |
|--------|--------|------|-------------|
| `$00` | `hhMagic` | long | Magic number `'HEAP'` (`$48454150`) |
| `$04` (long base; low word at `$06`) | `hhFlags` | long / low word | Configuration flags in the low 16 bits (see §3) |
| `$04` (hi word) | `hhId` | word | Heap ID (monotonically assigned on creation) |
| `$08` | `hhRequestSize` | long | Size passed to `_MachineHeapInitialize` or `_HeapCreate` |
| `$0C` | `hhSize` | long | Actual total heap size including all headers |
| `$10` | `hhHeapHead` | long | Pointer to first block in the physical block chain |
| `$14`–`$38` | `hhFreeHead0`–`hhFreeHead9` | 10 × long | Segregated free-list heads (one per size bucket) |
| `$3C` | `hhSmallPool` | long | Pointer to this heap's Small Object Allocator control block (SCB), or NULL until first small allocation (§2.7). Zeroed on creation. Formerly `hhReserved`. |

The heap handle returned by `_MachineHeapInitialize` and `_HeapCreate` is a pointer to this structure.

### 2.3 Block Header

Every regular allocated or free block begins with a header immediately before
the data area. Size: `BLK_HDR_SIZE` = `$20` (32 bytes). A regular allocation's
user pointer is at `bhData`, offset `$20`. SOA cells have no such per-cell header.

| Offset | Symbol | Size | Description |
|--------|--------|------|-------------|
| `$00` | `bhMagic` | long | Magic number `'BLKH'` (`$424C4B48`) |
| `$04` (long base; low word at `$06`) | `bhFlags` | long / low word | Block status flags in the low 16 bits |
| `$04` (hi word) | `bhId` | word | Heap ID this block belongs to |
| `$08` | `bhRequestSize` | long | User-requested size (data area only; for free blocks this equals the data area size) |
| `$0C` | `bhSize` | long | Total block size including this header |
| `$10` | `bhPrev` | long | Pointer to previous block in physical chain (NULL = first) |
| `$14` | `bhNext` | long | Pointer to next block in physical chain (NULL = last) |
| `$18` | `bhFreePrev` | long | Pointer to previous block in bucket free chain (NULL = head) |
| `$1C` | `bhFreeNext` | long | Pointer to next block in bucket free chain (NULL = tail) |
| `$20` | `bhData` | — | Start of user data area |

**Block flags** (low word of `bhFlags`):

| Bit | Name | Set when |
|-----|------|----------|
| 0 | `FLG_FREE` | Block is on the free list |
| 1 | `FLG_GARBAGE` | Reserved garbage marker; current paths clear it but do not set it |

The physical block chain is a doubly-linked list in address order. For a
non-final block at address `B`, `bhNext(B) = B + bhSize(B)`, and
`bhPrev(bhNext(B)) = B`. The last block has `bhNext = 0`.

### 2.4 End-of-Heap Marker

The last `HEAP_END_SIZE` bytes (32) of every heap are filled with the longword
`'PAEH'` (`$50414548`). `_HeapValidate` checks the **first longword** and verifies
that the marker starts where the final block's address plus size predicts.
It does not scan all eight marker longwords. The marker is not a block-chain
entry (`bhNext` of the last real block is NULL).

### 2.5 Segregated Free Lists

Ten size-bucketed doubly-linked free lists are maintained, indexed by the
data-area size of the free block:

| Bucket | Offset in header | Maximum data size |
|--------|-----------------|-------------------|
| 0 | `hhFreeHead0` | ≤ 64 bytes |
| 1 | `hhFreeHead1` | ≤ 128 bytes |
| 2 | `hhFreeHead2` | ≤ 256 bytes |
| 3 | `hhFreeHead3` | ≤ 512 bytes |
| 4 | `hhFreeHead4` | ≤ 1 KB |
| 5 | `hhFreeHead5` | ≤ 4 KB |
| 6 | `hhFreeHead6` | ≤ 16 KB |
| 7 | `hhFreeHead7` | ≤ 64 KB |
| 8 | `hhFreeHead8` | ≤ 256 KB |
| 9 | `hhFreeHead9` | > 256 KB |

`__HeapGetBucketOffset` maps a data-area size to a bucket offset **relative to
`hhFreeHead0`**. All insertions are LIFO (new head of bucket). Allocation starts
in the bucket containing the required data size, scans for the first fit, and
walks upward until a fit is found or all buckets are exhausted.

Bucket 9 is the overflow bucket for data areas larger than 256 KB. All buckets,
not just bucket 9, use first-fit scans rather than best-fit ordering.

### 2.6 Global Data

The following globals live in `HeapData.a68`:

| Symbol | Description |
|--------|-------------|
| `__HeapId` (word) | Next heap ID counter. Incremented each time a new heap is created. The full longword is read to OR the ID into flags fields. |
| `__MachineHeapHandle` | Pointer to the machine heap header, or NULL before initialization. |
| `__HeapError` | Last error code set by any heap API function. |
| `__HeapSoaClassTbl` | Sixteen word-sized SOA class values, shared by allocation, validation, and tests. |

`__HeapId` is a word followed by a zero padding word; reading its longword form
places the ID in the high word of a flags longword.

---

### 2.7 Small Object Allocator (SOA)

Small requests are expensive for the block allocator: every allocation carries a
32-byte header and is rounded up to a 32-byte boundary, so a 1-byte request costs a
64-byte footprint. The **Small Object Allocator** is a slab/segregated-fit sub-allocator
layered on top of the block allocator to serve small requests densely. It is **on by
default**; opt out per heap (or per allocation call) with the mask
`HEAP_DISABLE_SMALL_POOL` (bit position `FLG_HEAP_DISABLE_SMALL_POOL`).

**Routing.** `_HeapAlloc` sends a request to the SOA when *all* of the following hold:
`1 ≤ lBytes ≤ SOA_MAX` (256), the heap does **not** have `FLG_HEAP_DISABLE_SMALL_POOL`
set, the call does not pass that flag, and the heap does **not** have
`FLG_HEAP_ENABLE_TAIL_CHECK` set (tail checking needs the block path's guard band). If
the SOA cannot satisfy the request (its parent heap is exhausted), `_HeapAlloc` falls
back to the block path transparently.

**Size classes.** A request maps to one of 16 size classes:
`8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256` bytes. A cell is
the class size (≥ the request); there is no per-cell header. Actual overhead
includes request-to-class rounding, the 32-byte slab header, unused slab
capacity, the SCB, and arena descriptor/backing-block costs.

**Structures.** Each heap that uses the SOA gets a lazily created **SCB** (small-pool
control block), stored in the heap header's `hhSmallPool` field (the former reserved
slot). The SCB owns a list of **arenas** — `SLAB_SIZE`-aligned (4 KB) tile regions
carved from ordinary parent-heap blocks — and per-class lists of partially-used and
full **slabs**. A slab is one 4 KB tile divided into equal cells with an intrusive
free list; the free path releases a slab (and its arena, once empty) back to the block
allocator eagerly. The SCB, arenas, and slabs are described by the `'SCB '`, `'AREN'`,
and `'SLAB'` magics respectively.

**NM1 aligned backing.** Each arena owns a separate 28-byte regular-block
descriptor and a regular backing block whose data pointer is 4 KB aligned.
The descriptor is allocated with `HEAP_DISABLE_SMALL_POOL`, so it cannot
recursively create another pool. Backing requests are exactly
`arSlabs * SLAB_SIZE`, not `(arSlabs + 1) * SLAB_SIZE`.

| Arena offset | Field | Size | Meaning |
| --- | --- | --- | --- |
| `$00` | `arMagic` | long | `'AREN'` |
| `$04` | `arBlock` | long | Backing **data** pointer; its block header is 32 bytes earlier |
| `$08` | `arNext` | long | Next separately owned descriptor |
| `$0C` | `arBase` | long | Tile base, equal to `arBlock` |
| `$10` | `arSlabs` | word | Reserved tiles, 1 through 32 |
| `$12` | `arSlabUse` | word | Live tiles |
| `$14` | `arTileMap` | long | Live-tile bitmap |
| `$18` | `arPadding` | long | Unusable retained backing suffix, zero through 32 bytes |

The first 24 bytes retain their original offsets, but descriptor/block aliasing
is no longer valid. Normal descriptor commitment is 64 bytes including header
and rounding. Backing commitment is tile payload plus its 32-byte header,
retained padding, and any configured tail guard. Legal prefix/suffix fragments
remain reusable regular free blocks. Empty-arena release unlinks and captures
ownership before freeing backing and descriptor.

The internal `__HeapAllocAligned(hHeap, lFlags, lBytes, lAlignment, pPadding)`
returns an ordinary regular-block data pointer. Alignment must be a power of
two of at least 32 bytes; requests must be nonzero. Arithmetic and the 24-bit
address bound are checked before chain mutation. `pPadding` is an optional
longword output, initialized to zero before parameter checks after heap
validation. Failure returns zero with an explicit heap error and leaves
the physical/free chains unchanged. This is not a new public `HeapAlloc`
alignment guarantee, and an ordinary moving `HeapReAlloc` need not preserve
the internal allocation's larger alignment.

**Consequences for callers.**
- **Alignment.** Cells are **8-byte aligned** (block allocations remain 32-byte
  aligned). All addresses are even, so word/long access is safe. Do not assume small
  allocations have more than 8-byte alignment or tag their low 5 bits.
- **`_HeapSize`.** For a cell, `_HeapSize` returns the **class (usable) size**, not the
  original request (analogous to `malloc_usable_size`). Block allocations still return
  the exact requested size. See §5.7.
- **`_HeapFree` / `_HeapReAlloc`.** Recognize and handle cells transparently; a
  recognized cell freed to the wrong heap reports `HEAP_ERROR_HANDLE_BLOCK_MISMATCH`.
  A repeat free is detected as `HEAP_ERROR_DOUBLE_FREE` while the slab remains
  live. After its last cell is freed, the slab magic is invalidated and a stale
  pointer need not produce that same error.
- **Debugging.** `_HeapValidate` deep-checks the SOA; `_HeapCompact` releases any empty
  slabs/arenas. The SCB itself remains allocated until the owning heap is
  destroyed. The internal `__HeapSoaWalk` enumerates live cells for tooling;
  public `_HeapWalk` and single-block `_HeapValidate` remain regular-block APIs.

---

## 3. Heap Flags

Flags are stored in the low word of `hhFlags` in the heap header. Each flag is a bit position; the corresponding mask constant is `1 shl FLG_...`.

| Bit | Name | Mask constant | Description |
|-----|------|--------------|-------------|
| 0 | `FLG_HEAP_ZERO_MEMORY` | `HEAP_ZERO_MEMORY` | Initialize allocated blocks to zero. Overridden by `FLG_HEAP_ENABLE_DEBUG_FILL`. |
| 1 | `FLG_HEAP_REALLOC_IN_PLACE_ONLY` | `HEAP_REALLOC_IN_PLACE_ONLY` | Prevent block movement during `_HeapReAlloc`. |
| 2 | `FLG_HEAP_ENABLE_DEBUG_FILL` | `HEAP_ENABLE_DEBUG_FILL` | Fill allocated blocks with `$CDCDCDCD`; fill freed blocks with `$BAADF00D`. Supersedes `FLG_HEAP_ZERO_MEMORY`. |
| 3 | `FLG_HEAP_ENABLE_TAIL_CHECK` | `HEAP_TAIL_CHECKING_ENABLED` | Write `$ABABABAB` guard words after each allocation's data area; check them on `_HeapFree`. `HEAP_TAIL_SIZE` (= `$20`) bytes are reserved beyond `lBytes`. |
| 4 | `FLG_HEAP_ENABLE_FREE_CHECK` | `HEAP_FREE_CHECKING_ENABLED` | Run `_HeapValidate` on the entire heap on each `_HeapFree` call. |
| 5 | `FLG_HEAP_VALIDATE_PARAMETERS` | `HEAP_VALIDATE_PARAMETERS` | Run `_HeapValidateHandle` on each heap API call. |
| 6 | `FLG_HEAP_VALIDATE_ALL` | `HEAP_VALIDATE_ALL_ENABLED` | Run full `_HeapValidate` on each heap API call. Very slow; use only for corruption hunting. |
| 7 | `FLG_HEAP_ENABLE_TAGGING` | `HEAP_ALLOCATION_TAGGING_ENABLED` | Reserved for future use (tagging not yet implemented). |
| 8 | `FLG_HEAP_DISABLE_COALESCING` | `HEAP_DISABLE_COALESCE_ON_FREE` | Skip coalescing on `_HeapFree`. `_HeapCompact` will coalesce explicitly. |
| 9 | `FLG_HEAP_TRAP_ON_ERROR` | `HEAP_TRAP_ON_ERROR` | Reserved. Intended to issue a `TRAP` instruction on detecting heap corruption instead of returning an error code. |
| 10 | `FLG_HEAP_DISABLE_SMALL_POOL` | `HEAP_DISABLE_SMALL_POOL` | Opt out of the Small Object Allocator (§2.7). When set on a heap, all requests use the block allocator regardless of size. May also be passed at call time to `_HeapAlloc` to force a single allocation onto the block path. |

Per-call flags **enable** the supported option for that call; passing zero
does not disable a heap-level option. `_HeapAlloc` honours `HEAP_ZERO_MEMORY`
and `HEAP_DISABLE_SMALL_POOL`; `_HeapReAlloc` honours `HEAP_ZERO_MEMORY` and
`HEAP_REALLOC_IN_PLACE_ONLY`, and forwards flags when it allocates a replacement.
Debug fill and tail checking are selected from the heap flags, not enabled by
passing their masks to an individual allocation. Heap-level flags persist.

---

## 4. Error Codes

Error codes are stored in `__HeapError` and retrieved via `_HeapGetError`. Most API functions also signal failure through their return value (NULL or zero).

| Value | Name | Meaning |
|-------|------|---------|
| `$00` | `HEAP_ERROR_SUCCESS` | No error |
| `$01` | `HEAP_ERROR_INVALID_PARAM` | Bad parameter (e.g. NULL `pEntry` to `_HeapWalk`) |
| `$02` | `HEAP_ERROR_INVALID_HANDLE` | Heap handle is NULL or does not pass validation |
| `$03` | `HEAP_ERROR_INVALID_BLOCK` | Pointer is not a valid heap block (bad magic, wrong alignment, already freed, or NULL) |
| `$04` | `HEAP_ERROR_INVALID_PREV_LINK` | Block chain back-link is incorrect |
| `$05` | `HEAP_ERROR_INVALID_NEXT_LINK` | Block chain forward-link is incorrect |
| `$06` | `HEAP_ERROR_INVALID_FPREV_LINK` | Free-chain back-link is incorrect |
| `$07` | `HEAP_ERROR_BLOCK_NOT_FREE` | Block found in a free chain is not marked free |
| `$08` | `HEAP_ERROR_HEAPEND_BAD_MAGIC` | End-of-heap magic is corrupt |
| `$09` | `HEAP_ERROR_INVALID_HEAPEND` | End-of-heap marker is at the wrong address |
| `$0A` | `HEAP_ERROR_HANDLE_BLOCK_MISMATCH` | Block's heap ID does not match the supplied heap handle |
| `$0B` | `HEAP_ERROR_OUT_OF_MEMORY` | No free block large enough for the request |
| `$0C` | `HEAP_ERROR_NOT_INITIALIZED` | Machine heap has not been initialized |
| `$0D` | `HEAP_ERROR_INITIALIZED` | Machine heap is already initialized (duplicate init) |
| `$0E` | `HEAP_ERROR_NO_MORE_ITEMS` | `_HeapWalk` has reached the end of the heap |
| `$0F` | `HEAP_HEADER_BLOCK_HEADPTR_BAD` | `hhHeapHead` does not point to a valid block |
| `$10` | `HEAP_HEADER_BLOCK_FREEPTR_BAD` | A bucket head does not point to a valid block |
| `$11` | `HEAP_HEADER_BAD_MAGIC` | Heap header magic number is corrupt |
| `$12` | `HEAP_HEADER_INVALID_SIZE` | `hhSize` cannot be derived from `hhRequestSize` |
| `$13` | `HEAP_ERROR_TAIL_VALIDATION_FAILED` | Buffer-overrun tail guard was modified |
| `$14` | `HEAP_ERROR_INVALID_FNXT_LINK` | Free-chain forward-link is incorrect |
| `$15` | `HEAP_ERROR_SLAB_CORRUPT` | Small-pool slab header, free list, or class list is inconsistent (§2.7) |
| `$16` | `HEAP_ERROR_DOUBLE_FREE` | Small-pool cell was already free when `_HeapFree` was called |
| `$17` | `HEAP_ERROR_SOA_ARENA_CORRUPT` | Small-pool control block or arena descriptor is inconsistent (§2.7) |

---

## 5. Public API

### 5.1 `_MachineHeapInitialize`

```
PROTO  , lOptions:DWORD, lStart:DWORD, lSize:DWORD
```

**Purpose**: Creates the machine heap in caller-supplied memory, once before
allocation or private-heap management. Status/handle queries can report
the not-initialized state before this call.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `lOptions` | Heap flags (see §3). May be 0 or any combination of flag mask constants. |
| `lStart` | Address of the first byte available for the heap. The implementation rounds this up to the next `BLK_HDR_SIZE` boundary internally. |
| `lSize` | Requested initial **free data capacity**, not the total backing-region size. |

**Return value**: D0 = heap handle on success, NULL on failure. Call `_HeapGetError` on failure.

**Errors**: `HEAP_ERROR_INITIALIZED` if called a second time.

**Backing storage precondition**: the function rounds `lStart` **up** to 32 bytes
and uses `round_up(lSize,32) + HEAP_HDR_SIZE + BLK_HDR_SIZE + HEAP_END_SIZE`
bytes from that aligned address: `round_up(lSize,32) + 128` in this build.
The caller must provide that entire writable range, including up to 31 bytes
lost before the aligned start. There are no general bounds/overflow checks
here. Align the start first and round the available data capacity **down**
after subtracting 128 bytes and any stack reservation; see §7.1.

**Design notes**: The function aligns `lStart` up to a `BLK_HDR_SIZE` boundary, then lays out: heap header → one large free block → end-of-heap marker. The free block is placed into the appropriate size bucket. If `FLG_HEAP_ENABLE_DEBUG_FILL` is set, the entire data area of the initial free block is filled with `$BAADF00D`. The new heap receives the current `__HeapId` value in the high word of its flags; `__HeapId` is then incremented. The handle is stored in `__MachineHeapHandle`.

---

### 5.2 `_HeapCreate`

```
PROTO  , lOptions:DWORD, lSize:DWORD
```

**Purpose**: Creates a private heap by allocating
`round_up(lSize,32) + 128` bytes from the machine heap and initializing that
storage as an independent heap. `lSize = 0` is accepted; it does not promise a
useful nonzero allocation capacity.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `lOptions` | Heap flags for the new private heap. Independent of the machine heap's flags. |
| `lSize` | Requested usable heap size in bytes. |

**Return value**: D0 = handle to the new private heap on success, NULL on failure.

**Errors**: `HEAP_ERROR_NOT_INITIALIZED` if the machine heap has not been created. `HEAP_ERROR_OUT_OF_MEMORY` if the machine heap cannot satisfy the allocation. The machine heap's configured validation flags are applied before allocating.

**Design notes**: The private heap's layout is identical to the machine heap.
Its parent allocation normally is a regular block, but `_HeapCreate` does
not force the machine heap's SOA off: with that pool enabled, requests of
`lSize ≤ 128` can fit a 128–256-byte cell instead. Destruction frees the parent
allocation through `_HeapFree` in either case. Private heaps receive their own
ID and flags. Tiny SOA-backed private heaps are not found by the regular-block
scan in `_GetMachineHeaps` (§5.13).

---

### 5.3 `_HeapDestroy`

```
PROTO  , hHeap:DWORD
```

**Purpose**: Destroys a private heap and returns its memory to the machine heap.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `hHeap` | Handle to the private heap to destroy. Must not be the machine heap handle. |

**Return value**: D0 = non-zero (TRUE) on success, zero (FALSE) on failure.

**Errors**: `HEAP_ERROR_NOT_INITIALIZED` if the machine heap does not exist;
`HEAP_ERROR_INVALID_HANDLE` if `hHeap` is NULL or is the machine heap handle.
Configured validation failures and the error from the parent `_HeapFree`
are propagated.

**Design notes**: Before returning the parent allocation, the function
invalidates the private heap's slab/arena magics and zeroes its heap header.
All outstanding allocations are discarded with the containing storage; there
is no drain or destructor mechanism and their pointers become invalid. It is
not possible to destroy the machine heap.

---

### 5.4 `_HeapAlloc`

```
PROTO  , hHeap:DWORD, lFlags:DWORD, lBytes:DWORD
```

**Purpose**: Allocates a block of memory from the specified heap.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `hHeap` | Heap to allocate from. |
| `lFlags` | `HEAP_ZERO_MEMORY` enables zeroing unless heap debug fill takes precedence; `HEAP_DISABLE_SMALL_POOL` forces this request onto the regular path. |
| `lBytes` | Requested bytes. Zero bypasses the SOA and creates a zero-length regular allocation on success; it must still be freed. |

**Return value**: D0 = pointer to the allocated data area on success, NULL on failure.

**Errors**: configured validation errors, `HEAP_ERROR_OUT_OF_MEMORY` if no
sufficiently large free block exists, or `HEAP_ERROR_BLOCK_NOT_FREE` if the
allocation scan finds a non-free entry in a free chain.

**Small Object Allocator**: When routing conditions are met (`1 ≤ lBytes ≤ 256`, small
pool not disabled on the heap or the call, tail checking off), the request is served by
the SOA as an 8-byte-aligned cell instead of a 32-byte block (§2.7). On SOA exhaustion
of the parent heap, allocation falls back to the block algorithm below.

**Allocation algorithm** (block path):

1. Run `__HeapAutoValidateFlagCheck` before either SOA or regular allocation.
2. Round `lBytes` up to the next `BLK_HDR_SIZE` boundary; add `BLK_HDR_SIZE` for the header. If tail checking is enabled, also add `HEAP_TAIL_SIZE` (32 bytes) before alignment.
3. Call `__HeapGetBucketOffset` on the minimum required data size to find the starting bucket.
4. Walk buckets from the starting bucket upward until a non-empty bucket is found.
5. Walk the free chain within that bucket looking for a block with `bhSize >= required`. If the block is too small, advance within the chain; if the chain is exhausted, move to the next bucket.
6. **Exact fit or near-exact fit** (leftover ≤ `BLK_HDR_SIZE`): unlink the block from its free chain, mark it allocated.
7. **Split**: split the free block into the allocated portion and a new free remainder. The remainder is inserted into the correct bucket at the head (LIFO).
8. Write fill/zero/tail-check data via the internal `__FillBlock` subroutine.
9. Return `bhData` address of the allocated block.

**`__FillBlock` behaviour**:
- If `FLG_HEAP_ENABLE_TAIL_CHECK`: fill bytes from the rounded-up end of `bhRequestSize` to the end of the block's data area with `$ABABABAB`.
- If `FLG_HEAP_ENABLE_DEBUG_FILL`: fill data area (up to `bhRequestSize`) with `$CDCDCDCD`.
- Else if `HEAP_ZERO_MEMORY` (from caller flags or heap flags): zero-fill data area.
- Fill handles 32-bit counts with a `dbra` + `sub.l #$10000,dn` loop.

---

### 5.5 `_HeapFree`

```
PROTO  , hHeap:DWORD, pMem:DWORD
```

**Purpose**: Frees a previously allocated block and returns it to the heap's free pool.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `hHeap` | Heap the block was allocated from. |
| `pMem` | Live pointer returned by `_HeapAlloc` or `_HeapReAlloc`. NULL is a no-op **after** heap validation succeeds. |

**Return value**: D0 = non-zero (TRUE) on success, zero (FALSE) on failure.

**Errors**: `HEAP_ERROR_INVALID_BLOCK` if the pointer is not a valid, allocated heap block. `HEAP_ERROR_HANDLE_BLOCK_MISMATCH` if the block's heap ID does not match `hHeap`. `HEAP_ERROR_TAIL_VALIDATION_FAILED` if tail guard bytes are corrupt.

**SOA path**: after automatic heap validation, a non-NULL pointer is probed
with `__HeapSlabFromPtr`. A recognized cell's heap ID is checked, then
`__HeapSoaFree` returns it to its slab. The free tag plus a bounded free-list
membership check detects double-free without mistaking matching live user
data for a free cell. Full slabs become partial; empty slabs and their
otherwise-empty arenas are released eagerly. Debug poison precedes rewriting
the first four bytes as free-list control. The SCB remains.

**Regular-block free algorithm** (when the SOA probe did not recognize a cell):

1. Run `__HeapAutoValidateFlagCheck` with `fFree = -1` (triggers `FLG_HEAP_ENABLE_FREE_CHECK` path).
2. Subtract `BLK_HDR_SIZE` from `pMem` to get the block header.
3. Validate alignment (upper byte zero, lower bits zero within `BLK_HDR_SIZE-1` mask), magic number, free-flag, and heap ID.
4. If `FLG_HEAP_ENABLE_TAIL_CHECK`: scan guard bytes from `round_up(bhRequestSize,4)` to end of data area; abort on corruption.
5. If `FLG_HEAP_DISABLE_COALESCING` is clear: call `__HeapCoalesce`. If coalescing occurred, the block is already back in a free bucket.
6. Otherwise (no coalescing or coalescing disabled): insert block at the head of the correct bucket, update `FLG_FREE` and clear `FLG_GARBAGE` in `bhFlags`.
7. If `FLG_HEAP_ENABLE_DEBUG_FILL`: call `__HeapDebugFillOnFree` to fill the data area with `$BAADF00D`.

---

### 5.6 `_HeapReAlloc`

```
PROTO  , hHeap:DWORD, lFlags:DWORD, pMem:DWORD, lBytes:DWORD
```

**Purpose**: Changes the size of an existing allocation. Attempts in-place resize before resorting to allocate-copy-free.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `hHeap` | Heap the block was allocated from. |
| `lFlags` | `HEAP_ZERO_MEMORY` enables zeroing on growth, subject to debug-fill precedence and the SOA exceptions below. `HEAP_REALLOC_IN_PLACE_ONLY` forbids a required move; a heap-level in-place-only flag cannot be turned off by passing zero. |
| `pMem` | Existing allocation pointer. Must not be NULL. |
| `lBytes` | New requested size. Zero means a minimal, still-live zero-length regular allocation on success, **not** free. |

**Return value**: D0 = pointer to the (possibly relocated) data area on success, NULL on failure. On failure, the original block is untouched and valid.

**Errors**: `HEAP_ERROR_INVALID_BLOCK` if `pMem` is invalid. `HEAP_ERROR_HANDLE_BLOCK_MISMATCH` if the block is not owned by `hHeap`. `HEAP_ERROR_OUT_OF_MEMORY` if in-place growth failed and `HEAP_REALLOC_IN_PLACE_ONLY` was specified, or if `_HeapAlloc` failed on relocation.

**SOA-origin reallocation**:
- A nonzero request in the same class returns the existing cell unchanged.
  No original request size is stored, so same-class grow/shrink does not
  zero or debug-fill a newly exposed/surrendered subrange.
- A different small class allocates another cell with `__HeapSoaAlloc`,
  copies `min(new request, old class size)` bytes, and frees the old cell.
  Unlike public `_HeapAlloc`, this direct cell-to-cell path has no regular
  fallback on SOA exhaustion.
- A zero or greater-than-256-byte request uses `_HeapAlloc` for the
  replacement, with the same bounded copy followed by cell release.
- In-place-only permits the same-class case and rejects every required move.
  Newly allocated space is filled by its allocator; on a grow, initialization
  beyond the old **class size** applies, not beyond an unrecorded old request.

**Regular-block realloc algorithm**:

1. Validate `pMem` (alignment, magic, not free, heap ID).
2. Compute required total block size `D1` (same rounding as `_HeapAlloc`).
3. Compare `D1` to current `bhSize`:
   - **Equal**: retain the block, update `bhRequestSize`, initialize growth bytes if requested, and rewrite the tail guard when enabled.
   - **Grow** (`D1 > bhSize`):
     - Check if `bhNext` is free and large enough.
       - If so and splitting is worthwhile: take only what is needed from the free block, insert the remainder as a new free block, invalidate the old free block header.
       - If so but splitting not worthwhile: consume the entire next block — unlink it from both free and block chains, absorb its size into the current block.
     - If in-place growth is impossible: check `HEAP_REALLOC_IN_PLACE_ONLY`; if set, fail. Otherwise allocate new block, copy `bhRequestSize` bytes, free original.
     - On in-place growth, fill newly added bytes with debug pattern or zero as configured.
   - **Shrink** (`D1 < bhSize`):
     - If leftover > `BLK_HDR_SIZE`: split a new free block from the tail, insert it into the correct bucket, optionally coalesce with successor.
     - If leftover ≤ `BLK_HDR_SIZE`: keep the block at its current size (internal fragmentation).
     - Debug-fill surrendered bytes if enabled.
   - In all cases, rewrite tail guard at the new position if tail-checking is enabled.
4. Return pointer to data area.

Shrinking a regular block below `SOA_MAX` does **not** convert it to a cell,
even with the SOA enabled. It stays on the regular path and can shrink in
place with `HEAP_REALLOC_IN_PLACE_ONLY`. A later moving regular realloc calls
`_HeapAlloc`, whose routing applies to that replacement.

**Current debug-shrink limitation**: on retained regular blocks,
`HEAP_ENABLE_DEBUG_FILL` rounds the surrendered range **down** to a longword
boundary. A shrink to a non-multiple of four can overwrite up to three bytes
that are still inside the new request (for example 36 → 33 overwrites byte 32).
Do not rely on complete prefix preservation for that case; this is an
implementation limitation, not an intended realloc guarantee.

**On relocation**: The original block's requested size is used as the copy length, guaranteeing that no uninitialized data is propagated. If `_HeapFree` fails after a successful copy (a degenerate internal consistency failure), the error is cleared so the caller receives the valid new pointer.

---

### 5.7 `_HeapSize`

```
PROTO  , hHeap:DWORD, pMem:DWORD
```

**Purpose**: Returns the latest requested size of a regular allocation, or the
usable class size of an SOA cell.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `hHeap` | Heap that owns the block. |
| `pMem` | Allocation pointer from `_HeapAlloc` or `_HeapReAlloc`. |

**Return value**: D0 = `bhRequestSize` of the block on success, `-1` on failure.

**Errors**: `HEAP_ERROR_INVALID_BLOCK`, `HEAP_ERROR_HANDLE_BLOCK_MISMATCH`.

**Notes**: For a **block** allocation, returns the *requested* byte count, not the
*actual* block size (which is always a multiple of `BLK_HDR_SIZE` and may include
tail-guard space) — the same value passed as `lBytes` to the most recent `_HeapAlloc`
or `_HeapReAlloc`. For a **Small Object Allocator cell** (§2.7), no per-cell request
size is stored, so `_HeapSize` returns the **class (usable) size** — the smallest class
value ≥ the original request (analogous to `malloc_usable_size`). Callers must not
assume `_HeapSize` echoes the exact request for small allocations.

---

### 5.8 `_HeapCompact`

```
PROTO  , hHeap:DWORD
```

**Purpose**: Sweeps fully empty SOA slabs/arenas, then returns the data size of
the largest regular free block. If `FLG_HEAP_DISABLE_COALESCING` is set, it
also coalesces adjacent regular free blocks before scanning.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `hHeap` | Heap to compact. |

**Return value**: D0 = data-area size (bytes) of the largest free block, or zero if the heap is fully allocated (in which case `_HeapGetError` returns `HEAP_ERROR_SUCCESS`). Zero is also returned on validation failure.

**Design notes**: When coalescing is normally enabled, free blocks are already coalesced on every `_HeapFree`, so this call only performs the scan. When `FLG_HEAP_DISABLE_COALESCING` is set, the function first walks all ten buckets and calls `__HeapCoalesce` on each free block; it restarts each bucket's walk after any successful coalesce (because the block may have moved to a larger bucket). The returned size excludes the `BLK_HDR_SIZE` overhead.

The SOA normally releases empty slabs/arenas on the last free, so its compact
sweep is often a no-op. It neither moves live cells nor frees the retained
SCB. The result is not total free space, free-cell capacity, or a guaranteed
maximum request when tail-guard overhead is enabled.

---

### 5.9 `_HeapValidate`

```
PROTO  , hHeap:DWORD, pBlock:DWORD
```

**Purpose**: Validates the integrity of the entire heap or a single block within it.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `hHeap` | Heap to validate. |
| `pBlock` | NULL validates the entire heap, including its SOA. A non-NULL value must be a **regular-block data pointer**, not an SOA cell. |

**Result**: CCR.Z = 1 on success, 0 on failure; **D0 is preserved**, not a
returned status. Branch on Z immediately after the call and stack cleanup
(`ADDA` preserves CCR). `__HeapError` is set to success or the detected error;
use `_HeapGetError` when an error code is needed.

**Single-block validation**:
- Alignment and magic check.
- Heap ID ownership check.
- Linear walk of the block chain to confirm the block is physically present in this heap.
- Back-link (`bhPrev`) consistency: `bhPrev(this)->bhNext == this`.
- Forward-link (`bhNext`) consistency: `bhNext(this)->bhPrev == this`.
- If free: free-chain back-link and forward-link consistency.

**Full-heap validation**:
1. Walk the physical block chain from `hhHeapHead`. For each block: alignment, magic, back-link, and computed forward-link (address + `bhSize` must equal `bhNext`).
2. At chain end: verify the first end-marker longword and that the computed address matches.
3. Walk all ten free-list buckets. For each block in a bucket: free-chain back-link consistency, and that the block has `FLG_FREE` set.
4. If no free blocks were found in any bucket (heap fully allocated): walk the physical chain and confirm no block has `FLG_FREE` set and no stale `bhFreePrev`/`bhFreeNext` pointers.
5. Call `__HeapSoaValidate` to check the SCB, owned arena descriptor/backing
   blocks, tile accounting, live slab headers and free lists, and the forward
   partial/full class lists.

This is not exhaustive memory-safety validation: for example, the SOA check
does not prove that every live tile occurs exactly once in the class lists or
recompute every running SCB counter. Arbitrary invalid pointers can still
fault when dereferenced.

---

### 5.10 `_HeapValidateHandle`

```
PROTO  , hHeap:DWORD
```

**Purpose**: Lightweight validation that a handle pointer looks like a valid heap. Used internally by `__HeapAutoValidateFlagCheck` and by callers needing a quick sanity check without a full chain walk.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `hHeap` | Handle to validate. |

**Result**: Z set on success, Z clear on failure. **All registers, including
D0, are preserved.** `__HeapError` is updated on failure only; successful
handle validation does not clear a previous error.

**Checks performed**:
- Handle not NULL.
- Lower bits zero, upper byte zero (aligned, valid address range).
- `hhMagic == 'HEAP'`.
- `hhSize` is consistent with `hhRequestSize` (using the same alignment arithmetic applied during creation).
- `hhHeapHead` points to a block with magic `'BLKH'`.
- Every non-NULL `hhFreeHeadN` pointer points to a block with magic `'BLKH'`.
- If `hhSmallPool` is non-NULL, its `scbMagic` must be `'SCB '`; a mismatch
  reports `HEAP_ERROR_SLAB_CORRUPT`.

It does not walk block/free chains or establish that arbitrary pointer fields
refer to mapped memory.

---

### 5.11 `_HeapWalk`

```
PROTO  , hHeap:DWORD, pEntry:DWORD
```

**Purpose**: Enumerates all blocks in the physical block chain of a heap, one at a time.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `hHeap` | Heap to enumerate. |
| `pEntry` | Pointer to a longword that holds the current enumeration state. Initialize `*pEntry = 0` to begin. On each call the function updates `*pEntry` with the raw block header address of the next block. |

**Return value**: D0 = non-zero on success (more blocks follow or the current block was returned). D0 = zero when the end of heap is reached (`__HeapError = HEAP_ERROR_NO_MORE_ITEMS`) or on error.

**Important**: `*pEntry` holds a raw **block header** pointer, not a user data pointer. To get the user-visible pointer, add `BLK_HDR_SIZE` (`$20`) to the value stored at `*pEntry`. This pointer cannot be passed directly to `_HeapFree`, `_HeapSize`, or `_HeapReAlloc`.

The walk includes free blocks and the SOA's internal SCB, arena descriptors,
and backing blocks; it does **not** enumerate individual cells. Do not free
internal allocations just because they appear in this walk. For live cells,
the internal companion is `__HeapSoaWalk` (§6.9). Do not mutate the heap while
using either cursor.

**Usage pattern**:
```asm
    extern  _HeapGetError

    clr.l   HeapEntry           ; Initialize: *pEntry = 0
walk_loop:
    move.l  #HeapEntry,-(sp)
    move.l  hHeap,-(sp)
    jsr     _HeapWalk
    adda.l  #8,sp
    tst.l   d0
    beq.s   walk_done
    ; process *HeapEntry (raw header pointer)
    bra.s   walk_loop
walk_done:
    jsr     _HeapGetError
    cmpi.l  #HEAP_ERROR_NO_MORE_ITEMS,d0
    beq.s   normal_end
    ; handle error
```

---

### 5.12 `_GetMachineHeap`

```
PROTO
```

**Purpose**: Returns the handle to the machine (system) heap.

**Return value**: D0 = machine heap handle on success, NULL if the machine heap has not been initialized (`__HeapError = HEAP_ERROR_NOT_INITIALIZED`).

---

### 5.13 `_GetMachineHeaps`

```
PROTO  , NumHeaps:DWORD, pHeaps:DWORD
```

**Purpose**: Counts the machine heap plus private-heap candidates found by a
regular-block scan, and fills a caller-supplied handle array.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `NumHeaps` | Nonnegative capacity of the `pHeaps` array, in handles. Use `(0, NULL)` for a count-only query. |
| `pHeaps` | Writable longword array of at least `NumHeaps` elements when capacity is nonzero. NULL alone is not a safe count-query form with a nonzero capacity. |

**Return value**: D0 = number found, or zero with
`HEAP_ERROR_NOT_INITIALIZED` before machine-heap initialization. If D0 exceeds
`NumHeaps`, only the capacity is stored; allocate `D0 × 4` bytes and retry
without changing the heap.

**Limitations**: this is a heuristic, not a registry. Allocated regular blocks
whose data starts with `'HEAP'` can be misidentified as heaps. Conversely, tiny
private heaps backed by SOA cells (§5.2) are missed. With a valid output buffer
and nonzero capacity, the machine heap is always the first entry.

---

### 5.14 `_HeapGetError`

**Prototype**: No PROTO (leaf function, no frame). Call with `jsr _HeapGetError`.

**Purpose**: Returns the last error code set by any heap API function.

**Return value**: D0 = `__HeapError`.

**Notes**: `_HeapGetError` is a pure leaf: `move.l __HeapError,d0` followed by
`rts`. It does not clear the error. Most operations reset the status at entry
or through automatic validation, but `_HeapValidateHandle` leaves an old
error unchanged on success. Declare `extern _HeapGetError` and call with
`jsr`; no PROTO for it is supplied by `heap.inc`.

---

## 6. Internal Functions

These functions are not public API. Most stack-based helpers have
double-underscore PROTO declarations in `heap.inc`; the register-based leaf
helpers and `__HeapStats` instead require explicit external declarations.

### 6.1 `__HeapAutoValidateFlagCheck`

```
PROTO  , hHeap:DWORD, fFree:DWORD
```

Dispatches automatic validation based on the heap's configuration flags. Called at the entry of every allocating/freeing API function. The `fFree` parameter is non-zero when the caller is `_HeapFree`, which activates `FLG_HEAP_ENABLE_FREE_CHECK`.

- If `FLG_HEAP_VALIDATE_ALL`: calls `_HeapValidate(hHeap, 0)`.
- Else if `FLG_HEAP_ENABLE_FREE_CHECK` and `fFree != 0`: calls `_HeapValidate(hHeap, 0)`.
- Else if `FLG_HEAP_VALIDATE_PARAMETERS`: calls `_HeapValidateHandle(hHeap)`.
- Otherwise: does nothing (Z=1 = success).

Clears `__HeapError` at entry and rejects NULL handles even if validation
flags are disabled. Returns with Z=1 on success and Z=0 on failure, preserving
all registers. The final `MOVEM` restore does not change the CCR established
by the validation/test instructions.

### 6.2 `__HeapCoalesce`

```
PROTO  , hHeap:DWORD, pBlock:DWORD
```

Merges `pBlock` with its physically adjacent free neighbors. `pBlock` may be allocated or free.

- Checks predecessor (`bhPrev`) and successor (`bhNext`) for the `FLG_FREE` flag.
- **CoalesceWithPrev**: surviving block is `bhPrev`. Absorbs `pBlock` into predecessor, removing `pBlock` from block chain and free chain. Preceding block is removed from its old bucket before size update, then re-inserted into the correct bucket.
- **CoalesceWithNext**: surviving block is `pBlock`. Absorbs `bhNext` into `pBlock`, removing `bhNext` from block chain and free chain.
- **CoalesceWithBoth**: surviving block is `bhPrev`. Absorbs both `pBlock` and `bhNext`.

After merging, updates `bhRequestSize` to the new data area size, clears `FLG_GARBAGE`, sets `FLG_FREE`, and inserts the result into the correct bucket (LIFO).

Returns D0 = pointer to coalesced block on success, or 0 if no coalescing was possible.

### 6.3 `__HeapUnlinkFromBlockChain`

```
PROTO  , hHeap:DWORD, pBlock:DWORD
```

Removes a block from the doubly-linked physical block chain by bridging `bhPrev(pBlock)->bhNext` to `bhNext(pBlock)` and updating the back-link of the successor. Does not modify free-chain pointers.

### 6.4 `__HeapUnlinkFromFreeBlockChain`

```
PROTO  , hHeap:DWORD, pBlock:DWORD
```

Removes a block from its segregated free list. Handles four cases: only block in bucket (clears bucket head), forward-link only (successor becomes new bucket head), back-link only (clears predecessor's forward link), and both links (bridges across the removed block). Uses `__HeapGetBucketOffset` to identify the correct bucket head pointer when updating the head.

### 6.5 `__HeapGetBucketOffset`

Not a `PROC` (leaf function). Public symbol, no frame.

```
; Input:  D0.l = data area size (bytes)
; Output: D0.l = byte offset relative to hhFreeHead0 / HEAP_FREE_BUCKET_BASE
```

Returns 0, 4, …, 36 for buckets 0–9 using `cmpi.l` / `ble.s` branches.
Use the result as `HEAP_FREE_BUCKET_BASE(a0,d0.l)`, not as an absolute
heap-header offset. Apart from D0's return value, only CCR is changed.

### 6.6 `__HeapDebugFillOnFree`

```
PROTO  , pBlock:DWORD
```

Fills the data area of a block with `$BAADF00D`. Called by `_HeapFree` and `__HeapCoalesce` when `FLG_HEAP_ENABLE_DEBUG_FILL` is set. `pBlock` is a block header pointer (not a user pointer). Uses the `bhSize - BLK_HDR_SIZE` data area size as the fill count.

### 6.7 `__HeapInvalidateBlockHeader`

```
PROTO  , hHeap:DWORD, pBlock:DWORD
```

Fills an absorbed block header with zero, or `$BAADF00D` when heap debug fill
is enabled, so its old magic is no longer valid. Used after unlinking absorbed
headers in coalescing and consume-next-block paths.

### 6.8 `__HeapStats`

`__HeapStats(hHeap, pStats)` fills the `HEAP_STATS_SIZE` (`$48`, 72-byte)
structure defined in `heap.inc`. Declare `extern __HeapStats` and push the
two arguments right-to-left. D0 is nonzero on success, zero on failure.

It walks **regular physical blocks** and records block/allocated/free counts,
requested and committed bytes, free bytes, committed-minus-requested
overhead, largest free data area, and a ten-bin **request-size** histogram.
Committed/free totals include their block headers but exclude the heap
header and end marker. The histogram boundaries differ from the free buckets.

With the SOA active, these totals count its SCB, descriptors, and tile-backing
requests, not individual caller cells. Use `scbLiveCells` and
`scbLiveCellBytes` for live-cell count and usable class bytes; exact original
cell requests must be tracked by the caller. This is not a workload
requested-byte or cell-density benchmark by itself.

### 6.9 SOA Helpers

The implementation modules and contracts are detailed in
[the SOA design](HEAP_SMALL_ALLOC_DESIGN.md). Key internal entry points include:

| Helper | Contract |
|--------|----------|
| `__HeapSoaSizeToClass` | Register leaf: D0 = request 0–256, returns class index 0–15; zero maps to class 0, although public zero allocation uses the regular path. |
| `__HeapScbGetOrCreate` | Returns the heap's lazily allocated, explicitly zero-initialized SCB. |
| `__HeapAllocAligned` | Checked regular allocation with power-of-two data alignment ≥32 and optional retained-padding output; see §2.7. |
| `__HeapArenaCreate` / `__HeapArenaRelease` | Own separate regular descriptor/backing allocations; requests are clamped to 1–32 tiles and failed multi-tile backing retries one tile. |
| `__HeapSlabCreate` / `__HeapSlabRelease` | Claim/release a tile; creation does not itself link the slab into a class list. |
| `__HeapSlabFromPtr` | Returns a recognized slab or zero; checks structure, tile membership, class bounds, nonzero cell size, and cell offset/index. Ownership is checked separately by the public caller. |
| `__HeapSoaAlloc` / `__HeapSoaFree` / `__HeapSoaReAlloc` | Cell operations with internal caller preconditions; they do not supply all public validation/routing checks themselves. |
| `__HeapSoaValidate` | Returns D0 = zero or a heap error code; unlike public `_HeapValidate`, this helper does not preserve D0. |
| `__HeapSoaCompact` | Sweeps empty slabs/arenas; retains the SCB and does not move live allocations. |
| `__HeapSoaWalk` | Uses a zero-initialized 12-byte `{swArena, swTile, swCell}` cursor; returns the next live cell or zero with `HEAP_ERROR_NO_MORE_ITEMS`. |

---

## 7. Usage Guide

### 7.1 Initialization Sequence

Initialize the machine heap before allocating or creating private heaps.
A typical sequence in a 68K CP/M or bare-metal environment is:

```asm
    ; Compute heap start and size from the base page or system state
    move.l  bsstart(a0),d2      ; End of BSS
    add.l   bslen(a0),d2        ; D2 = first byte after BSS
    addi.l  #BLK_HDR_SIZE-1,d2
    andi.l  #NOT(BLK_HDR_SIZE-1),d2 ; Align start before measuring capacity
    move.l  hightpa(a0),d1      ; Top of TPA
    sub.l   d2,d1               ; D1 = available bytes
    subi.l  #STKSIZE,d1         ; Reserve space for stack
    subi.l  #HEAP_HDR_SIZE+BLK_HDR_SIZE+HEAP_END_SIZE,d1
    ble     init_failed        ; Not enough room for heap overhead
    andi.l  #NOT(BLK_HDR_SIZE-1),d1 ; Round usable capacity DOWN

    ; Initialize the machine heap
    move.l  d1,-(sp)            ; lSize
    move.l  d2,-(sp)            ; lStart
    clr.l   -(sp)               ; lOptions = 0
    jsr     _MachineHeapInitialize
    adda.l  #12,sp
    tst.l   d0
    beq     init_failed
    move.l  d0,hMachineHeap
```

Or using `INVOKE` (requires `heap.inc` to be included):
```asm
    INVOKE  _MachineHeapInitialize, #0, d2, d1
    tst.l   d0
    beq     init_failed
```

### 7.2 Private Heaps

Private heaps isolate separate subsystems from each other and from the system pool:

```asm
    INVOKE  _HeapCreate, #(HEAP_ENABLE_DEBUG_FILL or HEAP_TAIL_CHECKING_ENABLED), #8192
    tst.l   d0
    beq     create_failed
    move.l  d0,hMyHeap

    ; ... use hMyHeap for allocations ...

    INVOKE  _HeapDestroy, hMyHeap    ; Release all memory at once
```

All storage within a private heap is reclaimed when it is destroyed, with no
need to free individual allocations first. This is not synchronization:
callers must prevent concurrent access and discard all old handles/pointers.

### 7.3 Allocating and Freeing Memory

```asm
    ; Allocate 64 bytes, zero-initialize
    INVOKE  _HeapAlloc, hMyHeap, #HEAP_ZERO_MEMORY, #64
    tst.l   d0
    beq     alloc_failed
    move.l  d0,pBuffer

    ; Grow to 128 bytes
    INVOKE  _HeapReAlloc, hMyHeap, #0, pBuffer, #128
    tst.l   d0
    beq     realloc_failed
    move.l  d0,pBuffer

    ; Query size
    INVOKE  _HeapSize, hMyHeap, pBuffer  ; D0 = 128

    ; Free
    INVOKE  _HeapFree, hMyHeap, pBuffer
```

**Ownership**: always free a block to the same heap it was allocated from. Passing a block from heap A to `_HeapFree` with heap B's handle will be detected (heap ID mismatch) and result in `HEAP_ERROR_HANDLE_BLOCK_MISMATCH`.

**NULL free**: `_HeapFree` returns success for NULL only after the supplied
heap passes its configured validation.

### 7.4 Heap Enumeration

```asm
    clr.l   HeapEntry           ; *pEntry = NULL to begin
walk_loop:
    INVOKE  _HeapWalk, hMyHeap, #HeapEntry
    tst.l   d0
    beq.s   walk_done

    move.l  HeapEntry,a0        ; A0 = raw block header
    lea     bhData(a0),a1       ; A1 = user data pointer
    btst.b  #FLG_FREE_BIT,bhFlags+3(a0)
    bne.s   walk_loop           ; Skip free blocks if desired
    ; process the block at A1, size = bhRequestSize(a0)
    bra.s   walk_loop

walk_done:
    jsr     _HeapGetError       ; Declare extern _HeapGetError in this source
    cmpi.l  #HEAP_ERROR_NO_MORE_ITEMS,d0
    bne     handle_walk_error
```

### 7.5 Debugging with Heap Flags

**Recommended debug configuration**:
```asm
DEBUG_FLAGS equ (HEAP_ENABLE_DEBUG_FILL or HEAP_TAIL_CHECKING_ENABLED or HEAP_VALIDATE_PARAMETERS)
```

- `HEAP_ENABLE_DEBUG_FILL`: allocated memory is `$CD`, freed memory is `$BAADF00D`. References to uninitialized or freed memory produce distinctive data patterns.
- `HEAP_TAIL_CHECKING_ENABLED`: `$ABABABAB` pattern is written past the end of each allocation. Buffer overruns are detected on the subsequent `_HeapFree`.
- `HEAP_VALIDATE_PARAMETERS`: lightweight handle check on every call, negligible overhead.
- `HEAP_FREE_CHECKING_ENABLED`: full block-chain and free-chain walk on every `_HeapFree`. Moderate overhead.
- `HEAP_VALIDATE_ALL_ENABLED`: full validation on every API call. Use only for targeted corruption hunting; overhead is O(n) per call.

### 7.6 Using INVOKE with the Heap API

`heap.inc` declares PROTO entries for the 13 stack-parameter public APIs.
Sources including it can use `INVOKE` to check argument counts and generate
stack setup. `_HeapGetError` is the exception: declare it `extern` and use `jsr`.

```asm
    include heap.inc

    INVOKE  _HeapCreate, #HEAP_ENABLE_DEBUG_FILL, #4096
    INVOKE  _HeapAlloc,  hHeap, #0, #sizeof_MY_STRUCT
    INVOKE  _HeapFree,   hHeap, pMem
```

Parameters are pushed right-to-left. The assembler validates the parameter count against the PROTO declaration.

---

## 8. Design Notes

**Why segregated free lists?** Bucket selection avoids scanning irrelevant
smaller free blocks. Finding a fit is still a first-fit linear search within
the selected and larger buckets; no constant-time or best-fit guarantee is
made for regular allocations.

**Why ten buckets with these thresholds?** The thresholds (64, 128, 256, 512, 1024, 4096, 16384, 65536, 262144 bytes) cover the typical allocation size distribution in embedded applications. Smaller allocations cluster tightly in buckets 0–4; large I/O or filesystem buffers fall in 5–8; heap creation blocks fall in 9.

**LIFO insertion**: new free blocks are inserted at the head of their bucket chain. This improves cache locality (recently freed blocks are reused first) at the cost of not being a strict best-fit allocator within a bucket.

**Block size alignment to `BLK_HDR_SIZE`**: regular blocks use 32-byte
granularity. Allocation and shrink splits require leftover >32 bytes; the
in-place realloc-grow split accepts a 32-byte header-only remainder. A
zero-length request can also produce a header-only allocated block. Neither
case grants writable bytes through a zero-length data pointer.

**Heap IDs**: the 16-bit counter is incremented at each heap creation,
including machine-heap initialization. Ownership comparison is constant-time.
IDs wrap after 65,536 creations; reuse is not detected or prevented.

**Private heap as parent allocation**: destroying a private heap returns its
containing machine-heap allocation with one `_HeapFree` call, after
invalidating its metadata. Each private heap needs contiguous parent storage;
very small ones may be SOA-backed as described in §5.2.

**Register conventions**: D0/D1/A0/A1 are caller-saved; D2–D7/A2–A6 are
callee-saved. Many public routines preserve additional registers through
`USES`. D0 is a return register for most APIs, but is deliberately in the
`USES` lists of both public validators and the automatic-validation helper.
`PROC`/`ENDP` generate stack frames and preserve CCR across register restore.

---

## 9. Limitations and Known Issues

1. **Single-threaded**: there is no locking of any kind. The heap is not safe for concurrent access from multiple 68K contexts (interrupt handlers, multi-tasking). Any caller using the heap from an interrupt routine that may preempt another heap call must disable interrupts for the duration.

2. **Fixed-size heaps**: neither the machine heap nor any private heap can grow beyond its initial size. There is no mechanism to extend a heap, merge multiple heaps, or request additional memory from an OS when the heap is exhausted. The only recourse on `HEAP_ERROR_OUT_OF_MEMORY` is to compact (which may reveal previously fragmented free space) or to fail.

3. **First-fit, not best-fit**: all regular free buckets use first-fit scans,
   which can increase fragmentation for some allocation patterns.

4. **Heap ID wrap-around**: `__HeapId` is a 16-bit counter with no overflow
   detection. It wraps after 65,536 creations, allowing an ID to be reused.
   The ID comparison is not protection against arbitrary stale or forged pointers.

5. **`_HeapWalk` pointer type**: the `pEntry` parameter to `_HeapWalk` stores raw block header addresses, not data pointers. Callers must add `BLK_HDR_SIZE` to get a user pointer. This is unintuitive and differs from the Windows `HeapWalk` convention, where `PROCESS_HEAP_ENTRY` carries both.

6. **`_HeapDestroy` does not drain**: destroying a private heap without first freeing its individual allocations is silent and intentional, but it leaks any state those allocations represented (open file handles, sub-objects, etc.). There is no notification mechanism.

7. **Machine heap cannot be destroyed**: `_MachineHeapInitialize` can be called only once per session. There is no corresponding `_MachineHeapDestroy`. Reclaiming the machine heap's memory requires system reset or process exit.

8. **Tail-check granularity**: the tail guard (`$ABABABAB`) is written in full longword units from `round_up(bhRequestSize, 4)` to the end of the data area. A 1-, 2-, or 3-byte overrun that stays within the last partial longword of user data will not be caught because it does not reach the first tail longword.

9. **`HEAP_TRAP_ON_ERROR` not implemented**: the flag bit is defined and documented but the implementation does not currently issue a `TRAP` instruction on detecting corruption. It is reserved for a future enhancement.

10. **Tagging not implemented**: `FLG_HEAP_ENABLE_TAGGING` and its mask
    `HEAP_ALLOCATION_TAGGING_ENABLED` are defined but assign no allocation tags.

11. **`ar.exe` wildcard limitation on Windows**: `cmd.exe` and PowerShell do not expand wildcards for native executables, so archive commands must supply an explicit object-file list. Both makefiles supply that list when building `libheap.a`.

12. **`GetMachineHeaps` heuristic detection**: matching regular user data can
    produce false positives, and tiny SOA-backed private heaps are missed.
    For count-only queries use `(0, NULL)`, not NULL with nonzero capacity (§5.13).

13. **Caller-owned memory and pointer validity**: initialization requires
    rounded usable bytes **plus 128 bytes of metadata** and any leading
    alignment loss. It does not bounds-check the supplied region. Handle,
    block, and SOA recognition checks are not safe reads of arbitrary memory.

14. **SOA introspection is not the regular-block API**: `_HeapWalk` does not
    enumerate cells; `_HeapValidate(hHeap, cell)` is unsupported; `_HeapSize`
    does not establish that a recognized cell is still allocated. Use live
    pointers and whole-heap validation, and use internal tooling helpers only
    with their preconditions satisfied.

15. **Debug shrink can damage retained bytes**: shrinking a regular block to
    a non-longword size with debug fill enabled can poison bytes still inside
    the new request (§5.6). This remains an implementation limitation.

---

## 10. Possible Future Enhancements

1. **Heap extension / overflow policy**: add a callback or a linked list of heap segments so that a heap can grow on demand. When the primary block is exhausted, a new segment is allocated (from the machine heap or from a lower-level allocator) and linked into the heap's segment chain.

2. **Best-fit within bucket 9**: replace the first-fit scan of the overflow bucket with a sorted insert (by size) so that the closest-fit block is always returned for large requests, reducing internal fragmentation.

3. **Thread safety**: add caller-supplied critical-section hooks. A
   supervisor-mode interrupt-masking wrapper would need to save and restore
   the original SR; interrupt masking alone is not a general multitasking lock.

4. **`HEAP_TRAP_ON_ERROR` implementation**: on corruption detect, push a diagnostic longword (error code) and execute `TRAP #15` (or a configurable trap vector) so that a debugger or monitor can catch the violation with full register context intact.

5. **Allocation tagging** (`HEAP_ALLOCATION_TAGGING_ENABLED`): define
   separate tag storage without overwriting the ownership ID. Tag-based
   statistics could then identify which subsystem consumes memory.

6. **`_HeapWalk` data pointer**: return a struct (or two pointers) from `_HeapWalk` — one for the raw header (internal use) and one for the user data area — to match the ergonomics of the Windows `HeapWalk` / `PROCESS_HEAP_ENTRY` convention and eliminate the need for callers to add `BLK_HDR_SIZE` manually.

7. **Heap ID overflow protection**: change `__HeapId` to a 32-bit counter and mask only the upper 16 bits into the flags field, or wrap the counter with a check and reserve ID zero as an invalid sentinel.

8. **`_MachineHeapDestroy`**: a counterpart to `_MachineHeapInitialize` that zeroes `__MachineHeapHandle` and optionally scrubs the heap memory. This would allow unit-test harnesses to re-initialize the heap between test cases without restarting the process.

9. **Free-block ordering within buckets**: evaluate size/address ordering
   against insertion cost and fragmentation. Adjacent nodes in one size
   bucket are not necessarily physically adjacent; the existing physical
   chain remains necessary for reliable coalescing.

10. **`_HeapCompact` return value for data area**: currently `_HeapCompact` returns the largest free block's *total* size minus `BLK_HDR_SIZE`. Returning both the total and the usable size (accounting for tail-guard space) would give callers a more accurate picture of the maximum allocation they can make.

11. **Heap serialization / snapshot**: an API to dump the complete heap state (header, all block headers, free lists) to a linear buffer, suitable for crash dump analysis or heap state transfer across a reset.

> **Implemented:** small-object size classes (§2.7) eliminate per-cell block
> headers and regular block splitting. Request-to-class rounding, partially
> occupied slabs, and shared metadata still consume space; there is no universal
> footprint-reduction factor for every small workload.
