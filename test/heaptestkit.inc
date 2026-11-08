************************************************************************
*  heaptestkit.inc — shared macros + result protocol for the heap test
*  suite.  See ../docs/HEAP_TEST_SUITE_DESIGN.md §7 (result convention) and §8.
*
*  A test module looks like:
*
*      .model  flat
*      include heap.inc
*      include heaptestkit.inc
*      .code
*  start:
*      TEST_INIT   heapbuf,HEAPBUFSIZE-128
*      PHASE   1
*      EXPECT_NONZERO 1,hMachineHeap
*      ...
*      TEST_PASS
*      TEST_EPILOGUE           ; emits _tfail/_tdone (code only)
*
*      .bss                    ; the module declares the shared result vars
*  hMachineHeap ds.l 1         ; (hMachineHeap/tResult/tDetail) + its own test
*  tResult      ds.l 1         ; vars + heapbuf.  (.bss labels can't be emitted
*  tDetail      ds.l 1         ; from a macro — asm68K A2005 on macro-expanded
*  ;   ...test vars...          ; ds.l across the two passes.)
*  heapbuf ds.b HEAPBUFSIZE
*      end
*
*  Result protocol (read at the _tdone breakpoint by heaptest.gdb):
*      tResult = 0           all checks passed
*              = $0000FFFF   sentinel (did not reach _tdone)
*              = $0000PPCC   failing check (PP = phase, CC = check); also D7
*      tDetail               failing context (a value/address); also D6
*
*  Register usage inside macros: D0/D1 scratch, D6 = detail, D7 = code.
*  Keep live values in D2-D5 / A2-A5 or in module .bss across macros;
*  the H* wrappers additionally clobber D0/D1/A0/A1 (m68k caller-saved).
*
*  Flag-returning APIs (_HeapValidate / _HeapValidateHandle report status
*  in the Z flag) must be checked with EXPECT_Z / EXPECT_NZ *immediately*
*  after the H* wrapper (its trailing ADDA does not disturb CCR).
************************************************************************

	extern	_HeapGetError

htk_ph	SET	0			; current phase byte (set by PHASE)

*=======================================================================
* Lifecycle
*=======================================================================

TEST_INIT MACRO hbuf,hsz
	move.l	#(&hsz&),-(sp)		; heap size
	move.l	#&hbuf&,-(sp)		; heap start
	clr.l	-(sp)			; no options
	jsr	_MachineHeapInitialize
	adda.l	#12,sp
	move.l	d0,hMachineHeap
	move.l	#$0000FFFF,tResult	; sentinel until we pass
	moveq	#0,d6
	moveq	#0,d7
	ENDM

PHASE MACRO ph
htk_ph	SET	(&ph&)
	ENDM

TEST_PASS MACRO
	clr.l	tResult
	moveq	#0,d7
	bra	_tdone
	ENDM

TEST_EPILOGUE MACRO
_tfail:
	move.l	d7,tResult
	move.l	d6,tDetail
_tdone:
	jmp	_tdone
	ENDM

*=======================================================================
* Value assertions   (set D7=$PPCC, D6=detail; branch to _tfail on fail)
*=======================================================================

EXPECT_NONZERO MACRO code,src
	move.l	#((htk_ph shl 8) or (&code&)),d7
	move.l	&src&,d0
	move.l	d0,d6
	beq	_tfail
	ENDM

EXPECT_ZERO MACRO code,src
	move.l	#((htk_ph shl 8) or (&code&)),d7
	move.l	&src&,d0
	move.l	d0,d6
	bne	_tfail
	ENDM

EXPECT_EQ MACRO code,src,imm
	move.l	#((htk_ph shl 8) or (&code&)),d7
	move.l	&src&,d0
	move.l	d0,d6
	cmpi.l	#(&imm&),d0
	bne	_tfail
	ENDM

EXPECT_NE MACRO code,src,imm
	move.l	#((htk_ph shl 8) or (&code&)),d7
	move.l	&src&,d0
	move.l	d0,d6
	cmpi.l	#(&imm&),d0
	beq	_tfail
	ENDM

* Value compares (second operand is a memory/register value, not an immediate) —
* for comparing two runtime values, e.g. a handle against hMachineHeap.
EXPECT_EQV MACRO code,src,val
	move.l	#((htk_ph shl 8) or (&code&)),d7
	move.l	&src&,d0
	move.l	d0,d6
	cmp.l	&val&,d0
	bne	_tfail
	ENDM

EXPECT_NEV MACRO code,src,val
	move.l	#((htk_ph shl 8) or (&code&)),d7
	move.l	&src&,d0
	move.l	d0,d6
	cmp.l	&val&,d0
	beq	_tfail
	ENDM

EXPECT_MAGIC MACRO code,src,magic
	move.l	#((htk_ph shl 8) or (&code&)),d7
	move.l	&src&,d0
	move.l	d0,d6
	cmpi.l	#(&magic&),d0
	bne	_tfail
	ENDM

EXPECT_GE MACRO code,src,imm
	move.l	#((htk_ph shl 8) or (&code&)),d7
	move.l	&src&,d0
	move.l	d0,d6
	cmpi.l	#(&imm&),d0
	blo	_tfail			; unsigned: fail if src < imm
	ENDM

