	.nolist
************************************************************************
*
*  heap.inc : Definitions for the Heap API
*
************************************************************************

************************************************************************
* Heap special values
************************************************************************
HEAP_MAGIC      equ 	'HEAP'			; Heap header magic number markin start of heap.
BLOCK_MAGIC     equ     'BLKH'			; Block header magic number marking start of a block.
HEAP_TAIL       equ 	$abababab		; Guard bytes used with FLG_HEAP_ENABLE_TAIL_CHECK.
HEAP_END        equ     'PAEH'			; Heap magic number signaling end of the heap.
CDCDCDCD 	equ 	$cdcdcdcd 		; Debug fill pattern for allocated blocks.
BAADFOOD        equ     $baadf00d		; Debug fill pattern for freed blocks.
HEAP_ID_MASK	equ 	$ffff0000 		; Mask off flag bits leaving the heap id in upper word.

************************************************************************
* Heap Constants
************************************************************************
HEAP_TAIL_SIZE 	equ 	$20 			; Number of bytes reserved for buffer overrun detection.

************************************************************************
* Heap Header structure definition
************************************************************************
hhMagic	        equ	$00             	; Heap Header magic number.
hhFlags	        equ	$04             	; Heap configuration flags (loword).
hhId 		equ 	$04 			; Heap ID (hiword)
hhRequestSize   equ     $08             	; Requested heap size
hhSize	        equ	$0C             	; Total actual size of the heap including the headers
hhHeapHead      equ	$10             	; Pointer to the first block in the heap block list
hhFreeHead0     equ     $14             	; Free list head: data size <=64 bytes
hhFreeHead1     equ     $18             	; Free list head: data size <=128 bytes
hhFreeHead2     equ     $1C             	; Free list head: data size <=256 bytes
hhFreeHead3     equ     $20             	; Free list head: data size <=512 bytes
hhFreeHead4     equ     $24             	; Free list head: data size <=1 KB
hhFreeHead5     equ     $28             	; Free list head: data size <=4 KB
hhFreeHead6     equ     $2C             	; Free list head: data size <=16 KB
hhFreeHead7     equ     $30             	; Free list head: data size <=64 KB
hhFreeHead8     equ     $34             	; Free list head: data size <=256 KB
hhFreeHead9     equ     $38             	; Free list head: data size >256 KB (overflow)
hhReserved      equ     $3C             	; Reserved for future use
HEAP_HDR_SIZE   equ     $40             	; Size of the heap header in bytes
hhHeapData 	equ 	HEAP_HDR_SIZE		; Offset to the start of the heap data area

************************************************************************
* Segregated free list bucket definitions
************************************************************************
HEAP_NUM_FREE_BUCKETS   equ     10      	; Number of segregated free list buckets
HEAP_FREE_BUCKET_BASE   equ     hhFreeHead0	; Offset of first bucket head in heap header
HEAP_FREE_BKT0_MAX      equ     64      	; Bucket 0: data size <=64 bytes
HEAP_FREE_BKT1_MAX      equ     128     	; Bucket 1: data size <=128 bytes
HEAP_FREE_BKT2_MAX      equ     256     	; Bucket 2: data size <=256 bytes
HEAP_FREE_BKT3_MAX      equ     512     	; Bucket 3: data size <=512 bytes
HEAP_FREE_BKT4_MAX      equ     1024    	; Bucket 4: data size <=1 KB
HEAP_FREE_BKT5_MAX      equ     4096    	; Bucket 5: data size <=4 KB
HEAP_FREE_BKT6_MAX      equ     16384   	; Bucket 6: data size <=16 KB
HEAP_FREE_BKT7_MAX      equ     65536   	; Bucket 7: data size <=64 KB
HEAP_FREE_BKT8_MAX      equ     262144  	; Bucket 8: data size <=256 KB
                                        	; Bucket 9: data size >256 KB (overflow, walk required)

