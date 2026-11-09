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
LIBDIR    =C:\git\worm68k\lib
INCDIR    =C:\git\worm68k\include
BINDIR    =C:\git\worm68k\bin

{src}.a68.o:
	$(ASM) $(ELF_FLAGS) $(AINC) /Fo$@ /Fl$(@R).lst /c $<

{test}.a68{test}.o:
	$(ASM) $(ELF_FLAGS) $(AINC) /Itest /Fo$@ /Fl$(@R).lst /c $<

# targets

HEAP_ELF_OBJS = GetMachineHeap.o GetMachineHeaps.o \
	   HeapAlloc.o HeapAutoValidateFlagCheck.o HeapCoalesce.o HeapCompact.o \
	   HeapCreate.o HeapDestroy.o HeapFree.o HeapGetError.o HeapInitialize.o \
	   HeapReAlloc.o HeapSize.o HeapStats.o HeapUnlinkFromBlockChain.o \
	   HeapUnlinkFromFreeBlockChain.o HeapValidate.o \
	   HeapValidateHandle.o HeapWalk.o HeapData.o \
	   HeapDebugFillOnFree.o HeapInvalidateBlockHeader.o \
	   HeapSmallCtl.o HeapArena.o HeapSlab.o HeapSmallAlloc.o HeapSmallFree.o \
	   HeapSmallReAlloc.o HeapSmallValidate.o HeapSmallCompact.o HeapSmallWalk.o


all: libheap.a test\heaptest.elf test\heapsmalltest.elf

libheap.a: $(HEAP_ELF_OBJS)
	$(AR) -rscv $@ $**
	copy src\heap.inc $(INCDIR)
	copy $@ $(LIBDIR)

test\heaptest.elf: test\HeapTest.o libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 test\HeapTest.o -L $(LIBDIR) -lheap -o $@
	copy $@ $(BINDIR)

test\heapsmalltest.elf: test\HeapSmallTest.o libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 test\HeapSmallTest.o -L $(LIBDIR) -lheap -o $@
	copy $@ $(BINDIR)

# --- automated test suite (see docs/HEAP_TEST_SUITE_DESIGN.md) ---
TEST_ELFS = test\stub.elf test\test_kit.elf test\test_create.elf test\test_block.elf \
	    test\test_soa.elf test\test_debug.elf test\test_errors.elf \
	    test\test_stress.elf test\test_edges.elf test\test_aligned.elf

tests: $(TEST_ELFS)

test: tests
	pwsh -NoProfile -ExecutionPolicy Bypass -File test\run-heap-tests.ps1 -NoBuild

test\stub.elf: test\stub.o libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 test\stub.o -L $(LIBDIR) -lheap -o $@

test\test_kit.elf: test\test_kit.o libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 test\test_kit.o -L $(LIBDIR) -lheap -o $@

test\test_create.elf: test\test_create.o libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 test\test_create.o -L $(LIBDIR) -lheap -o $@

test\test_block.elf: test\test_block.o libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 test\test_block.o -L $(LIBDIR) -lheap -o $@

test\test_soa.elf: test\test_soa.o libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 test\test_soa.o -L $(LIBDIR) -lheap -o $@

test\test_debug.elf: test\test_debug.o libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 test\test_debug.o -L $(LIBDIR) -lheap -o $@

test\test_errors.elf: test\test_errors.o libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 test\test_errors.o -L $(LIBDIR) -lheap -o $@

test\test_stress.elf: test\test_stress.o libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 test\test_stress.o -L $(LIBDIR) -lheap -o $@

test\test_edges.elf: test\test_edges.o libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 test\test_edges.o -L $(LIBDIR) -lheap -o $@

test\test_aligned.elf: test\test_aligned.o libheap.a
	$(LD) -T $(LDSCRIPT) -Ttext 500 test\test_aligned.o -L $(LIBDIR) -lheap -o $@

