# Heap API Reference

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
- **Segregated free lists**: ten size-class buckets provide O(1) best-fit allocation for the common case without requiring a full scan of all free blocks.
- **Block coalescing**: adjacent free blocks are merged on `HeapFree` (unless disabled) to control long-term fragmentation.
- **In-place reallocation**: `HeapReAlloc` first attempts to grow or shrink a block without moving it by consuming or releasing the adjacent free block.
- **Configurable debug instrumentation**: each heap can independently enable debug fill patterns, buffer-overrun tail guards, free-check validation, parameter validation, and full per-call validation.
- **Heap identity**: every heap and every block carries a 16-bit ID in the high word of their flags field so cross-heap frees are detected at runtime.
- **Portable calling convention**: all functions use the 68K stack for parameters and return values in D0; registers are preserved according to the 68K ABI (`PROC`/`ENDP` with explicit `USES` lists).

The implementation lives in `src/` and is split across individual `.a68` source files, one per function, assembled to ELF object files and linked into `out/lib/libheap.a`. Public constants, structures, and API prototypes are in `src/heap.inc`, copied to `out/include/heap.inc` when built. Library objects and listings are placed in `out/lib/`; test objects, listings, and executables are placed in `out/bin/`. The entire `out/` directory is excluded from Git.

ELF is the only supported object format. Build with [makefile](../makefile)
on Windows or [makefile.macos](../makefile.macos) on macOS.

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
│  • reserved                       │
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

All allocation units are aligned to `BLK_HDR_SIZE` (= `$20`, 32 bytes). The upper byte of any valid heap or block address is always zero (upper byte of the 32-bit address space is reserved for metadata detection); a non-zero upper byte is treated as corruption.

### 2.2 Heap Header

Defined at offset 0 from the heap handle. Size: `HEAP_HDR_SIZE` = `$40` (64 bytes).

| Offset | Symbol | Size | Description |
|--------|--------|------|-------------|
| `$00` | `hhMagic` | long | Magic number `'HEAP'` (`$48454150`) |
| `$04` (lo word) | `hhFlags` | word | Configuration flags (see §3) |
| `$04` (hi word) | `hhId` | word | Heap ID (monotonically assigned on creation) |
| `$08` | `hhRequestSize` | long | Size passed to `_MachineHeapInitialize` or `_HeapCreate` |
| `$0C` | `hhSize` | long | Actual total heap size including all headers |
| `$10` | `hhHeapHead` | long | Pointer to first block in the physical block chain |
| `$14`–`$38` | `hhFreeHead0`–`hhFreeHead9` | 10 × long | Segregated free-list heads (one per size bucket) |
| `$3C` | `hhSmallPool` | long | Pointer to this heap's Small Object Allocator control block (SCB), or NULL until first small allocation (§2.7). Zeroed on creation. Formerly `hhReserved`. |

The heap handle returned by `_MachineHeapInitialize` and `_HeapCreate` is a pointer to this structure.

### 2.3 Block Header

Every allocated or free block begins with a header immediately before the data area. Size: `BLK_HDR_SIZE` = `$20` (32 bytes). The user-visible pointer returned by `_HeapAlloc` points to the byte at offset `$20` from the block header (the `bhData` offset).

| Offset | Symbol | Size | Description |
|--------|--------|------|-------------|
| `$00` | `bhMagic` | long | Magic number `'BLKH'` (`$424C4B48`) |
| `$04` (lo word) | `bhFlags` | word | Block status flags (`FLG_FREE`, `FLG_GARBAGE`) |
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
| 1 | `FLG_GARBAGE` | Block is being coalesced (transient) |

The physical block chain is a doubly-linked list in address order. The forward link in each block is always `bhPrev(next_block)` — that is, `bhNext` of block N points to the first byte of block N+1's header, and `bhNext - bhPrev` of that block equals `bhSize` of block N.

### 2.4 End-of-Heap Marker

The last `BLK_HDR_SIZE` bytes of every heap (including the machine heap) are filled with the longword `'PAEH'` (`$50414548`). `_HeapValidate` checks that the marker is intact and sits exactly where the block chain arithmetic predicts. The end marker is not part of the block chain (`bhNext` of the last real block is NULL).

### 2.5 Segregated Free Lists