************************************************************************
* Heap Header Flag Definitions
************************************************************************
*
*    FLG_HEAP_ZERO_MEMORY : The allocated memory will be initialized
*	to zero.
*
*    FLG_HEAP_REALLOC_IN_PLACE_ONLY : There can be no movement when
*	reallocating a memory block.
*
*    FLG_HEAP_ENABLE_DEBUG_FILL : Fill blocks on allocation and when
*	freed with filler patterns to help debug references to both
*  	uninitialized memory and already freed memory. The flag
*	FLG_HEAP_ZERO_MEMORY is ignored when this is enabled.
*
*    FLG_HEAP_ENABLE_TAIL_CHECK : Checks for buffer overruns when a
*	block is freed. This flag adds a short pattern to the end of
*	each allocation. The heap manager detects the pattern when
*	the block is freed and, if the pattern was modified, the heap
*	manager will return an error or TRAP into the debugger.
*
*    FLG_HEAP_ENABLE_FREE_CHECK : Enable heap free checking.  Validates
*	the heap when a block is freed.
*
*    FLG_HEAP_VALIDATE_PARAMETERS : Enable heap parameter checking.
*	Verifies some aspects of the heap whenever a heap API is called.
*
*    FLG_HEAP_VALIDATE_ALL : Enable heap validation on call. Validates
*	the entire heap each time a heap API is called. To avoid the
*	high overhead resulting from this flag, use the _HeapValidate
*	API at critical junctures, such as when the heap is destroyed.
*	However, this flag is useful for detecting random corruption
*	in a pool.
*
*    FLG_HEAP_ENABLE_TAGGING : Enable heap tagging. Assigns unique tags
*	to heap allocations. You can display the tag by using the !heap
*	debugger extension with the -t parameter.
*
*    FLG_HEAP_DISABLE_COALESCING : Leaves adjacent blocks of heap memory
*	separate when they are freed. By default, the system combines
*	("coalesces") newly freed adjacent blocks into a single block.
*	Combining the blocks takes time, but reduces fragmentation that
*	might force the heap to allocate additional memory when it can't
*	find contiguous memory. This flag is used to test optimizing
*	strategies. It is not used for debugging.
*
*    FLG_HEAP_TRAP_ON_ERROR : If a heap validation error occurs TRAP
*	rather than return an error code.
*
************************************************************************
FLG_HEAP_ZERO_MEMORY 		equ 	0	; The allocated memory will be initialized to zero.
FLG_HEAP_REALLOC_IN_PLACE_ONLY	equ 	1	; There can be no movement when reallocating a memory block.
FLG_HEAP_ENABLE_DEBUG_FILL	equ 	2	; Enable filling blocks with debug data on allocation and free.
FLG_HEAP_ENABLE_TAIL_CHECK	equ	3	; Enable heap tail checking.
FLG_HEAP_ENABLE_FREE_CHECK	equ 	4	; Enable full heap validation on HeapFree only.
FLG_HEAP_VALIDATE_PARAMETERS	equ	5	; Enable limited heap validation on all API calls.
FLG_HEAP_VALIDATE_ALL		equ 	6	; Enable full heap validation on all API calls.
FLG_HEAP_ENABLE_TAGGING		equ 	7	; Enable heap tagging.
FLG_HEAP_DISABLE_COALESCING	equ 	8	; Disable heap coalesce on free.
FLG_HEAP_TRAP_ON_ERROR		equ 	9 	; TRAP rather than return error code on corruption.