# Dependencies for ELF objects
GetMachineHeap.o: src\GetMachineHeap.a68 src\heap.inc makefile
GetMachineHeaps.o: src\GetMachineHeaps.a68 src\heap.inc makefile
HeapAlloc.o: src\HeapAlloc.a68 src\heap.inc makefile
HeapAutoValidateFlagCheck.o: src\HeapAutoValidateFlagCheck.a68 src\heap.inc makefile
HeapCoalesce.o: src\HeapCoalesce.a68 src\heap.inc makefile
HeapCompact.o: src\HeapCompact.a68 src\heap.inc makefile
HeapCreate.o: src\HeapCreate.a68 src\heap.inc makefile
HeapData.o: src\HeapData.a68 src\heap.inc makefile
HeapDebugFillOnFree.o: src\HeapDebugFillOnFree.a68 src\heap.inc makefile
HeapDestroy.o: src\HeapDestroy.a68 src\heap.inc makefile
HeapFree.o: src\HeapFree.a68 src\heap.inc makefile
HeapGetError.o: src\HeapGetError.a68 makefile
HeapInitialize.o: src\HeapInitialize.a68 src\heap.inc makefile
HeapInvalidateBlockHeader.o: src\HeapInvalidateBlockHeader.a68 src\heap.inc makefile
HeapReAlloc.o: src\HeapReAlloc.a68 src\heap.inc makefile
HeapSize.o: src\HeapSize.a68 src\heap.inc makefile
HeapStats.o: src\HeapStats.a68 src\heap.inc makefile
HeapSmallCtl.o: src\HeapSmallCtl.a68 src\heap.inc makefile
HeapArena.o: src\HeapArena.a68 src\heap.inc makefile
HeapSlab.o: src\HeapSlab.a68 src\heap.inc makefile
HeapSmallAlloc.o: src\HeapSmallAlloc.a68 src\heap.inc makefile
HeapSmallFree.o: src\HeapSmallFree.a68 src\heap.inc makefile
HeapSmallReAlloc.o: src\HeapSmallReAlloc.a68 src\heap.inc makefile
HeapSmallValidate.o: src\HeapSmallValidate.a68 src\heap.inc makefile
HeapSmallCompact.o: src\HeapSmallCompact.a68 src\heap.inc makefile
HeapSmallWalk.o: src\HeapSmallWalk.a68 src\heap.inc makefile
HeapUnlinkFromBlockChain.o: src\HeapUnlinkFromBlockChain.a68 src\heap.inc makefile
HeapUnlinkFromFreeBlockChain.o: src\HeapUnlinkFromFreeBlockChain.a68 src\heap.inc makefile
HeapValidate.o: src\HeapValidate.a68 src\heap.inc makefile
HeapValidateHandle.o: src\HeapValidateHandle.a68 src\heap.inc makefile
HeapWalk.o: src\HeapWalk.a68 src\heap.inc makefile

test\HeapTest.o: test\HeapTest.a68 src\heap.inc libheap.a makefile
test\HeapSmallTest.o: test\HeapSmallTest.a68 src\heap.inc libheap.a makefile
test\HeapCompactTest.o: test\HeapCompactTest.a68 src\heap.inc libheap.a makefile
test\stub.o: test\stub.a68 src\heap.inc libheap.a makefile
test\test_kit.o: test\test_kit.a68 src\heap.inc test\heaptestkit.inc libheap.a makefile
test\test_create.o: test\test_create.a68 src\heap.inc test\heaptestkit.inc libheap.a makefile
test\test_block.o: test\test_block.a68 src\heap.inc test\heaptestkit.inc libheap.a makefile
test\test_soa.o: test\test_soa.a68 src\heap.inc test\heaptestkit.inc libheap.a makefile
test\test_debug.o: test\test_debug.a68 src\heap.inc test\heaptestkit.inc libheap.a makefile
test\test_errors.o: test\test_errors.a68 src\heap.inc test\heaptestkit.inc libheap.a makefile
test\test_stress.o: test\test_stress.a68 src\heap.inc test\heaptestkit.inc libheap.a makefile
test\test_edges.o: test\test_edges.a68 src\heap.inc test\heaptestkit.inc libheap.a makefile
test\test_aligned.o: test\test_aligned.a68 src\heap.inc test\heaptestkit.inc libheap.a makefile

clean:
	del *.68k
	del *.a
	del *.o
	del *.lst
	del test\*.68k test\*.elf test\*.o test\*.lst
