<#
    run-heap-tests.ps1 — automated heap test runner (see ../docs/HEAP_TEST_SUITE_DESIGN.md §10).

    For each test module it:
      1. starts a fresh `sim68k --gdb` RSP stub,
      2. drives it with `m68k-elf-gdb <module>.elf -nx --batch -x heaptest.gdb`
         (which `load`s the program, breaks at `_tdone`, and prints RESULT=/DETAIL=),
      3. parses the RESULT, applies a watchdog, and tears the sim down.

    Exit code = number of non-passing modules (0 = all pass), for CI.

    Usage:
      nmake test                                  # canonical one-step: build + run + verdict (CI)
      pwsh -File test\run-heap-tests.ps1                 # build + run the default modules
      pwsh -File test\run-heap-tests.ps1 -Modules stub   # a single module
      pwsh -File test\run-heap-tests.ps1 -NoBuild        # skip the nmake build step
      pwsh -File test\run-heap-tests.ps1 -Port 4321 -TimeoutSec 40

    A FAIL row's Note decodes RESULT=$0000PPCC as "phase P, check 0xCC"; DETAIL is the
    failing value/code (see the module source for that check).
#>
[CmdletBinding()]
param(
    [string[]] $Modules    = @('stub', 'test_kit', 'test_create', 'test_block', 'test_soa', 'test_debug', 'test_errors', 'test_stress', 'test_edges', 'test_aligned'),
    [int]      $TimeoutSec = 20,        # per-module watchdog (storm/hang cutoff)
    [int]      $Port       = 1234,
    [switch]   $NoBuild,
    [string]   $Sim = (Join-Path (Split-Path -Parent $PSScriptRoot) 'toolchain\windows\sim68k.exe'),
    [string]   $Gdb = (Join-Path (Split-Path -Parent $PSScriptRoot) 'toolchain\windows\m68k-elf-gdb.exe'),
    [string]   $ReportPath = ''
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$SourceRoot = Join-Path $RepoRoot 'src'
$OutputRoot = Join-Path $RepoRoot 'out'
$BinaryRoot = Join-Path $OutputRoot 'bin'
Set-Location -LiteralPath $PSScriptRoot

$GdbScript = Join-Path $PSScriptRoot 'heaptest.gdb'
$Modules = @($Modules | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ($ReportPath) { $ReportPath = [IO.Path]::GetFullPath($ReportPath) }

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

function Stop-OwnedProcess($process) {
    if ($null -eq $process) { return }
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    $process.WaitForExit()
    $process.Dispose()
}

function Assert-PortFree([int]$p) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $p)
    try { $listener.Start() }
    catch [Net.Sockets.SocketException] { throw "heap tests: port $p is already in use" }
    finally { $listener.Stop() }
}

function Wait-Port([int]$p, [int]$timeoutMs = 5000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $c = [System.Net.Sockets.TcpClient]::new()
        try {
            if ($c.ConnectAsync('127.0.0.1', $p).Wait(200)) { $c.Close(); return $true }
        } catch [AggregateException] {
            if ($_.Exception.InnerException -isnot [Net.Sockets.SocketException] -or
                $_.Exception.InnerException.SocketErrorCode -ne [Net.Sockets.SocketError]::ConnectionRefused) {
                throw
            }
        }
        finally { $c.Dispose() }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Record([string]$path) {
    $file = Get-Item $path
    return [ordered]@{ path=$file.FullName; bytes=$file.Length; sha256=(Get-FileHash $path -Algorithm SHA256).Hash }
}

if (-not $NoBuild) {
    Write-Host "Building test ELFs (nmake tests)..."
    Push-Location -LiteralPath $RepoRoot
    try { $buildLog = & nmake tests 2>&1 }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) {
        $buildLog | Select-Object -Last 25 | ForEach-Object { Write-Host $_ }
        Write-Error "build failed (nmake exit $LASTEXITCODE)"; exit 255
    }
}

$results = @()
$simProc = $null
$gdbProc = $null
$temporaryFiles = [Collections.Generic.List[string]]::new()
$commands = [IO.Path]::GetTempFileName()
$temporaryFiles.Add($commands)
$scriptLines = @(Get-Content $GdbScript)
if (@($scriptLines | Where-Object { $_ -match '^target remote ' }).Count -ne 1) {
    throw 'heap tests: expected exactly one RSP endpoint in heaptest.gdb'
}
$scriptLines -replace '^target remote .+$', "target remote 127.0.0.1:$Port" |
    Set-Content $commands -Encoding ascii