HEAP_ZERO_MEMORY 		equ 	1 shl FLG_HEAP_ZERO_MEMORY
HEAP_REALLOC_IN_PLACE_ONLY 	equ 	1 shl FLG_HEAP_REALLOC_IN_PLACE_ONLY
HEAP_ENABLE_DEBUG_FILL		equ 	1 shl FLG_HEAP_ENABLE_DEBUG_FILL
HEAP_TAIL_CHECKING_ENABLED      equ 	1 shl FLG_HEAP_ENABLE_TAIL_CHECK
HEAP_FREE_CHECKING_ENABLED      equ 	1 shl FLG_HEAP_ENABLE_FREE_CHECK
HEAP_VALIDATE_PARAMETERS	equ 	1 shl FLG_HEAP_VALIDATE_PARAMETERS
HEAP_VALIDATE_ALL_ENABLED	equ	1 shl FLG_HEAP_VALIDATE_ALL
HEAP_ALLOCATION_TAGGING_ENABLED	equ	1 shl FLG_HEAP_ENABLE_TAGGING
HEAP_DISABLE_COALESCE_ON_FREE   equ	1 shl FLG_HEAP_DISABLE_COALESCING
HEAP_TRAP_ON_ERROR 		equ	1 shl FLG_HEAP_TRAP_ON_ERROR

************************************************************************
* Heap Allocation Block Header structure definition
************************************************************************
bhMagic         equ     $00             	; Heap Block magic number
bhFlags         equ     $04             	; Block status flags (loword)
bhId 		equ 	$04 			; Heap ID the block is a member of (hiword)
bhRequestSize   equ     $08             	; Requested allocation size
bhSize          equ     $0C             	; Actual size of block including headers
bhPrev          equ     $10             	; Pointer to the previous block
bhNext	        equ 	$14             	; Pointer to the next block
bhFreePrev      equ     $18             	; Pointer to previous free block
bhFreeNext      equ     $1C             	; Pointer to the next free block
bhData	        equ	$20             	; Offset to the start of block data
BLK_HDR_SIZE    equ     $20             	; Size of the block header in bytes

************************************************************************
* Heap Allocation Block Header Flag Definitions
************************************************************************
FLG_FREE_BIT    equ     0               	; Bit # of free flag
FLG_GARBAGE_BIT equ     1               	; Bit # of garbage bit
FLG_FREE        equ     1 shl FLG_FREE_BIT      ; Set if the block is free
FLG_GARBAGE     equ     1 shl FLG_GARBAGE_BIT	; Set during garbage collection

************************************************************************
* Heap End Marker structure definition
************************************************************************
heMagic         equ     $00             	; Offset to the MAGIC Number
HEAP_END_SIZE   equ     BLK_HDR_SIZE    	; Size of the heap end marker in bytes.

************************************************************************
* Small Object Allocator (SOA) definitions - see HEAP_SMALL_ALLOC_DESIGN.md
* Phase 0: definitions only (no behavior yet).
************************************************************************
SOA_MAX         equ     256             	; Max request (bytes) routed to the SOA
SOA_NUM_CLASSES equ     16              	; Number of small size classes
SOA_MIN_CLASS   equ     8               	; Smallest size class / cell alignment
SLAB_SIZE       equ     $1000           	; 4096; slab tile size (power of two)
SLAB_SIZE_MASK  equ     SLAB_SIZE-1     	; Mask to recover slab base from a cell pointer
SLAB_HDR_SIZE   equ     $20             	; 32; slab header (30 bytes) rounded up to a multiple of 8
ARENA_MAX_SLABS equ     32              	; Max tiles per arena (arTileMap is one longword)
ARENA_SLABS_DFLT equ    4               	; Default tiles per new arena; adaptive down to 1 (S4/R9)
SOA_FREE_TAG    equ     $F2EE           	; Double-free guard word stored in a free cell
SOA_NIL_INDEX   equ     $FFFF           	; Free-list end-of-chain sentinel

SCB_MAGIC       equ     'SCB '          	; Small-pool control block magic
AREN_MAGIC      equ     'AREN'          	; Arena descriptor magic
SLAB_MAGIC      equ     'SLAB'          	; Slab header magic

; New heap flag: disable the small-object allocator for a heap.
FLG_HEAP_DISABLE_SMALL_POOL	equ 	10
HEAP_DISABLE_SMALL_POOL		equ 	1 shl FLG_HEAP_DISABLE_SMALL_POOL