Ten singly-typed doubly-linked free lists are maintained, indexed by the data-area size of the free block:

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

`__HeapGetBucketOffset` maps a data-area size to the byte offset of the correct `hhFreeHeadN` field. All insertions are LIFO (new head of bucket). Allocation starts in the smallest sufficient bucket and walks upward until a fitting block is found or all buckets are exhausted.

Bucket 9 is an overflow bucket for very large blocks. Because all blocks in bucket 9 are larger than 256 KB, the allocator must do a linear scan within that bucket; it finds the first block that is large enough (first-fit, not best-fit) for oversized requests.

### 2.6 Global Data

Three longword variables live in `HeapData.a68`:

| Symbol | Description |
|--------|-------------|
| `__HeapId` (word) | Next heap ID counter. Incremented each time a new heap is created. The full longword is read to OR the ID into flags fields. |
| `__MachineHeapHandle` | Pointer to the machine heap header, or NULL before initialization. |
| `__HeapError` | Last error code set by any heap API function. |

---

### 2.7 Small Object Allocator (SOA)

Small requests are expensive for the block allocator: every allocation carries a
32-byte header and is rounded up to a 32-byte boundary, so a 1-byte request costs a
64-byte footprint. The **Small Object Allocator** is a slab/segregated-fit sub-allocator
layered on top of the block allocator to serve small requests densely. It is **on by
default**; opt out per heap (or per call) with `FLG_HEAP_DISABLE_SMALL_POOL`.

