#
# Makefile for building libheap.a
#
# A library that supports a simple heap management API.
#

# Definitions for Assembler

.SUFFIXES: .a68 .a

TOOLCHAIN_DIR =toolchain\windows
ASM       =$(TOOLCHAIN_DIR)\asm68K.exe
ELF_FLAGS =/Cx /elf /Fl /Zi /nologo
AINC      =/Isrc
LD        =$(TOOLCHAIN_DIR)\m68k-elf-ld.exe
LDSCRIPT  =$(TOOLCHAIN_DIR)\cpm68k.ld
AR        =$(TOOLCHAIN_DIR)\m68k-elf-ar.exe
OUTDIR    =out
LIBDIR    =$(OUTDIR)\lib
INCDIR    =$(OUTDIR)\include
BINDIR    =$(OUTDIR)\bin

{src}.a68{$(LIBDIR)}.o:
	@if not exist "$(LIBDIR)" mkdir "$(LIBDIR)"
	$(ASM) $(ELF_FLAGS) $(AINC) /Fo$@ /Fl$(@R).lst /c $<

{test}.a68{$(BINDIR)}.o:
	@if not exist "$(BINDIR)" mkdir "$(BINDIR)"
	$(ASM) $(ELF_FLAGS) $(AINC) /Itest /Fo$@ /Fl$(@R).lst /c $<

# targets

HEAP_ELF_OBJS = $(LIBDIR)\GetMachineHeap.o $(LIBDIR)\GetMachineHeaps.o \
	   $(LIBDIR)\HeapAlloc.o $(LIBDIR)\HeapAutoValidateFlagCheck.o $(LIBDIR)\HeapCoalesce.o $(LIBDIR)\HeapCompact.o \
	   $(LIBDIR)\HeapCreate.o $(LIBDIR)\HeapDestroy.o $(LIBDIR)\HeapFree.o $(LIBDIR)\HeapGetError.o $(LIBDIR)\HeapInitialize.o \
	   $(LIBDIR)\HeapReAlloc.o $(LIBDIR)\HeapSize.o $(LIBDIR)\HeapStats.o $(LIBDIR)\HeapUnlinkFromBlockChain.o \
	   $(LIBDIR)\HeapUnlinkFromFreeBlockChain.o $(LIBDIR)\HeapValidate.o \
	   $(LIBDIR)\HeapValidateHandle.o $(LIBDIR)\HeapWalk.o $(LIBDIR)\HeapData.o \
	   $(LIBDIR)\HeapDebugFillOnFree.o $(LIBDIR)\HeapInvalidateBlockHeader.o \
	   $(LIBDIR)\HeapSmallCtl.o $(LIBDIR)\HeapArena.o $(LIBDIR)\HeapSlab.o $(LIBDIR)\HeapSmallAlloc.o $(LIBDIR)\HeapSmallFree.o \
	   $(LIBDIR)\HeapSmallReAlloc.o $(LIBDIR)\HeapSmallValidate.o $(LIBDIR)\HeapSmallCompact.o $(LIBDIR)\HeapSmallWalk.o


all: directories $(INCDIR)\heap.inc $(LIBDIR)\libheap.a $(BINDIR)\heaptest.elf $(BINDIR)\heapsmalltest.elf

directories:
	@if not exist "$(BINDIR)" mkdir "$(BINDIR)"
	@if not exist "$(INCDIR)" mkdir "$(INCDIR)"
	@if not exist "$(LIBDIR)" mkdir "$(LIBDIR)"

libheap.a: directories $(INCDIR)\heap.inc $(LIBDIR)\libheap.a

$(INCDIR)\heap.inc: src\heap.inc
	@if not exist "$(BINDIR)" mkdir "$(BINDIR)"
	@if not exist "$(INCDIR)" mkdir "$(INCDIR)"
	@if not exist "$(LIBDIR)" mkdir "$(LIBDIR)"
	copy src\heap.inc $@

$(LIBDIR)\libheap.a: $(HEAP_ELF_OBJS) $(INCDIR)\heap.inc
	$(AR) -rscv $@ $(HEAP_ELF_OBJS)

$(BINDIR)\heaptest.elf: $(BINDIR)\HeapTest.o $(LIBDIR)\libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 $(BINDIR)\HeapTest.o -L $(LIBDIR) -lheap -o $@

$(BINDIR)\heapsmalltest.elf: $(BINDIR)\HeapSmallTest.o $(LIBDIR)\libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 $(BINDIR)\HeapSmallTest.o -L $(LIBDIR) -lheap -o $@