; Master build switch: route qualifying _HeapAlloc requests through the SOA.
; Phases 1-5 kept this 0 (opt-in) so the block paths stayed legacy and the SOA
; primitives could be unit-tested directly.  Phase 6 turns it on: the SOA is now
; the default for 1..SOA_MAX-byte requests (opt out per heap with
; HEAP_DISABLE_SMALL_POOL, or per call by passing that flag to _HeapAlloc).
SOA_ROUTE			equ 	1

; The reserved heap-header slot now holds the SOA control block pointer (0 = dormant).
hhSmallPool     equ     hhReserved      	; $3C : ptr to SOA control block

; The 16 size-class values are emitted once as a word table in HeapData.a68:
;   __HeapSoaClassTbl: dc.w 8,16,24,32,40,48,56,64,80,96,112,128,160,192,224,256

************************************************************************
* SOA structures (Phase 1)
************************************************************************
SLAB_SIZE_SHIFT equ     12              	; log2(SLAB_SIZE); SLAB_SIZE = 1 shl this

* --- SOA Control Block (SCB): one per heap, lazily created ---
scbMagic        equ     $00             	; 'SCB ' magic
scbHeap         equ     $04             	; back-pointer to owning heap header
scbArenaHead    equ     $08             	; head of the arena list
scbFlags        equ     $0C             	; reserved SOA-local flags
scbPartial      equ     $10             	; 16 x long: per-class partial-slab list heads
scbFull         equ     $50             	; 16 x long: per-class full-slab list heads
scbLiveCells    equ     $90             	; live (allocated) cell count
scbLiveCellBytes equ    $94             	; sum of usable (class) bytes over live cells
scbSlabCount    equ     $98             	; number of live slabs
scbArenaCount   equ     $9C             	; number of arenas
SCB_HDR_SIZE    equ     $A0             	; size of the SCB

* --- Arena descriptor: SLAB_SIZE-aligned tile backing store ---
arMagic         equ     $00             	; 'AREN' magic
arBlock         equ     $04             	; underlying regular block (for release)
arNext          equ     $08             	; next arena in the SCB arena list
arBase          equ     $0C             	; first SLAB_SIZE-aligned tile address
arSlabs         equ     $10             	; word: total tiles in this arena
arSlabUse       equ     $12             	; word: tiles currently in use
arTileMap       equ     $14             	; long: used/free bitmap (bit i = tile i live)
AREN_HDR_SIZE   equ     $18             	; size of the arena descriptor

* --- Slab header: at each SLAB_SIZE-aligned tile ---
slMagic         equ     $00             	; 'SLAB' magic (free-path discriminator)
slFlags         equ     $04             	; loword: slab flags
slId            equ     $04             	; hiword: owning heap id (HEAP_ID_MASK)
slClass         equ     $08             	; word: size-class index (0..15)
slCellSz        equ     $0A             	; word: cell size in bytes (class value)
slTotal         equ     $0C             	; word: total cells in this slab
slFree          equ     $0E             	; word: free cell count
slFreeHd        equ     $10             	; word: free-list head index ($FFFF = none)
slArena         equ     $12             	; long: owning arena descriptor
slNext          equ     $16             	; long: next slab in class partial/full list
slPrev          equ     $1A             	; long: prev slab in class partial/full list
                                        	; $1E-$1F: pad to SLAB_HDR_SIZE
slCells         equ     SLAB_HDR_SIZE   	; first cell = tile + SLAB_HDR_SIZE ($20)

* --- Free-cell control (stored in a free cell body) ---
cellNextIdx     equ     $00             	; word: next free cell index ($FFFF = end)
cellFreeTag     equ     $02             	; word: SOA_FREE_TAG while the cell is free

