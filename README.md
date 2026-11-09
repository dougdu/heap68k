# heap68k

A Motorola 68000 assembly heap-management library with private heaps,
slab-based small-object allocation, coalescing, reallocation, debug validation,
and an automated simulator-based test suite.

The library builds as `libheap.a`, a static archive of ELF object files, with
`heap.inc` as its public assembly include. ELF is the only supported object
format; COFF builds are no longer supported.

## Features

- A machine heap backed by caller-supplied memory, with private heaps carved
  from that pool.
- Slab-based pooling for small allocations up to 256 bytes.
- Segregated free lists and adjacent-block coalescing to reduce fragmentation.
- Reallocation that first attempts to resize in place before moving a block.
- Configurable debug fills, tail guards, free checks, and heap validation.
- Heap walking and compaction.

Heaps have fixed capacities, and the library provides no internal locking.
Callers must serialize access, including access from interrupt handlers.
See the [API limitations](docs/HEAP_API.md#9-limitations-and-known-issues)
before integrating the library.

## Build and test on Windows

### Prerequisites

- 64-bit Windows.
- NMake, available with Visual Studio C++ Build Tools.
- PowerShell 7 (`pwsh`).
- Microsoft Visual C++ 2015-2022 x64 runtime.

The assembler, ELF linker and archiver, simulator, debugger, and their supporting
files are bundled in [toolchain/windows](toolchain/windows/). No separate
68K toolchain installation is required. Keep the bundle's DLLs and debugger
runtime files intact; see the [toolchain guide](toolchain/README.md) for versions,
provenance, and tool overrides.

From the repository root, in a shell with `nmake` and `pwsh` on `PATH`:

```powershell
nmake
nmake test
```

`nmake` builds the library, exports its public include, and builds the legacy
test harnesses. `nmake test` builds and runs the ten automated test modules in
sim68k through GDB. GDB is needed by the test harness, not to build or use the
library.

The default-build `heaptest.elf` is a CP/M-base-page scratch driver, not a
headless test module. The self-contained `heapsmalltest.elf` is retained as a
legacy SOA check; the automated suite normally uses `test_soa` instead.

| Command | Purpose |
|---------|---------|
| `nmake libheap.a` | Build only the library and exported include. |
| `nmake tests` | Build the automated test executables without running them. |
| `nmake test` | Build and run the automated suite. |
| `nmake clean` | Remove compiled outputs and the exported include. |

### Running selected tests

After building the tests:

```powershell
pwsh -File test\run-heap-tests.ps1 -NoBuild -Modules test_soa
```

The runner uses localhost TCP port 1234 and a 20-second timeout per module by
default. Both can be overridden:

```powershell
pwsh -File test\run-heap-tests.ps1 -NoBuild -Port 4321 -TimeoutSec 40
```

To save a JSON report, use an absolute path so it is independent of the runner's
working directory:

```powershell
$report = Join-Path (Get-Location) 'out\bin\heap-tests.json'
pwsh -File test\run-heap-tests.ps1 -NoBuild -ReportPath $report
```

The runner returns zero when all selected modules pass and a nonzero exit code
on failure. See the [test suite guide](docs/HEAP_TEST_SUITE_DESIGN.md) for
current coverage, known gaps, diagnostics, and integrity-report details.
This is a regression suite, not exhaustive coverage of every flag/input combination.

## Build outputs

Builds automatically create the following directories under the repository root:

| Directory | Contents |
|-----------|----------|
| `out/bin/` | Test executables, objects, listings, and optional reports/logs saved there. |
| `out/include/` | Exported `heap.inc`. |
| `out/lib/` | `libheap.a`, library objects, and assembly listings. |

The entire `out/` directory is ignored by Git. Builds do not place objects or
listings alongside the sources.
`nmake clean` leaves optional JSON reports/logs and the output directories in place.

## Using the library

1. Add `out/include` to your assembler's include search path and include
   `heap.inc`.
2. Link your application objects against `out/lib/libheap.a`. With GNU ld, place
   `-Lout\lib -lheap` after the objects that reference the heap API.
3. Initialize the machine heap over a caller-supplied memory region with
   `_MachineHeapInitialize`, then allocate from it or create private heaps with
   `_HeapCreate`.

Important contracts:

- The initialization size is **usable capacity**, not the backing-buffer size.
  Supply `round_up(lSize,32) + 128` writable bytes after the aligned start,
  plus any leading alignment loss. See the
  [initialization example](docs/HEAP_API.md#71-initialization-sequence).
- Qualifying 1–256-byte allocations normally use 8-byte-aligned SOA cells.
  `_HeapSize` returns their usable **class size**, not the original request.
  Use `HEAP_DISABLE_SMALL_POOL` for regular 32-byte-aligned allocations with
  exact requested-size reporting. Heap tail checking also selects the regular path.
- `_HeapValidate` and `_HeapValidateHandle` preserve D0 and report through
  CCR.Z, unlike the usual D0-returning APIs.
- `_HeapReAlloc` rejects NULL rather than acting as allocation. A zero new
  size is a minimal live allocation on success, not free. Same-class cell
  growth does not initialize newly exposed bytes.

The [API reference](docs/HEAP_API.md) documents the calling convention, constants,
structures, initialization, allocation/free operations, and assembly examples.
Its [limitations](docs/HEAP_API.md#9-limitations-and-known-issues) include
current debug-shrink and heap-enumeration caveats.
The [public include](src/heap.inc) contains 13 public PROTO declarations;
the `_HeapGetError` leaf is declared `extern` by callers.

## Repository layout

| Path | Purpose |
|------|---------|
| [src/](src/) | Library assembly sources and public include. |
| [test/](test/) | Test programs, support macros, and PowerShell runner. |
| [docs/](docs/) | API, allocator design, and test documentation. |
| [toolchain/](toolchain/) | Bundled Windows tools and reserved macOS directory. |
| [makefile](makefile) | Windows NMake build using the repository-local tools. |
| [makefile.macos](makefile.macos) | GNU-make build for an external macOS toolchain. |

### macOS status

The macOS makefile requires externally supplied asm68k and GNU m68k ELF tools.
Configure its `ASM`, `LD`, `AR`, and `LDSCRIPT` variables for your installation.
Its legacy `ELF_FLAGS` include linker-only `-Fm`; override them if the selected
assembler rejects that option with `-c`. Unlike the Windows build, it has no
automated `tests`/`test` targets.
[toolchain/macos](toolchain/macos/) is reserved for a future bundle and is not
populated yet. The build/test instructions above describe the Windows workflow;
a native macOS build and test run has not been validated.

## Documentation

- [Heap API reference](docs/HEAP_API.md)
- [Small-object allocator design](docs/HEAP_SMALL_ALLOC_DESIGN.md)
- [Small-object allocator design review](docs/HEAP_SMALL_ALLOC_DESIGN_REVIEW.md)
- [Test suite design and runner guide](docs/HEAP_TEST_SUITE_DESIGN.md)
- [Local toolchain guide and notices](toolchain/README.md)

## License

The heap68k library is licensed under the [MIT License](LICENSE).

Bundled tools and runtimes in [toolchain/](toolchain/) are excluded from the
library's MIT license and retain their upstream copyright and licensing terms.
Review the [toolchain notices](toolchain/README.md#notices), including the GNU
corresponding-source requirements, before redistributing the bundle.
