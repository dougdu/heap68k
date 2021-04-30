* HEAP_ZERO_MEMORY 0x00000001
*	If the reallocation request is for a larger size, the additional
* 	region of memory beyond the original size be initialized to zero.
*	The contents of the memory block up to its original size are
*	unaffected.
*
* HEAP_REALLOC_IN_PLACE_ONLY 0x00000002
* 	There can be no movement when reallocating a memory block.
* 	If this value is not specified, the function may move the
*	block to a new location. If this value is specified and the
*	block cannot be resized without moving, the function fails,
* 	leaving the original memory block unchanged.
*
* HEAP_TAIL_CHECKING_ENABLED      0x00000004
*	This flag adds a short pattern to the end of each allocation. The
*	heap manager detects the pattern when the block is freed and, if
*	the block was modified, the heap manager breaks into the debugger.
*
* HEAP_FREE_CHECKING_ENABLED      0x00000008
*       The Enable heap free checking flag validates each heap allocation
*  	when it is freed.
*
* HEAP_DISABLE_COALESCE_ON_FREE   0x00000010
*	The Disable heap coalesce on free flag leaves adjacent blocks
*	of heap memory separate when they are freed.
*
HEAP_ZERO_MEMORY_BIT 		  equ 	0
HEAP_REALLOC_IN_PLACE_ONLY_BIT	  equ 	1
HEAP_TAIL_CHECKING_ENABLED_BIT	  equ	2
HEAP_FREE_CHECKING_ENABLE_BIT	  equ	3
HEAP_DISABLE_COALESCE_ON_FREE_BIT equ	4

HEAP_ZERO_MEMORY 		equ 	1 shl HEAP_ZERO_MEMORY_BIT
HEAP_REALLOC_IN_PLACE_ONLY 	equ 	1 shl HEAP_REALLOC_IN_PLACE_ONLY_BIT
HEAP_TAIL_CHECKING_ENABLED      equ 	1 shl HEAP_TAIL_CHECKING_ENABLED_BIT
HEAP_FREE_CHECKING_ENABLED      equ 	1 shl HEAP_FREE_CHECKING_ENABLE_BIT
HEAP_DISABLE_COALESCE_ON_FREE   equ	1 shl HEAP_DISABLE_COALESCE_ON_FREE_BIT

HEAP_MAGIC      equ 	'HEAP'
BLOCK_MAGIC     equ     'BLKH'
HEAP_TAIL       equ 	$cdcdcdcd
HEAP_END        equ     'PAEH'
BAADFOOD        equ     $baadf00d

* HEAP_HEADER
hhMagic	        equ	$00             ; Heap Header magic number
hhFlags	        equ	$04             ; Heap configuration flags
hhRequestSize   equ     $08             ; Requested heap size
hhSize	        equ	$0C             ; Total actual size of the heap including the headers
hhHeapHead      equ	$10             ; Pointer to the first block in the heap block list
hhFreeHead      equ     $14             ; Pointer to the head of the free block list
HEAP_HDR_SIZE   equ     $18             ; Size of the heap header in bytes

* BLOCK_HEADER
bhMagic         equ     $00             ; Heap Block magic number
bhFlags         equ     $04             ; Block status flags
bhRequestSize   equ     $08             ; Requested allocation size
bhSize          equ     $0C             ; Actual size of block including headers
bhPrev          equ     $10             ; Pointer to the previous block
bhNext	        equ 	$14             ; Pointer to the next block
bhFreePrev      equ     $18             ; Pointer to previous free block
bhFreeNext      equ     $1C             ; Pointer to the next free block
bhData	        equ	$20             ; Offset to the start of block data
BLK_HDR_SIZE    equ     $20             ; Size of the block header in bytes

* The least significant two bits of bhNext offset are used as flags
FLG_FREE_BIT    equ     0               ; Bit # of free flag
FLG_GARBAGE_BIT equ     1               ; Bit # of garbage bit
FLG_FREE        equ     1 shl FLG_FREE_BIT      ; Set if the block is free
FLG_GARBAGE     equ     1 shl FLG_GARBAGE_BIT   ; Set during garbage collection

* HEAP_END
heMagic         equ     $00             ; Offset to the MAGIC Number
HEAP_END_SIZE   equ     BLK_HDR_SIZE    ; Size of the heap end marker in bytes.

MACHINE_HEAP_SIZE equ	32768 * 2       ; Size of the machine heap