* --- SOA walk cursor (caller-provided; zero the whole struct to start) ---
swArena         equ     $00             	; long: current arena descriptor
swTile          equ     $04             	; long: next tile index to examine
swCell          equ     $08             	; long: next cell index to examine
SOA_WALK_CURSOR_SIZE equ $0C            	; size of the walk cursor

************************************************************************
* SOA function prototypes (Phase 1)
************************************************************************
__HeapScbGetOrCreate		PROTO	, hHeap:DWORD
__HeapArenaCreate		PROTO	, hHeap:DWORD, nTiles:DWORD
__HeapArenaRelease		PROTO	, hHeap:DWORD, arena:DWORD
__HeapSlabCreate		PROTO	, hHeap:DWORD, cls:DWORD
__HeapSlabFromPtr		PROTO	, pMem:DWORD
__HeapSlabRelease		PROTO	, hHeap:DWORD, slab:DWORD
__HeapClassListPush		PROTO	, pHeadSlot:DWORD, slab:DWORD
__HeapClassListUnlink		PROTO	, pHeadSlot:DWORD, slab:DWORD

; SOA allocation path (Phase 2)
__HeapSoaAlloc			PROTO	, hHeap:DWORD, lFlags:DWORD, lBytes:DWORD

; SOA free path (Phase 3)
__HeapSoaFree			PROTO	, hHeap:DWORD, slab:DWORD, pMem:DWORD

; SOA realloc path (Phase 4)
__HeapSoaReAlloc		PROTO	, hHeap:DWORD, lFlags:DWORD, slab:DWORD, pMem:DWORD, lBytes:DWORD

; SOA validation / compaction / walk (Phase 5)
__HeapSoaValidate		PROTO	, hHeap:DWORD
__HeapSoaCompact		PROTO	, hHeap:DWORD
__HeapSoaWalk			PROTO	, hHeap:DWORD, pCursor:DWORD

************************************************************************
* Heap Error codes
************************************************************************
HEAP_ERROR_SUCCESS 			equ 	$00	; Last heap operation was successful
HEAP_ERROR_INVALID_PARAM		equ 	$01 	; Bad parameter
HEAP_ERROR_INVALID_HANDLE		equ 	$02	; Heap handle is invalid
HEAP_ERROR_INVALID_BLOCK		equ 	$03 	; Memory pointer is not a heap block
HEAP_ERROR_INVALID_PREV_LINK		equ	$04 	; Block chain back link is invalid
HEAP_ERROR_INVALID_NEXT_LINK		equ 	$05 	; Block chain forward link is invalid
HEAP_ERROR_INVALID_FPREV_LINK 		equ 	$06 	; Block in free chain has an invalid back link
HEAP_ERROR_BLOCK_NOT_FREE 		equ 	$07 	; Block in free chain not marked as free
HEAP_ERROR_HEAPEND_BAD_MAGIC		equ 	$08	; End of heap magic number is corrupt
HEAP_ERROR_INVALID_HEAPEND		equ 	$09	; Heap end found in the worng position
HEAP_ERROR_HANDLE_BLOCK_MISMATCH	equ 	$0A 	; Heap block is valid but not owned by heap
HEAP_ERROR_OUT_OF_MEMORY		equ 	$0B	; Insufficient free space to satisfy request
HEAP_ERROR_NOT_INITIALIZED 		equ 	$0C	; Machine heap not initialized
HEAP_ERROR_INITIALIZED			equ 	$0D 	; Machine heap is already initialized
HEAP_ERROR_NO_MORE_ITEMS		equ     $0E 	; No more enumerable blocks.
HEAP_HEADER_BLOCK_HEADPTR_BAD		equ 	$0F 	; The block chain head pointer is invalid
HEAP_HEADER_BLOCK_FREEPTR_BAD 		equ 	$10 	; The free block chain head pointer is invalid
HEAP_HEADER_BAD_MAGIC			equ 	$11 	; The heap header magic number is invalid
HEAP_HEADER_INVALID_SIZE		equ 	$12 	; Heap size not derived from reqested size
HEAP_ERROR_TAIL_VALIDATION_FAILED 	equ 	$13 	; The debug tail data was corrupt
HEAP_ERROR_INVALID_FNXT_LINK		equ 	$14 	; Block in free chain has an invalid forward link

