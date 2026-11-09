/* cpm68k.ld — GNU ld linker script for CP/M-68K bare-metal targets
 *
 * Usage:
 *   m68k-elf-ld -T cpm68k.ld -Ttext 0x1700 crt0.o main.o ... -o prog.68k
 *
 * -Ttext sets the start address of .text.  .data and .bss follow
 * immediately with no alignment gap (word-aligned only).
 * No entry point is defined; no basepage section is emitted.
 *
 * PHDRS:
 *   Without an explicit PHDRS clause ld coalesces .text/.data/.bss into a
 *   single default PT_LOAD whose flags are the union (R+W+X) of all the
 *   section flags it covers — triggering the
 *       "LOAD segment with RWX permissions"
 *   warning.  Declaring two program headers — a read+execute one for
 *   text/rodata and a read+write one for data/bss — emits exactly the
 *   permissions each segment actually needs and silences the warning.
 *   mkdri's PT_LOAD walker reads both segments independently; the
 *   resulting .68K layout (contiguous text+data, then bss as NOBITS
 *   memsz-tail) is unchanged.
 */

/*ENTRY(_start)*/

PHDRS
{
    text PT_LOAD FLAGS(5);  /* PF_R | PF_X */
    data PT_LOAD FLAGS(6);  /* PF_R | PF_W (covers .data and .bss) */
}

SECTIONS
{
    .text :
    {
        /* Conventional UNIX-style segment-bounds symbols.  Used by
         * the sim68k debug helper (tools/cpm68k_debug.gdb) to compute
         * accurate text/data/bss bounds when launching a transient
         * under sim68k --boot:cpm.sys --gdb -- GDB's `load` does not
         * transmit .bss and merges .text/.data into one contiguous
         * write, so the stub's auto-detect can't recover the real
         * segment layout without these markers.  Harmless to real
         * CP/M-68K loads. */
        _text_start = .;
        *(.text)
        *(.text.*)
        *(.rodata)
        *(.rodata.*)
    } :text

    . = ALIGN(2);
    /* Conventional UNIX-style "end of code" marker.  Used by the
     * sim68k GDB debug helper (tools/cpm68k_debug.gdb) to compute
     * accurate text/data/bss bounds when launching a transient under
     * an OS booted via sim68k --boot.  Harmless to real CP/M-68K
     * loads: the symbol carries no per-section data. */
    _etext = .;

    .data :
    {
        *(.data)
        *(.data.*)
    } :data

    . = ALIGN(2);
    _edata = .;

    .bss :
    {
        *(.bss)
        *(.bss.*)
        *(COMMON)
    } :data

    . = ALIGN(2);
    _end = .;
}
