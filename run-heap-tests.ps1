<#
    run-heap-tests.ps1 — automated heap test runner (see HEAP_TEST_SUITE_DESIGN.md §10).

    For each test module it:
      1. starts a fresh `sim68k --gdb` RSP stub,
      2. drives it with `m68k-elf-gdb <module>.elf -nx --batch -x heaptest.gdb`
         (which `load`s the program, breaks at `_tdone`, and prints RESULT=/DETAIL=),
      3. parses the RESULT, applies a watchdog, and tears the sim down.

    Exit code = number of non-passing modules (0 = all pass), for CI.

    Usage:
      pwsh -File run-heap-tests.ps1                 # build + run the default modules
      pwsh -File run-heap-tests.ps1 -Modules stub   # a specific module
      pwsh -File run-heap-tests.ps1 -NoBuild        # skip the nmake build step
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

# $PPCC (module-scoped) / sentinel decode table — keep in step with the test modules.
$KnownCodes = @{
    '0000FFFF'      = 'sentinel: did not reach _tdone (storm / hang / early-out)'
    'stub:00000101' = 'stub: machine heap handle is NULL'
    'stub:00000102' = 'stub: heap header magic != HEAP'
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

foreach ($m in $Modules) {
    $elf = "$m.elf"
    if (-not (Test-Path -LiteralPath $elf)) {
        $results += [pscustomobject]@{ Module=$m; Status='NOBUILD'; Result='--------'; Detail='--------'; Note='ELF not found' }
        continue
    }

    Stop-AllSim
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
        $results += [pscustomobject]@{ Module=$m; Status='NORESULT'; Result='--------'; Detail='--------'; Note='no RESULT= line from gdb' }
        continue
    }

    $res = $mt.Groups[1].Value.ToUpper()
    $det = $mt.Groups[2].Value.ToUpper()
    if ($res -eq '00000000') {
        $results += [pscustomobject]@{ Module=$m; Status='PASS'; Result=$res; Detail=$det; Note='' }
    } else {
        $note = $KnownCodes["${m}:$res"]
        if (-not $note) { $note = $KnownCodes[$res] }
        if (-not $note) { $note = 'unknown code (see the module source)' }
        $results += [pscustomobject]@{ Module=$m; Status='FAIL'; Result=$res; Detail=$det; Note=$note }
    }
}

Stop-AllSim

Write-Host ''
$results | Format-Table -AutoSize Module, Status, Result, Detail, Note | Out-String | Write-Host
$pass = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
$fail = @($results | Where-Object { $_.Status -ne 'PASS' }).Count
Write-Host ("heap tests: {0} passed, {1} failed, {2} total" -f $pass, $fail, $results.Count)
exit $fail
