# Local toolchain

`windows/` contains the non-sanitized x64 Release executables selected from the
supplied repositories at collection time. This is a pinned snapshot, not an
automatically updated download of their latest builds. `macos/` is reserved
for a future bundle. Only ELF-targeting GNU tools are included.

| Tool | Version | Source |
|------|---------|--------|
| `asm68K.exe` | 1.0.1088.0 | asm68k Release build |
| `sim68k.exe` | Release binary updated November 6, 2026 | sim68k Release build |
| `m68k-elf-ar.exe`, `m68k-elf-ld.exe` | Binutils 2.44 | worm68k tools/elf |
| `m68k-elf-objdump.exe` | Binutils 2.44 | worm68k tools/elf |
| `m68k-elf-gdb.exe` | GDB 15.2 | worm68k tools/elf |

The bundle also includes `cpm68k.ld`, the GNU tools' required non-system DLLs,
and Python 3.14 support for GDB. The Python archive retains the standard-library
and GDB Python sources without regression tests, bytecode caches, optional GUI
tools, or package installers. It is debugger support, not a standalone Python
installation.

GDB and its Python runtime are used for simulator-based tests, not library
assembly/archiving. A separate host Python installation is not required.
`m68k-elf-objdump.exe` is available for diagnostics.

[The manifest](windows/manifest.json) records source paths, collection-time
repository revisions, timestamps, sizes, and SHA-256 hashes. A repository's
collection-time revision is not a claim that an existing executable was built
from that exact revision.

The manifest pins 19 payload files. Preserve their bytes and upstream notice
formatting; [`.gitattributes`](../.gitattributes) disables text conversion
for `toolchain/windows/**` so line-ending changes cannot invalidate hashes.

## Host prerequisites

- 64-bit Windows with the Microsoft Visual C++ 2015-2022 x64 runtime installed.
- NMake for builds, and PowerShell 7 (`pwsh`) for the automated test runner.

Microsoft runtime and host build programs are not copied from the supplied
repositories.

## Using the collected tools

The Windows [makefile](../makefile) and [test runner](../test/run-heap-tests.ps1)
use this bundle by default. From the repository root:

```powershell
nmake
nmake test
pwsh -File test\run-heap-tests.ps1
```

Use NMake's `/A` option when switching tool versions to rebuild cached objects.
The makefile supplies assembly-only flags: `/Cx /elf /Fl /Zi /nologo`.
The assembler rejects the linker-only `/Fm` map option with `/c`.

`nmake libheap.a` builds just the archive/exported include; `nmake tests`
builds the ten automated ELFs; `nmake test` additionally runs them.
The default `nmake` target builds two legacy harnesses as well as the library;
the CP/M-base-page `heaptest.elf` is not a bare-simulator verdict module.
See the [test guide](../docs/HEAP_TEST_SUITE_DESIGN.md) for coverage and execution.

The archive command is `ar -rscv` with the explicit 31-object list. Its `s`
option builds the symbol index, so no separate ranlib executable or step is
needed. Applications link with `-lheap`, not a format-suffixed library name.

Builds create a Git-ignored `out/` directory in the repository root:

- `out/bin/`: test objects, listings, and executables.
- `out/include/`: the exported `heap.inc`.
- `out/lib/`: library objects, listings, and `libheap.a`.

The runner reads its ELFs and archive from this layout. `nmake clean` removes
compiled output patterns and the copied include, retaining directories,
optional reports/logs, sources, and the bundled toolchain.
`TOOLCHAIN_DIR` selects another **build-tool** directory; it does not change
the runner's simulator/GDB defaults. Use the runner's `-Sim` and `-Gdb`
options separately when selecting alternate test tools.

The macOS makefile still uses externally configured tools and legacy flags,
not `toolchain/macos/`, and provides no automated suite targets. No native
macOS build/test run is validated by this Windows bundle.

## Notices

The library's [MIT license](../LICENSE) does not apply to the bundled toolchain
files.

The bundled files retain their upstream licensing and copyright terms; this
directory grants no additional redistribution rights. GNU and Python notices
are retained under `windows/licenses/`.

The asm68k README states "Copyright Thoth Computers. All rights reserved" and
provides no separate open-source license. The sim68k README likewise provides
no formal license and refers readers to its source headers and historical
component notices. Review those terms and the GNU corresponding-source
requirements before redistributing this bundle.
