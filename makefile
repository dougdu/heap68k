#
# Makefile for building libheap.a
#
# A library that supports the a simple heap management API.
#

# Definitions for Assembler

.SUFFIXES: .a68 .s .bas .a

ASM       =C:\git\worm68k\68KTools\debug\asm68k.exe
COFF_FLAGS=/Cu /coff /Fl /Fm /nologo
ELF_FLAGS =/Cu /elf /Fl /Fm /nologo
AINC      =/I.
LD        =C:\git\worm68k\tools\ld.exe
AR        =C:\git\worm68k\tools\ar.exe
RANLIB	  =C:\git\worm68k\tools\ranlib.exe
SIM68KDIR =C:\git\worm68k\68KTools\sim68k
LIBDIR    =C:\git\worm68k\lib
INCDIR    =C:\git\worm68k\include

.a68.o:
	$(ASM) $(ELF_FLAGS) $(AINC) /c $<

.a68.obj:
	$(ASM) $(COFF_FLAGS) $(AINC) /c $<

.s.obj:
	$(ASM) /ScAS68 $(COFF_FLAGS) $(AINC) /c $<

# targets
HEAP_COFF_OBJS = GetMachineHeap.obj GetMachineHeaps.obj \
	   HeapAlloc.obj HeapAutoValidateFlagCheck.obj HeapCoalesce.obj HeapCompact.obj \
	   HeapCreate.obj HeapDestroy.obj HeapFree.obj HeapGetError.obj HeapInitialize.obj \
	   HeapReAlloc.obj HeapSize.obj HeapUnlinkFromBlockChain.obj \
	   HeapUnlinkFromFreeBlockChain.obj HeapValidate.obj \
	   HeapValidateHandle.obj HeapWalk.obj HeapData.obj \
	   HeapDebugFillOnFree.obj HeapInvalidateBlockHeader.obj

HEAP_ELF_OBJS = GetMachineHeap.o GetMachineHeaps.o \
	   HeapAlloc.o HeapAutoValidateFlagCheck.o HeapCoalesce.o HeapCompact.o \
	   HeapCreate.o HeapDestroy.o HeapFree.o HeapGetError.o HeapInitialize.o \
	   HeapReAlloc.o HeapSize.o HeapUnlinkFromBlockChain.o \
	   HeapUnlinkFromFreeBlockChain.o HeapValidate.o \
	   HeapValidateHandle.o HeapWalk.o HeapData.o \
	   HeapDebugFillOnFree.o HeapInvalidateBlockHeader.o


all: coff

elf: libheap-elf.a heaptest-elf.68k

coff: libheap-coff.a heaptest-coff.68k

libheap-elf.a: $(HEAP_ELF_OBJS)
	$(AR) -rscv libheap-elf.a $**
	copy Heap.inc $(INCDIR)
	copy libheap-elf.a $(LIBDIR)

libheap-coff.a: $(HEAP_COFF_OBJS)
	$(AR) -rscv libheap-coff.a $**
	copy Heap.inc $(INCDIR)
	copy libheap-coff.a $(LIBDIR)

heaptest-elf.68k:  heaptest.o libheap-elf.a
	$(LD) -o $@ -Ttext 1700 heaptest.o -L.\ -lheap-elf
	copy $@ $(SIM68KDIR)

heaptest-coff.68k:  heaptest.obj libheap-coff.a
	$(LD) -o $@ -Ttext 1700 heaptest.obj -L.\ -lheap-coff
	copy $@ $(SIM68KDIR)

# Dependencies for COFF objects
GetMachineHeap.obj: GetMachineHeap.a68
GetMachineHeaps.obj: GetMachineHeaps.a68
HeapAlloc.obj: HeapAlloc.a68 heap.inc
HeapAutoValidateFlagCheck.obj: HeapAutoValidateFlagCheck.a68 heap.inc
HeapCoalesce.obj: HeapCoalesce.a68 heap.inc
HeapCompact.obj: HeapCompact.a68 heap.inc
HeapCreate.obj: HeapCreate.a68 heap.inc
HeapData.obj: HeapData.a68 heap.inc
HeapDebugFillOnFree.obj: HeapDebugFillOnFree.a68 heap.inc
HeapDestroy.obj: HeapDestroy.a68 heap.inc
HeapFree.obj: HeapFree.a68 heap.inc
HeapGetError.obj: HeapGetError.a68
HeapInitialize.obj: HeapInitialize.a68 heap.inc
HeapInvalidateBlockHeader.obj: HeapInvalidateBlockHeader.a68 heap.inc
HeapReAlloc.obj: HeapReAlloc.a68 heap.inc
HeapSize.obj: HeapSize.a68 heap.inc
HeapUnlinkFromBlockChain.obj: HeapUnlinkFromBlockChain.a68 heap.inc
HeapUnlinkFromFreeBlockChain.obj: HeapUnlinkFromFreeBlockChain.a68 heap.inc
HeapValidate.obj: HeapValidate.a68 heap.inc
HeapValidateHandle.obj: HeapValidateHandle.a68 heap.inc
HeapWalk.obj: HeapWalk.a68 heap.inc

# Test program for libheap-coff.a
heaptest.obj: heaptest.a68 heap.inc libheap-coff.a

# Dependencies for ELF objects
GetMachineHeap.o: GetMachineHeap.a68
GetMachineHeaps.o: GetMachineHeaps.a68
HeapAlloc.o: HeapAlloc.a68 heap.inc
HeapAutoValidateFlagCheck.o: HeapAutoValidateFlagCheck.a68 heap.inc
HeapCoalesce.o: HeapCoalesce.a68 heap.inc
HeapCompact.o: HeapCompact.a68 heap.inc
HeapCreate.o: HeapCreate.a68 heap.inc
HeapData.o: HeapData.a68 heap.inc
HeapDebugFillOnFree.o: HeapDebugFillOnFree.a68 heap.inc
HeapDestroy.o: HeapDestroy.a68 heap.inc
HeapFree.o: HeapFree.a68 heap.inc
HeapGetError.o: HeapGetError.a68
HeapInitialize.o: HeapInitialize.a68 heap.inc
HeapInvalidateBlockHeader.o: HeapInvalidateBlockHeader.a68 heap.inc
HeapReAlloc.o: HeapReAlloc.a68 heap.inc
HeapSize.o: HeapSize.a68 heap.inc
HeapUnlinkFromBlockChain.o: HeapUnlinkFromBlockChain.a68 heap.inc
HeapUnlinkFromFreeBlockChain.o: HeapUnlinkFromFreeBlockChain.a68 heap.inc
HeapValidate.o: HeapValidate.a68 heap.inc
HeapValidateHandle.o: HeapValidateHandle.a68 heap.inc
HeapWalk.o: HeapWalk.a68 heap.inc



heaptest.o: heaptest.a68 heap.inc libheap-elf.a

clean:
	del *.68k
	del *.a
	del *.obj
	del *.o
	del *.lst
