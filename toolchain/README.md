# Local toolchain

`windows/` contains the newest existing, non-sanitized x64 Release executables
found in the supplied repositories. `macos/` is reserved for a future bundle.
Only ELF-targeting GNU tools are included.

| Tool | Version | Source |
|------|---------|--------|
| `asm68K.exe` | 1.0.1088.0 | asm68k Release build |
| `sim68k.exe` | Release binary updated November 6, 2026 | sim68k Release build |
| `m68k-elf-ar.exe`, `m68k-elf-ld.exe`, `m68k-elf-ranlib.exe` | Binutils 2.44 | worm68k tools/elf |
| `m68k-elf-objdump.exe` | Binutils 2.44 | worm68k tools/elf |
| `m68k-elf-gdb.exe` | GDB 15.2 | worm68k tools/elf |

The bundle also includes `cpm68k.ld`, the GNU tools' required non-system DLLs,
and Python 3.14 support for GDB. The Python archive retains the standard-library
and GDB Python sources without regression tests, bytecode caches, optional GUI
tools, or package installers. It is debugger support, not a standalone Python
installation.

[The manifest](windows/manifest.json) records source paths, collection-time
repository revisions, timestamps, sizes, and SHA-256 hashes. A repository's
collection-time revision is not a claim that an existing executable was built
from that exact revision.

## Host prerequisites

- 64-bit Windows with the Microsoft Visual C++ 2015-2022 x64 runtime installed.
- NMake and PowerShell 7 (`pwsh`) for the current build/test workflow.

Microsoft runtime and host build programs are not copied from the supplied
repositories.

## Using the collected tools

This collection does not change the existing makefile or runner defaults.
From the repository root, build using the bundle:

```powershell
nmake /f makefile-elf tests `
  "ASM=toolchain\windows\asm68K.exe" `
  "ELF_FLAGS=/Cx /elf /Fl /Zi /nologo" `
  "LD=toolchain\windows\m68k-elf-ld.exe" `
  "AR=toolchain\windows\m68k-elf-ar.exe" `
  "RANLIB=toolchain\windows\m68k-elf-ranlib.exe" `
  "LDSCRIPT=toolchain\windows\cpm68k.ld"

pwsh -File test\run-heap-tests.ps1 -NoBuild `
  -Sim (Resolve-Path toolchain\windows\sim68k.exe).Path `
  -Gdb (Resolve-Path toolchain\windows\m68k-elf-gdb.exe).Path
```

Use NMake's `/A` option when switching tool versions to rebuild cached objects.
The current assembler rejects the old makefile's `/Fm` map option with `/c`;
the example supplies assembly-only flags instead.

## Notices

The bundled files retain their upstream licensing and copyright terms; this
directory grants no additional redistribution rights. GNU and Python notices
are retained under `windows/licenses/`.

The asm68k README states "Copyright Thoth Computers. All rights reserved" and
provides no separate open-source license. The sim68k README likewise provides
no formal license and refers readers to its source headers and historical
component notices. Review those terms and the GNU corresponding-source
requirements before redistributing this bundle.