EXPECT_LE MACRO code,src,imm
	move.l	#((htk_ph shl 8) or (&code&)),d7
	move.l	&src&,d0
	move.l	d0,d6
	cmpi.l	#(&imm&),d0
	bhi	_tfail			; unsigned: fail if src > imm
	ENDM

EXPECT_LT MACRO code,src,imm
	move.l	#((htk_ph shl 8) or (&code&)),d7
	move.l	&src&,d0
	move.l	d0,d6
	cmpi.l	#(&imm&),d0
	bhs	_tfail			; unsigned: fail if src >= imm
	ENDM

*=======================================================================
* Flag assertions   (read the CCR left by the preceding call)
*=======================================================================

EXPECT_Z MACRO code
	LOCAL	ok
	beq	ok			; Z set -> pass
	move.l	#((htk_ph shl 8) or (&code&)),d7
	bra	_tfail
ok:
	ENDM

EXPECT_NZ MACRO code
	LOCAL	ok
	bne	ok			; Z clear -> pass
	move.l	#((htk_ph shl 8) or (&code&)),d7
	bra	_tfail
ok:
	ENDM

*=======================================================================
* Error-code assertion  (via _HeapGetError)
*=======================================================================

EXPECT_ERR MACRO code,experr
	move.l	#((htk_ph shl 8) or (&code&)),d7
	jsr	_HeapGetError
	move.l	d0,d6
	cmpi.l	#(&experr&),d0
	bne	_tfail
	ENDM

*=======================================================================
* Fill assertion  (assert a longword pattern over [addr, addr+lenb))
*=======================================================================

EXPECT_FILL MACRO code,addr,lenb,pat
	LOCAL	floop
	move.l	#((htk_ph shl 8) or (&code&)),d7
	movea.l	&addr&,a0
	move.l	#(&lenb&),d0
	lsr.l	#2,d0			; longword count
	subq.l	#1,d0			; dbra bias
floop:
	move.l	(a0)+,d1
	move.l	d1,d6			; detail = value seen
	cmpi.l	#(&pat&),d1
	bne	_tfail
	dbra	d0,floop
	ENDM

*=======================================================================
* API-call wrappers   (result, if any, in D0)
*=======================================================================

HALLOC MACRO hh,fl,nb
	move.l	&nb&,-(sp)
	move.l	&fl&,-(sp)
	move.l	&hh&,-(sp)
	jsr	_HeapAlloc
	adda.l	#12,sp
	ENDM

HFREE MACRO hh,pm
	move.l	&pm&,-(sp)
	move.l	&hh&,-(sp)
	jsr	_HeapFree
	adda.l	#8,sp
	ENDM

HREALLOC MACRO hh,fl,pm,nb
	move.l	&nb&,-(sp)
	move.l	&pm&,-(sp)
	move.l	&fl&,-(sp)
	move.l	&hh&,-(sp)
	jsr	_HeapReAlloc
	adda.l	#16,sp
	ENDM

HSIZE MACRO hh,pm
	move.l	&pm&,-(sp)
	move.l	&hh&,-(sp)
	jsr	_HeapSize
	adda.l	#8,sp
	ENDM

HCREATE MACRO opt,hsz
	move.l	&hsz&,-(sp)
	move.l	&opt&,-(sp)
	jsr	_HeapCreate
	adda.l	#8,sp
	ENDM

HDESTROY MACRO hh
	move.l	&hh&,-(sp)
	jsr	_HeapDestroy
	adda.l	#4,sp
	ENDM

HVALIDATE MACRO hh,pb
	move.l	&pb&,-(sp)
	move.l	&hh&,-(sp)
	jsr	_HeapValidate
	adda.l	#8,sp
	ENDM

HVALIDATEH MACRO hh
	move.l	&hh&,-(sp)
	jsr	_HeapValidateHandle
	adda.l	#4,sp
	ENDM

HWALK MACRO hh,pe
	move.l	&pe&,-(sp)
	move.l	&hh&,-(sp)
	jsr	_HeapWalk
	adda.l	#8,sp
	ENDM

HCOMPACT MACRO hh
	move.l	&hh&,-(sp)
	jsr	_HeapCompact
	adda.l	#4,sp
	ENDM

*=======================================================================
* Safety helpers  (encode the SOA test-authoring traps, §4 C7)
*=======================================================================

* Allocate a keep-alive cell of the given size and stash it in dst, so
* freeing the cell under test does not empty+release its slab.
ANCHOR_CELL MACRO hh,nb,dst
	HALLOC	&hh&,#0,&nb&
	move.l	d0,&dst&
	ENDM

* Dirty a live cell's body bytes [4..csz) with 'DIRT', leaving the first
* longword (the free-list control word) intact — for zero-fill-on-realloc
* checks that must not corrupt slFreeHd.
DIRTY_BODY MACRO pm,csz
	LOCAL	dloop
	movea.l	&pm&,a0
	addq.l	#4,a0			; skip the free-list control word
	move.l	#((&csz&)-4),d0
	lsr.l	#2,d0			; longword count
	subq.l	#1,d0			; dbra bias
	move.l	#$44495254,d1		; 'DIRT'
dloop:
	move.l	d1,(a0)+
	dbra	d0,dloop
	ENDM