# --- automated test suite (see docs/HEAP_TEST_SUITE_DESIGN.md) ---
TEST_ELFS = $(BINDIR)\stub.elf $(BINDIR)\test_kit.elf $(BINDIR)\test_create.elf $(BINDIR)\test_block.elf \
	    $(BINDIR)\test_soa.elf $(BINDIR)\test_debug.elf $(BINDIR)\test_errors.elf \
	    $(BINDIR)\test_stress.elf $(BINDIR)\test_edges.elf $(BINDIR)\test_aligned.elf

tests: directories $(INCDIR)\heap.inc $(TEST_ELFS)

test: tests
	pwsh -NoProfile -ExecutionPolicy Bypass -File test\run-heap-tests.ps1 -NoBuild

$(BINDIR)\stub.elf: $(BINDIR)\stub.o $(LIBDIR)\libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 $(BINDIR)\stub.o -L $(LIBDIR) -lheap -o $@

$(BINDIR)\test_kit.elf: $(BINDIR)\test_kit.o $(LIBDIR)\libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 $(BINDIR)\test_kit.o -L $(LIBDIR) -lheap -o $@

$(BINDIR)\test_create.elf: $(BINDIR)\test_create.o $(LIBDIR)\libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 $(BINDIR)\test_create.o -L $(LIBDIR) -lheap -o $@

$(BINDIR)\test_block.elf: $(BINDIR)\test_block.o $(LIBDIR)\libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 $(BINDIR)\test_block.o -L $(LIBDIR) -lheap -o $@

$(BINDIR)\test_soa.elf: $(BINDIR)\test_soa.o $(LIBDIR)\libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 $(BINDIR)\test_soa.o -L $(LIBDIR) -lheap -o $@

$(BINDIR)\test_debug.elf: $(BINDIR)\test_debug.o $(LIBDIR)\libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 $(BINDIR)\test_debug.o -L $(LIBDIR) -lheap -o $@

$(BINDIR)\test_errors.elf: $(BINDIR)\test_errors.o $(LIBDIR)\libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 $(BINDIR)\test_errors.o -L $(LIBDIR) -lheap -o $@

$(BINDIR)\test_stress.elf: $(BINDIR)\test_stress.o $(LIBDIR)\libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 $(BINDIR)\test_stress.o -L $(LIBDIR) -lheap -o $@

$(BINDIR)\test_edges.elf: $(BINDIR)\test_edges.o $(LIBDIR)\libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 $(BINDIR)\test_edges.o -L $(LIBDIR) -lheap -o $@

$(BINDIR)\test_aligned.elf: $(BINDIR)\test_aligned.o $(LIBDIR)\libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 $(BINDIR)\test_aligned.o -L $(LIBDIR) -lheap -o $@

# Dependencies for ELF objects
$(LIBDIR)\GetMachineHeap.o: src\GetMachineHeap.a68 src\heap.inc makefile
$(LIBDIR)\GetMachineHeaps.o: src\GetMachineHeaps.a68 src\heap.inc makefile
$(LIBDIR)\HeapAlloc.o: src\HeapAlloc.a68 src\heap.inc makefile
$(LIBDIR)\HeapAutoValidateFlagCheck.o: src\HeapAutoValidateFlagCheck.a68 src\heap.inc makefile
$(LIBDIR)\HeapCoalesce.o: src\HeapCoalesce.a68 src\heap.inc makefile
$(LIBDIR)\HeapCompact.o: src\HeapCompact.a68 src\heap.inc makefile
$(LIBDIR)\HeapCreate.o: src\HeapCreate.a68 src\heap.inc makefile
$(LIBDIR)\HeapData.o: src\HeapData.a68 src\heap.inc makefile
$(LIBDIR)\HeapDebugFillOnFree.o: src\HeapDebugFillOnFree.a68 src\heap.inc makefile
$(LIBDIR)\HeapDestroy.o: src\HeapDestroy.a68 src\heap.inc makefile
$(LIBDIR)\HeapFree.o: src\HeapFree.a68 src\heap.inc makefile
$(LIBDIR)\HeapGetError.o: src\HeapGetError.a68 makefile
$(LIBDIR)\HeapInitialize.o: src\HeapInitialize.a68 src\heap.inc makefile
$(LIBDIR)\HeapInvalidateBlockHeader.o: src\HeapInvalidateBlockHeader.a68 src\heap.inc makefile
$(LIBDIR)\HeapReAlloc.o: src\HeapReAlloc.a68 src\heap.inc makefile
$(LIBDIR)\HeapSize.o: src\HeapSize.a68 src\heap.inc makefile
$(LIBDIR)\HeapStats.o: src\HeapStats.a68 src\heap.inc makefile
$(LIBDIR)\HeapSmallCtl.o: src\HeapSmallCtl.a68 src\heap.inc makefile
$(LIBDIR)\HeapArena.o: src\HeapArena.a68 src\heap.inc makefile
$(LIBDIR)\HeapSlab.o: src\HeapSlab.a68 src\heap.inc makefile
$(LIBDIR)\HeapSmallAlloc.o: src\HeapSmallAlloc.a68 src\heap.inc makefile
$(LIBDIR)\HeapSmallFree.o: src\HeapSmallFree.a68 src\heap.inc makefile
$(LIBDIR)\HeapSmallReAlloc.o: src\HeapSmallReAlloc.a68 src\heap.inc makefile
$(LIBDIR)\HeapSmallValidate.o: src\HeapSmallValidate.a68 src\heap.inc makefile
$(LIBDIR)\HeapSmallCompact.o: src\HeapSmallCompact.a68 src\heap.inc makefile
$(LIBDIR)\HeapSmallWalk.o: src\HeapSmallWalk.a68 src\heap.inc makefile
$(LIBDIR)\HeapUnlinkFromBlockChain.o: src\HeapUnlinkFromBlockChain.a68 src\heap.inc makefile
$(LIBDIR)\HeapUnlinkFromFreeBlockChain.o: src\HeapUnlinkFromFreeBlockChain.a68 src\heap.inc makefile
$(LIBDIR)\HeapValidate.o: src\HeapValidate.a68 src\heap.inc makefile
$(LIBDIR)\HeapValidateHandle.o: src\HeapValidateHandle.a68 src\heap.inc makefile
$(LIBDIR)\HeapWalk.o: src\HeapWalk.a68 src\heap.inc makefile

