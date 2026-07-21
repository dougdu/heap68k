# heaptest.gdb — batch command file for the heap test harness.
# Driven by:  m68k-elf-gdb <module>.elf -nx --batch -x heaptest.gdb
# Assumes a running `sim68k --gdb` RSP stub on localhost:1234.
#
# The program is transferred to the simulator with `load` (the positional
# file argument is ignored by sim68k under --gdb); `load` also sets the PC
# to the ELF entry point.  We break only at `_tdone`: on the failure path
# `_tfail` writes tResult/tDetail and then falls through into `_tdone`, so
# tResult is valid there for both the pass and fail paths.
set pagination off
set confirm off
target remote :1234
load
break _tdone
continue
printf "RESULT=%08x DETAIL=%08x\n", *(unsigned int *)&tResult, *(unsigned int *)&tDetail
kill
quit