try {
foreach ($m in $Modules) {
    $elf = Join-Path $BinaryRoot "$m.elf"
    if (-not (Test-Path -LiteralPath $elf)) {
        $results += [pscustomobject]@{ Module=$m; Status='NOBUILD'; Result='--------'; Detail='--------'; Note='ELF not found' }
        continue
    }

    Assert-PortFree $Port
    $simOut = [System.IO.Path]::GetTempFileName()
    $temporaryFiles.Add($simOut)
    $temporaryFiles.Add("$simOut.err")
    $simProc = Start-Process -FilePath $Sim -ArgumentList '--gdb', "$Port" `
                 -PassThru -WindowStyle Hidden -RedirectStandardOutput $simOut -RedirectStandardError "$simOut.err"

    if (-not (Wait-Port $Port 5000)) {
        Stop-OwnedProcess $simProc
        $simProc = $null
        Remove-Item $simOut, "$simOut.err" -ErrorAction SilentlyContinue
        $results += [pscustomobject]@{ Module=$m; Status='NOSIM'; Result='--------'; Detail='--------'; Note="RSP port $Port did not open" }
        continue
    }

    $gdbOut = [System.IO.Path]::GetTempFileName()
    $temporaryFiles.Add($gdbOut)
    $temporaryFiles.Add("$gdbOut.err")
    $gdbProc = Start-Process -FilePath $Gdb -ArgumentList "`"$elf`"", '-nx', '--batch', '-x', "`"$commands`"" `
             -PassThru -WindowStyle Hidden -RedirectStandardOutput $gdbOut -RedirectStandardError "$gdbOut.err"

    $exited = $gdbProc.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) {
        Stop-OwnedProcess $gdbProc
        $gdbProc = $null
        Stop-OwnedProcess $simProc
        $simProc = $null
        Remove-Item $simOut, "$simOut.err", $gdbOut, "$gdbOut.err" -ErrorAction SilentlyContinue
        $results += [pscustomobject]@{ Module=$m; Status='TIMEOUT'; Result='--------'; Detail='--------'; Note="watchdog > $TimeoutSec s (storm/hang)" }
        continue
    }
    $gdbProc.WaitForExit()   # ensure redirected streams are flushed

    $gdbExit = $gdbProc.ExitCode
    $out = (Get-Content $gdbOut -Raw) + "`n" + (Get-Content "$gdbOut.err" -Raw)
    if ($ReportPath) {
        $logDir = Join-Path (Split-Path $ReportPath -Parent) 'logs'
        New-Item -ItemType Directory -Force $logDir | Out-Null
        [IO.File]::WriteAllText((Join-Path $logDir "$m-gdb.log"), $out)
    }
    Stop-OwnedProcess $gdbProc
    $gdbProc = $null
    Stop-OwnedProcess $simProc
    $simProc = $null
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
    if ($res -eq '00000000' -and $gdbExit -eq 0) {
        $results += [pscustomobject]@{ Module=$m; Status='PASS'; Result=$res; Detail=$det; Note=''; Elf=Record $elf; Source=Record "$m.a68"; GdbExit=$gdbExit }
    } else {
        $note = if ($gdbExit) { "gdb exit $gdbExit" } else { Get-ResultNote $m $res }
        $results += [pscustomobject]@{ Module=$m; Status='FAIL'; Result=$res; Detail=$det; Note=$note; Elf=Record $elf; Source=Record "$m.a68"; GdbExit=$gdbExit }
    }
}
}
finally {
    Stop-OwnedProcess $gdbProc
    Stop-OwnedProcess $simProc
    foreach ($file in $temporaryFiles) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
}

Write-Host ''
$results | Format-Table -AutoSize Module, Status, Result, Detail, Note | Out-String | Write-Host
$pass = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
$fail = @($results | Where-Object { $_.Status -ne 'PASS' }).Count
Write-Host ("heap tests: {0} passed, {1} failed, {2} total" -f $pass, $fail, $results.Count)
if ($ReportPath) {
    $sources = @(Get-ChildItem $SourceRoot -File | Where-Object {
        $_.Extension -eq '.a68' -or $_.Name -eq 'heap.inc'
    } | Sort-Object Name | ForEach-Object { Record $_.FullName })
    $report = [ordered]@{
        schema=1;phase='NM1-upstream';port=$Port;passed=$pass;failed=$fail;total=$results.Count
        simulator=Record $Sim;gdb=Record $Gdb;runner=Record $PSCommandPath
        gdbScript=Record $GdbScript;testKit=Record (Join-Path $PSScriptRoot 'heaptestkit.inc')
        library=Record (Join-Path $OutputRoot 'lib\libheap.a')
        librarySources=$sources
        tests=$results
    }
    New-Item -ItemType Directory -Force (Split-Path $ReportPath -Parent) | Out-Null
    $report | ConvertTo-Json -Depth 8 | Set-Content $ReportPath -Encoding UTF8
}
exit $fail