**Routing.** `_HeapAlloc` sends a request to the SOA when *all* of the following hold:
`1 ≤ lBytes ≤ SOA_MAX` (256), the heap does **not** have `FLG_HEAP_DISABLE_SMALL_POOL`
set, the call does not pass that flag, and the heap does **not** have
`FLG_HEAP_ENABLE_TAIL_CHECK` set (tail checking needs the block path's guard band). If
the SOA cannot satisfy the request (its parent heap is exhausted), `_HeapAlloc` falls
back to the block path transparently.

**Size classes.** A request maps to one of 16 size classes:
`8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256` bytes. A cell is
the class size (≥ the request); there is no per-block header, so overhead is a fraction
of a bit-per-cell of slab metadata.

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
longword output. Failure returns zero with an explicit heap error and leaves
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
- **`_HeapFree` / `_HeapReAlloc`.** Recognize and handle cells transparently; a cell
  freed to the wrong heap is reported as `HEAP_ERROR_HANDLE_BLOCK_MISMATCH`, and a
  repeat free as `HEAP_ERROR_DOUBLE_FREE`.
- **Debugging.** `_HeapValidate` deep-checks the SOA; `_HeapCompact` releases any empty
  slabs/arenas. The internal `__HeapSoaWalk` enumerates live cells for tooling.

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

Flags passed to `_HeapAlloc`, `_HeapReAlloc`, etc. at call time override the corresponding heap-level flags for that call only. The heap-level flags persist across calls.

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

**Purpose**: Creates the machine (system) heap in a caller-supplied block of memory. Must be called exactly once before any other heap API.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `lOptions` | Heap flags (see §3). May be 0 or any combination of flag mask constants. |
| `lStart` | Address of the first byte available for the heap. The implementation rounds this up to the next `BLK_HDR_SIZE` boundary internally. |
| `lSize` | Requested heap size in bytes. |

**Return value**: D0 = heap handle on success, NULL on failure. Call `_HeapGetError` on failure.

**Errors**: `HEAP_ERROR_INITIALIZED` if called a second time.

**Design notes**: The function aligns `lStart` up to a `BLK_HDR_SIZE` boundary, then lays out: heap header → one large free block → end-of-heap marker. The free block is placed into the appropriate size bucket. If `FLG_HEAP_ENABLE_DEBUG_FILL` is set, the entire data area of the initial free block is filled with `$BAADF00D`. The new heap receives the current `__HeapId` value in the high word of its flags; `__HeapId` is then incremented. The handle is stored in `__MachineHeapHandle`.

---

### 5.2 `_HeapCreate`

```
PROTO  , lOptions:DWORD, lSize:DWORD
```

**Purpose**: Creates a private heap by allocating a block from the machine heap large enough to hold `lSize` bytes plus heap and block header overhead, then initializing it as an independent heap.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `lOptions` | Heap flags for the new private heap. Independent of the machine heap's flags. |
| `lSize` | Requested usable heap size in bytes. |

**Return value**: D0 = handle to the new private heap on success, NULL on failure.

**Errors**: `HEAP_ERROR_NOT_INITIALIZED` if the machine heap has not been created. `HEAP_ERROR_OUT_OF_MEMORY` if the machine heap cannot satisfy the allocation. The machine heap's configured validation flags are applied before allocating.

**Design notes**: The private heap is entirely contained in a single block allocated from the machine heap. Its internal layout (header, free block, end marker) is identical to the machine heap. Because the private heap is just a machine-heap block, destroying it (`_HeapDestroy`) is equivalent to freeing that block. Private heaps receive their own unique heap ID and their own set of configuration flags.

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

**Errors**: `HEAP_ERROR_NOT_INITIALIZED` if the machine heap does not exist. `HEAP_ERROR_INVALID_HANDLE` if `hHeap` is NULL or is the machine heap handle. `HEAP_ERROR_INVALID_BLOCK` if `_HeapFree` fails internally.

**Design notes**: Before freeing the block, the heap header is zeroed longword-by-longword to invalidate any stale handles held by the caller. All outstanding allocations within the private heap are implicitly discarded — there is no drain or destructor mechanism. It is not possible to destroy the machine heap.

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
| `lFlags` | Per-call flags. Currently only `HEAP_ZERO_MEMORY` is honoured (overrides heap-level zero flag). |
| `lBytes` | Number of bytes to allocate. |

**Return value**: D0 = pointer to the allocated data area on success, NULL on failure.

**Errors**: `HEAP_ERROR_OUT_OF_MEMORY` if no sufficiently large free block exists.

**Small Object Allocator**: When routing conditions are met (`1 ≤ lBytes ≤ 256`, small
pool not disabled on the heap or the call, tail checking off), the request is served by
the SOA as an 8-byte-aligned cell instead of a 32-byte block (§2.7). On SOA exhaustion
of the parent heap, allocation falls back to the block algorithm below.

**Allocation algorithm** (block path):

1. Run `__HeapAutoValidateFlagCheck` per the heap's flags.
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
| `pMem` | Pointer returned by `_HeapAlloc` or `_HeapReAlloc`. NULL is silently ignored (returns success). |

**Return value**: D0 = non-zero (TRUE) on success, zero (FALSE) on failure.

**Errors**: `HEAP_ERROR_INVALID_BLOCK` if the pointer is not a valid, allocated heap block. `HEAP_ERROR_HANDLE_BLOCK_MISMATCH` if the block's heap ID does not match `hHeap`. `HEAP_ERROR_TAIL_VALIDATION_FAILED` if tail guard bytes are corrupt.

**Free algorithm**:

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
| `lFlags` | `HEAP_ZERO_MEMORY` (zero newly added bytes on growth), `HEAP_REALLOC_IN_PLACE_ONLY` (fail rather than move). Per-call overrides of heap flags. |
| `pMem` | Existing allocation pointer. Must not be NULL. |
| `lBytes` | New requested size in bytes. |

**Return value**: D0 = pointer to the (possibly relocated) data area on success, NULL on failure. On failure, the original block is untouched and valid.

**Errors**: `HEAP_ERROR_INVALID_BLOCK` if `pMem` is invalid. `HEAP_ERROR_HANDLE_BLOCK_MISMATCH` if the block is not owned by `hHeap`. `HEAP_ERROR_OUT_OF_MEMORY` if in-place growth failed and `HEAP_REALLOC_IN_PLACE_ONLY` was specified, or if `_HeapAlloc` failed on relocation.

**Realloc algorithm**:

1. Validate `pMem` (alignment, magic, not free, heap ID).
2. Compute required total block size `D1` (same rounding as `_HeapAlloc`).
3. Compare `D1` to current `bhSize`:
   - **Equal**: update `bhRequestSize` only (tail guard is rewritten if tail-checking is enabled).
   - **Grow** (`D1 > bhSize`):
     - Check if `bhNext` is free and large enough.
       - If so and splitting is worthwhile: take only what is needed from the free block, insert the remainder as a new free block, invalidate the old free block header.
       - If so but splitting not worthwhile: consume the entire next block — unlink it from both free and block chains, absorb its size into the current block.
     - If in-place growth is impossible: check `HEAP_REALLOC_IN_PLACE_ONLY`; if set, fail. Otherwise allocate new block, copy `bhRequestSize` bytes, free original.
     - On in-place growth, fill newly added bytes with debug pattern or zero as configured.
   - **Shrink** (`D1 < bhSize`):
     - If leftover ≥ `BLK_HDR_SIZE`: split a new free block from the tail, insert it into the correct bucket, optionally coalesce with successor.
     - If leftover < `BLK_HDR_SIZE`: keep the block at its current size (internal fragmentation).
     - Debug-fill surrendered bytes if enabled.
   - In all cases, rewrite tail guard at the new position if tail-checking is enabled.
4. Return pointer to data area.

**On relocation**: The original block's requested size is used as the copy length, guaranteeing that no uninitialized data is propagated. If `_HeapFree` fails after a successful copy (a degenerate internal consistency failure), the error is cleared so the caller receives the valid new pointer.

---

### 5.7 `_HeapSize`

```
PROTO  , hHeap:DWORD, pMem:DWORD
```

**Purpose**: Returns the originally requested size of a heap allocation.

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

**Purpose**: Returns the size of the largest contiguous free block in the heap. If `FLG_HEAP_DISABLE_COALESCING` is set, also coalesces all adjacent free blocks before scanning.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `hHeap` | Heap to compact. |

**Return value**: D0 = data-area size (bytes) of the largest free block, or zero if the heap is fully allocated (in which case `_HeapGetError` returns `HEAP_ERROR_SUCCESS`). Zero is also returned on validation failure.

**Design notes**: When coalescing is normally enabled, free blocks are already coalesced on every `_HeapFree`, so this call only performs the scan. When `FLG_HEAP_DISABLE_COALESCING` is set, the function first walks all ten buckets and calls `__HeapCoalesce` on each free block; it restarts each bucket's walk after any successful coalesce (because the block may have moved to a larger bucket). The returned size excludes the `BLK_HDR_SIZE` overhead.

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
| `pBlock` | If NULL, validate the entire heap. If non-NULL, validate only this block (a data-area pointer). |

**Return value**: D0 = zero (Z flag set) on success, non-zero error code on failure. `__HeapError` is updated in both cases.

**Single-block validation**:
- Alignment and magic check.
- Heap ID ownership check.
- Linear walk of the block chain to confirm the block is physically present in this heap.
- Back-link (`bhPrev`) consistency: `bhPrev(this)->bhNext == this`.
- Forward-link (`bhNext`) consistency: `bhNext(this)->bhPrev == this`.
- If free: free-chain back-link and forward-link consistency.

**Full-heap validation**:
1. Walk the physical block chain from `hhHeapHead`. For each block: alignment, magic, back-link, and computed forward-link (address + `bhSize` must equal `bhNext`).
2. At chain end: verify end-of-heap magic and that the computed address matches.
3. Walk all ten free-list buckets. For each block in a bucket: free-chain back-link consistency, and that the block has `FLG_FREE` set.
4. If no free blocks were found in any bucket (heap fully allocated): walk the physical chain and confirm no block has `FLG_FREE` set and no stale `bhFreePrev`/`bhFreeNext` pointers.

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

**Return value**: Z flag set on success (D0 = 0). Z flag clear (D0 = error code) on failure. `__HeapError` is updated on failure.

**Checks performed**:
- Handle not NULL.
- Lower bits zero, upper byte zero (aligned, valid address range).
- `hhMagic == 'HEAP'`.
- `hhSize` is consistent with `hhRequestSize` (using the same alignment arithmetic applied during creation).
- `hhHeapHead` points to a block with magic `'BLKH'`.
- Every non-NULL `hhFreeHeadN` pointer points to a block with magic `'BLKH'`.

All registers are preserved.

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

**Usage pattern**:
```asm
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

**Purpose**: Returns the count of active heaps and fills a caller-supplied array with their handles.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `NumHeaps` | Capacity of the `pHeaps` array, in handles. Pass 0 to query the count only. |
| `pHeaps` | Pointer to a longword array to receive the handles. Pass NULL to query the count only. |

**Return value**: D0 = total number of active heaps (machine heap + all private heaps). If D0 > `NumHeaps`, the supplied buffer was too small; the caller should allocate `D0 × 4` bytes and call again.

**Design notes**: The function walks the machine heap block chain looking for allocated blocks whose data area begins with `'HEAP'`. This requires that private heap headers not be modified between `_HeapCreate` and enumeration. The machine heap handle is always the first entry in the output array.

---

### 5.14 `_HeapGetError`

**Prototype**: No PROTO (leaf function, no frame). Call with `jsr _HeapGetError`.

**Purpose**: Returns the last error code set by any heap API function.

**Return value**: D0 = `__HeapError`.

**Notes**: `__HeapError` is set at the start of most API functions (cleared to `HEAP_ERROR_SUCCESS`) and updated on any error path. `_HeapGetError` is a pure leaf: one `move.l __HeapError,d0` and `rts`. It does not clear the error; the next API call will clear it.

---

## 6. Internal Functions

These functions are not part of the public API. They are used by the heap implementation itself. Their prototypes are declared in `heap.inc` with double-underscore prefix.

### 6.1 `__HeapAutoValidateFlagCheck`

```
PROTO  , hHeap:DWORD, fFree:DWORD
```

Dispatches automatic validation based on the heap's configuration flags. Called at the entry of every allocating/freeing API function. The `fFree` parameter is non-zero when the caller is `_HeapFree`, which activates `FLG_HEAP_ENABLE_FREE_CHECK`.

- If `FLG_HEAP_VALIDATE_ALL`: calls `_HeapValidate(hHeap, 0)`.
- Else if `FLG_HEAP_ENABLE_FREE_CHECK` and `fFree != 0`: calls `_HeapValidate(hHeap, 0)`.
- Else if `FLG_HEAP_VALIDATE_PARAMETERS`: calls `_HeapValidateHandle(hHeap)`.
- Otherwise: does nothing (Z=1 = success).

Returns with Z=1 on success (no validation or validation passed) and Z=0 on failure. All registers are preserved by the `PROC USES d0/a0` frame; the Z flag from the final `MOVEM.L (SP)+` is preserved.

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
; Output: D0.l = byte offset of hhFreeHeadN within the heap header
```

Maps a data-area size to the byte offset of the correct `hhFreeHeadN` field using a sequence of `cmpi.l` / `ble.s` branches. Returns offsets 0, 4, 8, 12, 16, 20, 24, 28, 32, or 36 for buckets 0–9. Trashes CCR only.

### 6.6 `__HeapDebugFillOnFree`

```
PROTO  , pBlock:DWORD
```

Fills the data area of a block with `$BAADF00D`. Called by `_HeapFree` and `__HeapCoalesce` when `FLG_HEAP_ENABLE_DEBUG_FILL` is set. `pBlock` is a block header pointer (not a user pointer). Uses the `bhSize - BLK_HDR_SIZE` data area size as the fill count.

### 6.7 `__HeapInvalidateBlockHeader`

```
PROTO  , hHeap:DWORD, pBlock:DWORD
```

Zeroes the header of a block that has been absorbed by coalescing, preventing use of a stale pointer to the now-defunct block from appearing valid (magic number check would fail). Used after `__HeapUnlinkFromBlockChain` in all coalescing and consume-next-block paths.

---

## 7. Usage Guide

### 7.1 Initialization Sequence

The machine heap must be initialized before any other heap API is called. The typical sequence in a 68K CPM or bare-metal environment:

```asm
    ; Compute heap start and size from the base page or system state
    move.l  bsstart(a0),d2      ; End of BSS
    add.l   bslen(a0),d2        ; D2 = first byte after BSS
    move.l  hightpa(a0),d1      ; Top of TPA
    sub.l   d2,d1               ; D1 = available bytes
    subi.l  #STKSIZE,d1         ; Reserve space for stack

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

All allocations within a private heap are freed atomically when the heap is destroyed, with no need to free individual blocks first.

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

**NULL free**: `_HeapFree` silently returns success if `pMem` is NULL.

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
    INVOKE  _HeapGetError
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

`heap.inc` declares PROTO entries for all public API functions. Any source file that includes `heap.inc` can use `INVOKE` for type-checked calls without writing explicit stack setup:

```asm
    include heap.inc

    INVOKE  _HeapCreate, #HEAP_ENABLE_DEBUG_FILL, #4096
    INVOKE  _HeapAlloc,  hHeap, #0, #sizeof_MY_STRUCT
    INVOKE  _HeapFree,   hHeap, pMem
```

Parameters are pushed right-to-left. The assembler validates the parameter count against the PROTO declaration.

---

## 8. Design Notes

**Why segregated free lists?** A single free list requires O(n) allocation time as the heap fills. Segregated free lists bring common-case allocation close to O(1): the correct bucket is computed in constant time by `__HeapGetBucketOffset`, and within a bucket the first block is almost always a match. Bucket 9 (oversized blocks) retains O(k) behaviour where k is the number of blocks in that bucket.

**Why ten buckets with these thresholds?** The thresholds (64, 128, 256, 512, 1024, 4096, 16384, 65536, 262144 bytes) cover the typical allocation size distribution in embedded applications. Smaller allocations cluster tightly in buckets 0–4; large I/O or filesystem buffers fall in 5–8; heap creation blocks fall in 9.

**LIFO insertion**: new free blocks are inserted at the head of their bucket chain. This improves cache locality (recently freed blocks are reused first) at the cost of not being a strict best-fit allocator within a bucket.

**Block size alignment to `BLK_HDR_SIZE`**: with a minimum block granularity of 32 bytes, there is never a free block too small to hold a block header. The split threshold (`leftover > BLK_HDR_SIZE`) ensures that splitting never creates a header-only block with no data area.

**Heap IDs**: the 16-bit heap ID in the high word of `hhFlags`/`bhFlags` is assigned monotonically from `__HeapId` at heap creation time. Cross-heap block ownership is detected at O(1) with a simple mask-and-compare. The ID is never reused within a session; if `__HeapId` wraps (after 65 535 heaps), an old heap could theoretically receive the same ID as a new one — this is not guarded against.

**Private heap as machine-heap block**: nesting private heaps inside the machine heap means that destroying a private heap is a single `_HeapFree` call. The downside is that the machine heap must be large enough to accommodate all private heaps simultaneously as contiguous blocks, which limits the total number and aggregate size of private heaps.

**Register conventions**: all `PROC` functions use `USES` to save and restore only the registers they modify. D0 is always the return value register and is never listed in `USES`. The stack frame is generated by `PROC`/`ENDP`; parameters are accessed by name using `LINK`-relative addressing.

---

## 9. Limitations and Known Issues

1. **Single-threaded**: there is no locking of any kind. The heap is not safe for concurrent access from multiple 68K contexts (interrupt handlers, multi-tasking). Any caller using the heap from an interrupt routine that may preempt another heap call must disable interrupts for the duration.

2. **Fixed-size heaps**: neither the machine heap nor any private heap can grow beyond its initial size. There is no mechanism to extend a heap, merge multiple heaps, or request additional memory from an OS when the heap is exhausted. The only recourse on `HEAP_ERROR_OUT_OF_MEMORY` is to compact (which may reveal previously fragmented free space) or to fail.

3. **No large-block best-fit**: within bucket 9 (blocks > 256 KB) the allocator uses first-fit rather than best-fit, which can increase fragmentation when many oversized blocks are in use simultaneously.

4. **Heap ID wrap-around**: `__HeapId` is a 16-bit counter with no overflow detection. After 65 535 heaps have been created across the lifetime of the process, the ID will wrap and a new heap could share an ID with an older one that was destroyed. This allows a freed block from the old heap to pass the ownership check against the new heap.

5. **`_HeapWalk` pointer type**: the `pEntry` parameter to `_HeapWalk` stores raw block header addresses, not data pointers. Callers must add `BLK_HDR_SIZE` to get a user pointer. This is unintuitive and differs from the Windows `HeapWalk` convention, where `PROCESS_HEAP_ENTRY` carries both.

6. **`_HeapDestroy` does not drain**: destroying a private heap without first freeing its individual allocations is silent and intentional, but it leaks any state those allocations represented (open file handles, sub-objects, etc.). There is no notification mechanism.

7. **Machine heap cannot be destroyed**: `_MachineHeapInitialize` can be called only once per session. There is no corresponding `_MachineHeapDestroy`. Reclaiming the machine heap's memory requires system reset or process exit.

8. **Tail-check granularity**: the tail guard (`$ABABABAB`) is written in full longword units from `round_up(bhRequestSize, 4)` to the end of the data area. A 1-, 2-, or 3-byte overrun that stays within the last partial longword of user data will not be caught because it does not reach the first tail longword.

9. **`HEAP_TRAP_ON_ERROR` not implemented**: the flag bit is defined and documented but the implementation does not currently issue a `TRAP` instruction on detecting corruption. It is reserved for a future enhancement.

10. **`HEAP_ENABLE_TAGGING` not implemented**: similarly defined but not implemented. No tags are assigned to allocations.

11. **`ar.exe` wildcard limitation on Windows**: `cmd.exe` and PowerShell do not expand wildcards for native executables, so archive commands must supply an explicit object-file list. Both makefiles supply that list when building `libheap.a`.

12. **`GetMachineHeaps` heuristic detection**: `_GetMachineHeaps` detects private heaps by scanning the machine heap block chain for allocated blocks whose first four bytes are `'HEAP'`. If application data happens to begin with those bytes, it will be misidentified as a heap handle.

---

## 10. Possible Future Enhancements

1. **Heap extension / overflow policy**: add a callback or a linked list of heap segments so that a heap can grow on demand. When the primary block is exhausted, a new segment is allocated (from the machine heap or from a lower-level allocator) and linked into the heap's segment chain.

2. **Best-fit within bucket 9**: replace the first-fit scan of the overflow bucket with a sorted insert (by size) so that the closest-fit block is always returned for large requests, reducing internal fragmentation.

3. **Thread safety**: add an optional critical-section mechanism. The heap could hold a pointer to a lock word and a caller-supplied lock/unlock pair. Alternatively, interrupt-disable wrappers could be injected at a compile-time flag, since 68K hardware makes this straightforward with `AND #$F8FF,SR` / `OR #$0700,SR`.

4. **`HEAP_TRAP_ON_ERROR` implementation**: on corruption detect, push a diagnostic longword (error code) and execute `TRAP #15` (or a configurable trap vector) so that a debugger or monitor can catch the violation with full register context intact.

5. **Allocation tagging** (`HEAP_ENABLE_TAGGING`): embed a caller-supplied 16-bit tag in the high word of `bhFlags` (reusing or extending the ID field). Tag-based allocation statistics would allow identification of which subsystem is consuming memory.

6. **`_HeapWalk` data pointer**: return a struct (or two pointers) from `_HeapWalk` — one for the raw header (internal use) and one for the user data area — to match the ergonomics of the Windows `HeapWalk` / `PROCESS_HEAP_ENTRY` convention and eliminate the need for callers to add `BLK_HDR_SIZE` manually.

7. **Heap ID overflow protection**: change `__HeapId` to a 32-bit counter and mask only the upper 16 bits into the flags field, or wrap the counter with a check and reserve ID zero as an invalid sentinel.

8. **`_MachineHeapDestroy`**: a counterpart to `_MachineHeapInitialize` that zeroes `__MachineHeapHandle` and optionally scrubs the heap memory. This would allow unit-test harnesses to re-initialize the heap between test cases without restarting the process.

9. **Free-block ordering within buckets**: change bucket insertion from LIFO to address-ordered (ascending), enabling simple address-based coalescing without needing to walk the physical chain — the predecessor and successor in the free chain would always be adjacent in memory. This trades insertion cost (O(n) scan within bucket) for potentially simpler coalescing paths.

10. **`_HeapCompact` return value for data area**: currently `_HeapCompact` returns the largest free block's *total* size minus `BLK_HDR_SIZE`. Returning both the total and the usable size (accounting for tail-guard space) would give callers a more accurate picture of the maximum allocation they can make.

11. **Heap serialization / snapshot**: an API to dump the complete heap state (header, all block headers, free lists) to a linear buffer, suitable for crash dump analysis or heap state transfer across a reset.

> **Implemented:** *Per-allocation size classes with no internal fragmentation for
> small sizes* — served by the Small Object Allocator (§2.7), which uses dedicated
> slab pools of equal-size cells (8–256 bytes) with no per-cell header, eliminating the
> 32-byte block overhead and split fragmentation for small allocations.
