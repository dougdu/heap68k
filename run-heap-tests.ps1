<#
    run-heap-tests.ps1 — automated heap test runner (see HEAP_TEST_SUITE_DESIGN.md §10).

    For each test module it:
      1. starts a fresh `sim68k --gdb` RSP stub,
      2. drives it with `m68k-elf-gdb <module>.elf -nx --batch -x heaptest.gdb`
         (which `load`s the program, breaks at `_tdone`, and prints RESULT=/DETAIL=),
      3. parses the RESULT, applies a watchdog, and tears the sim down.

    Exit code = number of non-passing modules (0 = all pass), for CI.

    Usage:
      nmake /f makefile-elf test                    # canonical one-step: build + run + verdict (CI)
      pwsh -File run-heap-tests.ps1                 # build + run the default modules
      pwsh -File run-heap-tests.ps1 -Modules stub   # a single module
      pwsh -File run-heap-tests.ps1 -NoBuild        # skip the nmake build step
      pwsh -File run-heap-tests.ps1 -Port 4321 -TimeoutSec 40

    A FAIL row's Note decodes RESULT=$0000PPCC as "phase P, check 0xCC"; DETAIL is the
    failing value/code (see the module source for that check).
#>
[CmdletBinding()]
param(
    [string[]] $Modules    = @('stub', 'test_kit', 'test_create', 'test_block', 'test_soa', 'test_debug', 'test_errors', 'test_stress', 'test_edges'),
    [int]      $TimeoutSec = 20,        # per-module watchdog (storm/hang cutoff)
    [int]      $Port       = 1234,
    [switch]   $NoBuild
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

$Sim       = 'C:\git\worm68k\68kTools\builds\win64\bin\Release\sim68k.exe'
$Gdb       = 'C:\SysGCC\m68k-elf\bin\m68k-elf-gdb.exe'
$GdbScript = Join-Path $PSScriptRoot 'heaptest.gdb'

foreach ($tool in @($Sim, $Gdb, $GdbScript)) {
    if (-not (Test-Path -LiteralPath $tool)) { Write-Error "missing: $tool"; exit 255 }
}

# Optional module-scoped overrides for specific $PPCC codes.  Any code not listed
# here is decoded generically as "phase P, check 0xCC" (see Get-ResultNote), so this
# table only needs entries where a friendlier message is genuinely worthwhile.
$KnownCodes = @{
    'stub:00000101' = 'stub: machine heap handle is NULL'
    'stub:00000102' = 'stub: heap header magic != HEAP'
}

# Decode a non-zero RESULT into a human-readable note.  RESULT is $0000PPCC
# (PP = 1-based phase, CC = check id within that phase); $0000FFFF is the
# "never reached _tdone" sentinel written by TEST_INIT.
function Get-ResultNote([string]$module, [string]$res) {
    if ($res -eq '0000FFFF') { return 'sentinel: never reached _tdone (storm / hang / early-out)' }
    if ($KnownCodes.ContainsKey("${module}:$res")) { return $KnownCodes["${module}:$res"] }
    if ($KnownCodes.ContainsKey($res))             { return $KnownCodes[$res] }
    $pp = [Convert]::ToInt32($res.Substring(4, 2), 16)
    $cc = [Convert]::ToInt32($res.Substring(6, 2), 16)
    return ('phase {0}, check 0x{1:X2}' -f $pp, $cc)
}

function Stop-AllSim {
    Get-Process sim68k -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Wait-Port([int]$p, [int]$timeoutMs = 5000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $c = [System.Net.Sockets.TcpClient]::new()
        try {
            if ($c.ConnectAsync('127.0.0.1', $p).Wait(200)) { $c.Close(); return $true }
        } catch { }
        finally { $c.Dispose() }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

# Wait until the RSP port stops accepting connections, i.e. a previous sim has
# fully released it, so we never attach gdb to a dying sim on a stale port.
function Wait-PortFree([int]$p, [int]$timeoutMs = 3000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $c = [System.Net.Sockets.TcpClient]::new()
        try {
            if (-not $c.ConnectAsync('127.0.0.1', $p).Wait(150)) { return $true }   # timed out -> free
            $c.Close()                                                             # still open -> wait
        } catch { return $true }                                                   # refused/threw -> free
        finally { $c.Dispose() }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

if (-not $NoBuild) {
    Write-Host "Building test ELFs (nmake /f makefile-elf tests)..."
    $buildLog = & nmake /f makefile-elf tests 2>&1
    if ($LASTEXITCODE -ne 0) {
        $buildLog | Select-Object -Last 25 | ForEach-Object { Write-Host $_ }
        Write-Error "build failed (nmake exit $LASTEXITCODE)"; exit 255
    }
}

Stop-AllSim
$results = @()

try {
foreach ($m in $Modules) {
    $elf = "$m.elf"
    if (-not (Test-Path -LiteralPath $elf)) {
        $results += [pscustomobject]@{ Module=$m; Status='NOBUILD'; Result='--------'; Detail='--------'; Note='ELF not found' }
        continue
    }

    Stop-AllSim
    [void] (Wait-PortFree $Port 3000)
    $simOut = [System.IO.Path]::GetTempFileName()
    $simProc = Start-Process -FilePath $Sim -ArgumentList '--gdb', "$Port" `
                 -PassThru -WindowStyle Hidden -RedirectStandardOutput $simOut -RedirectStandardError "$simOut.err"

    if (-not (Wait-Port $Port 5000)) {
        try { $simProc | Stop-Process -Force } catch { }
        Remove-Item $simOut, "$simOut.err" -ErrorAction SilentlyContinue
        $results += [pscustomobject]@{ Module=$m; Status='NOSIM'; Result='--------'; Detail='--------'; Note="RSP port $Port did not open" }
        continue
    }

    $gdbOut = [System.IO.Path]::GetTempFileName()
    $gdbProc = Start-Process -FilePath $Gdb -ArgumentList $elf, '-nx', '--batch', '-x', $GdbScript `
             -PassThru -WindowStyle Hidden -RedirectStandardOutput $gdbOut -RedirectStandardError "$gdbOut.err"

    $exited = $gdbProc.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) {
        try { $gdbProc | Stop-Process -Force } catch { }
        try { $simProc | Stop-Process -Force } catch { }
        Remove-Item $simOut, "$simOut.err", $gdbOut, "$gdbOut.err" -ErrorAction SilentlyContinue
        $results += [pscustomobject]@{ Module=$m; Status='TIMEOUT'; Result='--------'; Detail='--------'; Note="watchdog > $TimeoutSec s (storm/hang)" }
        continue
    }
    $gdbProc.WaitForExit()   # ensure redirected streams are flushed

    $out = (Get-Content $gdbOut -Raw -ErrorAction SilentlyContinue) + "`n" + (Get-Content "$gdbOut.err" -Raw -ErrorAction SilentlyContinue)
    try { $simProc | Stop-Process -Force } catch { }
    Remove-Item $simOut, "$simOut.err", $gdbOut, "$gdbOut.err" -ErrorAction SilentlyContinue

    $mt = [regex]::Match($out, 'RESULT=([0-9a-fA-F]{8})\s+DETAIL=([0-9a-fA-F]{8})')
    if (-not $mt.Success) {
        $hint = ($out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 1)
        $note = 'no RESULT= line from gdb'
        if ($hint) { $note = "$note ($hint)" }
        $results += [pscustomobject]@{ Module=$m; Status='NORESULT'; Result='--------'; Detail='--------'; Note=$note }
        continue
    }

    $res = $mt.Groups[1].Value.ToUpper()
    $det = $mt.Groups[2].Value.ToUpper()
    if ($res -eq '00000000') {
        $results += [pscustomobject]@{ Module=$m; Status='PASS'; Result=$res; Detail=$det; Note='' }
    } else {
        $note = Get-ResultNote $m $res
        $results += [pscustomobject]@{ Module=$m; Status='FAIL'; Result=$res; Detail=$det; Note=$note }
    }
}
}
finally {
    Stop-AllSim
}

Write-Host ''
$results | Format-Table -AutoSize Module, Status, Result, Detail, Note | Out-String | Write-Host
$pass = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
$fail = @($results | Where-Object { $_.Status -ne 'PASS' }).Count
Write-Host ("heap tests: {0} passed, {1} failed, {2} total" -f $pass, $fail, $results.Count)
exit $fail