HEAP_ERROR_SLAB_CORRUPT			equ 	$15 	; Slab header or free list is inconsistent
HEAP_ERROR_DOUBLE_FREE			equ 	$16 	; Small-pool cell was already free (double free)
HEAP_ERROR_SOA_ARENA_CORRUPT		equ 	$17 	; Small-pool arena descriptor is inconsistent

************************************************************************
* Heap Statistics structure (filled by __HeapStats)
************************************************************************
hsBlockCount    equ     $00             	; Total blocks in the physical chain
hsAllocCount    equ     $04             	; Allocated block count
hsFreeCount     equ     $08             	; Free block count
hsReqBytes      equ     $0C             	; Sum of bhRequestSize over allocated blocks
hsCommitBytes   equ     $10             	; Sum of bhSize over allocated blocks (incl headers)
hsFreeBytes     equ     $14             	; Sum of bhSize over free blocks
hsOverheadBytes equ     $18             	; hsCommitBytes - hsReqBytes (header + rounding waste)
hsLargestFree   equ     $1C             	; Largest free block data-area size
hsHist0         equ     $20             	; Allocated request size <= 8 bytes
hsHist1         equ     $24             	; Allocated request size <= 16 bytes
hsHist2         equ     $28             	; Allocated request size <= 32 bytes
hsHist3         equ     $2C             	; Allocated request size <= 64 bytes
hsHist4         equ     $30             	; Allocated request size <= 128 bytes
hsHist5         equ     $34             	; Allocated request size <= 256 bytes
hsHist6         equ     $38             	; Allocated request size <= 512 bytes
hsHist7         equ     $3C             	; Allocated request size <= 1024 bytes
hsHist8         equ     $40             	; Allocated request size <= 4096 bytes
hsHist9         equ     $44             	; Allocated request size > 4096 bytes
HEAP_STATS_SIZE equ     $48             	; Size of the HEAP_STATS structure

************************************************************************
* Heap API Prototypes
************************************************************************
_GetMachineHeap			PROTO
_GetMachineHeaps		PROTO	, NumHeaps:DWORD, pHeaps:DWORD
_HeapAlloc			PROTO	, hHeap:DWORD, lFlags:DWORD, lBytes:DWORD
_HeapCompact			PROTO	, hHeap:DWORD
_HeapCreate			PROTO	, lOptions:DWORD, lSize:DWORD
_HeapDestroy			PROTO	, hHeap:DWORD
_HeapFree			PROTO	, hHeap:DWORD, pMem:DWORD
_HeapReAlloc			PROTO	, hHeap:DWORD, lFlags:DWORD, pMem:DWORD, lBytes:DWORD
_HeapSize			PROTO	, hHeap:DWORD, pMem:DWORD
_HeapValidate			PROTO	, hHeap:DWORD, pBlock:DWORD
_HeapValidateHandle		PROTO	, hHeap:DWORD
_HeapWalk			PROTO	, hHeap:DWORD, pEntry:DWORD
_MachineHeapInitialize		PROTO	, lOptions:DWORD, lStart:DWORD, lSize:DWORD
__HeapAutoValidateFlagCheck	PROTO	, hHeap:DWORD, fFree:DWORD
__HeapCoalesce			PROTO	, hHeap:DWORD, pBlock:DWORD
__HeapDebugFillOnFree		PROTO	, pBlock:DWORD
__HeapInvalidateBlockHeader	PROTO	, hHeap:DWORD, pBlock:DWORD
__HeapUnlinkFromBlockChain	PROTO	, hHeap:DWORD, pBlock:DWORD
__HeapUnlinkFromFreeBlockChain	PROTO	, hHeap:DWORD, pBlock:DWORD

	.list
