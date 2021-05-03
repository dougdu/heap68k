#
# Makefile for building libheap.a
#
# A library that supports the a simple heap management API.
#

# Definitions for Assembler

.SUFFIXES: .a68 .s .bas .a

ASM       =F:\git\worm68k\68KTools\debug\asm68k.exe
AFLAGS    =/Cu /coff /Fl /Fm /nologo
AINC      =/I.
LD        =F:\git\worm68k\tools\ld.exe
AR        =F:\git\worm68k\tools\ar.exe
RANLIB	  =F:\git\worm68k\tools\ranlib.exe
SIM68KDIR =F:\git\worm68k\68KTools\sim68k

.a68.obj:
	$(ASM) $(AFLAGS) $(AINC) /c $<

.s.obj:
	$(ASM) /ScAS68 $(AFLAGS) $(AINC) /c $<

# targets
HEAPOBJS = HeapAlloc.obj HeapAutoValidateFlagCheck.obj HeapCompact.obj \
	   HeapCreate.obj HeapDestroy.obj HeapFree.obj HeapInitialize.obj \
	   HeapReAlloc.obj HeapSize.obj HeapUnlinkFromFreeList.obj \
	   HeapValidate.obj HeapValidateHandle.obj HeapWalk.obj HeapData.obj

all: libheap.a heaptest.68k

libheap.a: $(HEAPOBJS)
	$(AR) -rscv libheap.a $**

heaptest.68k:  heaptest.obj libheap.a
	$(LD) -o $@ -Ttext 1700 heaptest.obj -L.\ -lheap
	copy $@ $(SIM68KDIR)

HeapAlloc.obj: HeapAlloc.a68 heap.inc
HeapAutoValidateFlagCheck.obj: HeapAutoValidateFlagCheck.a68 heap.inc
HeapCompact.obj: HeapCompact.a68 heap.inc
HeapCreate.obj: HeapCreate.a68 heap.inc
HeapData.obj: HeapData.a68 heap.inc
HeapDestroy.obj: HeapDestroy.a68 heap.inc
HeapFree.obj: HeapFree.a68 heap.inc
HeapInitialize.obj: HeapInitialize.a68 heap.inc
HeapReAlloc.obj: HeapReAlloc.a68 heap.inc
HeapSize.obj: HeapSize.a68 heap.inc
HeapUnlinkFromFreeList.obj: HeapUnlinkFromFreeList.a68 heap.inc
HeapValidate.obj: HeapValidate.a68 heap.inc
HeapValidateHandle.obj: HeapValidateHandle.a68 heap.inc
HeapWalk.obj: HeapWalk.a68 heap.inc

# Test program for libheap.a
heaptest.obj: heaptest.a68 heap.inc libheap.a

clean:
	del *.68k
	del *.a
	del *.obj
	del *.lst