$(BINDIR)\HeapTest.o: test\HeapTest.a68 src\heap.inc $(LIBDIR)\libheap.a makefile
$(BINDIR)\HeapSmallTest.o: test\HeapSmallTest.a68 src\heap.inc $(LIBDIR)\libheap.a makefile
$(BINDIR)\HeapCompactTest.o: test\HeapCompactTest.a68 src\heap.inc $(LIBDIR)\libheap.a makefile
$(BINDIR)\stub.o: test\stub.a68 src\heap.inc $(LIBDIR)\libheap.a makefile
$(BINDIR)\test_kit.o: test\test_kit.a68 src\heap.inc test\heaptestkit.inc $(LIBDIR)\libheap.a makefile
$(BINDIR)\test_create.o: test\test_create.a68 src\heap.inc test\heaptestkit.inc $(LIBDIR)\libheap.a makefile
$(BINDIR)\test_block.o: test\test_block.a68 src\heap.inc test\heaptestkit.inc $(LIBDIR)\libheap.a makefile
$(BINDIR)\test_soa.o: test\test_soa.a68 src\heap.inc test\heaptestkit.inc $(LIBDIR)\libheap.a makefile
$(BINDIR)\test_debug.o: test\test_debug.a68 src\heap.inc test\heaptestkit.inc $(LIBDIR)\libheap.a makefile
$(BINDIR)\test_errors.o: test\test_errors.a68 src\heap.inc test\heaptestkit.inc $(LIBDIR)\libheap.a makefile
$(BINDIR)\test_stress.o: test\test_stress.a68 src\heap.inc test\heaptestkit.inc $(LIBDIR)\libheap.a makefile
$(BINDIR)\test_edges.o: test\test_edges.a68 src\heap.inc test\heaptestkit.inc $(LIBDIR)\libheap.a makefile
$(BINDIR)\test_aligned.o: test\test_aligned.a68 src\heap.inc test\heaptestkit.inc $(LIBDIR)\libheap.a makefile

clean:
	@if exist "$(LIBDIR)\*.a" del /q "$(LIBDIR)\*.a"
	@if exist "$(LIBDIR)\*.o" del /q "$(LIBDIR)\*.o"
	@if exist "$(LIBDIR)\*.lst" del /q "$(LIBDIR)\*.lst"
	@if exist "$(BINDIR)\*.elf" del /q "$(BINDIR)\*.elf"
	@if exist "$(BINDIR)\*.68k" del /q "$(BINDIR)\*.68k"
	@if exist "$(BINDIR)\*.o" del /q "$(BINDIR)\*.o"
	@if exist "$(BINDIR)\*.lst" del /q "$(BINDIR)\*.lst"
	@if exist "$(INCDIR)\heap.inc" del /q "$(INCDIR)\heap.inc"
