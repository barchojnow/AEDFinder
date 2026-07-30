<#
.SYNOPSIS
    Runs the Connect IQ unit tests across several devices in one go.

.DESCRIPTION
    The Connect IQ simulator only ever simulates one device at a time, so
    "all devices at once" means a sequential loop: build a unit-test
    binary per device, run it, collect the result.

    That single-device limit is also the reason this script restarts the
    simulator between devices instead of reusing one instance. Pushing a
    binary built for device B into a simulator currently running device A
    makes it discard the loaded app ("Unsupported app was removed:
    ...PRG") and re-initialise for the new device - and monkeydo is left
    waiting for a handshake from an app that no longer exists. It never
    times out on its own, so the run simply hangs, with the simulator
    sitting on its idle screen.

    Restarting is not quite enough on its own, because the simulator
    persists its session and only writes it on a clean exit. So the
    restart closes the window first and only kills what refuses to go,
    and there is no fixed "it must be ready by now" constant: each
    monkeydo call is bounded by -TimeoutSec and retried up to -Retries
    times with a longer settle each attempt. A device that times out on
    every attempt is a real failure; one that succeeds on the second was
    the simulator not being ready, which is not worth a red build.

    The tested logic (GeoMath, AedTiles, AedList, ProximityAlerts) is
    device-independent, so running all 65 products is mostly redundant -
    what differs per device is memory and compilation, and `Export
    Project` already covers compilation everywhere. The default list is
    the representative set: tightest memory and no compass (fr55), oldest
    API (fenix5), touch (venu2), newest hardware (fenix847mm).

.EXAMPLE
    .\tools\run-tests.ps1
    .\tools\run-tests.ps1 -Devices fenix5,venu2
    .\tools\run-tests.ps1 -All                 # every product in manifest.xml
    .\tools\run-tests.ps1 -KeepSimulator       # reuse one instance (fast, flaky)
#>

param(
    [string[]] $Devices = @('fr55', 'fenix5', 'venu2', 'fenix847mm'),
    [switch]   $All,
    [string]   $DeveloperKey,
    # Per-attempt ceiling on the monkeydo call. A healthy run finishes
    # in well under ten seconds, so anything near this is a hang and
    # waiting longer only delays the retry that actually fixes it.
    [int]      $TimeoutSec = 45,
    # Extra attempts per device after a timeout, each with a longer
    # simulator settle.
    [int]      $Retries = 2,
    # Reuse a single simulator instance. Faster, but only reliable when
    # every run targets the same device.
    [switch]   $KeepSimulator
)

$ErrorActionPreference = 'Stop'
$project = Resolve-Path "$PSScriptRoot\.."
$jungle  = Join-Path $project 'monkey.jungle'
$outDir  = Join-Path $project 'bin\test'

# Developer key: usually kept outside the repo (it must never be
# committed). Look in the usual spots unless one was passed in.
if (-not $DeveloperKey) {
    $candidates = @(
        "$project\..\..\developer_key",   # vs_projects\developer_key
        "$project\..\developer_key",      # aed_finder\developer_key
        "$env:APPDATA\Garmin\ConnectIQ\developer_key"
    )
    $DeveloperKey = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $DeveloperKey -or -not (Test-Path $DeveloperKey)) {
    throw "Developer key not found. Pass it explicitly: .\tools\run-tests.ps1 -DeveloperKey C:\path\to\developer_key"
}
$DeveloperKey = (Resolve-Path $DeveloperKey).Path
Write-Host "Developer key: $DeveloperKey" -ForegroundColor DarkGray

# Locate the active SDK the same way the VS Code extension does.
$sdkCfg = Join-Path $env:APPDATA 'Garmin\ConnectIQ\current-sdk.cfg'
if (Test-Path $sdkCfg) {
    $sdk = (Get-Content $sdkCfg -Raw).Trim()
} else {
    $sdk = (Get-ChildItem "$env:APPDATA\Garmin\ConnectIQ\Sdks" -Directory |
            Sort-Object Name -Descending | Select-Object -First 1).FullName
}
$monkeyc   = Join-Path $sdk 'bin\monkeyc.bat'
$monkeydo  = Join-Path $sdk 'bin\monkeydo.bat'
$simulator = Join-Path $sdk 'bin\simulator.exe'

if ($All) {
    $Devices = ([xml](Get-Content (Join-Path $project 'manifest.xml'))).
        manifest.application.products.product.id
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# The simulator's IPC listener. monkeydo's shell.exe scans this range to
# find it - which is also why a leftover shell from the previous device
# breaks the next one: it still holds the port the new shell needs.
$script:CiqPorts = 1234..1238

# $true when something is listening on the CIQ range, $false when the
# range is clear, $null when it cannot be determined (Get-NetTCPConnection
# needs the NetTCPIP module, which is not everywhere).
function Test-CiqPortListening {
    try {
        $conns = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
                   Where-Object { $script:CiqPorts -contains $_.LocalPort })
        return ($conns.Count -gt 0)
    } catch {
        return $null
    }
}

# Waits for the CIQ port to reach $Listening. Returns $false on timeout,
# and $true immediately when the state can't be read - the caller then
# falls back to a plain sleep rather than blocking on an unanswerable
# question.
function Wait-CiqPort {
    param([bool] $Listening, [int] $TimeoutSec = 30)

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $state = Test-CiqPortListening
        if ($null -eq $state) { return $true }
        if ($state -eq $Listening) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# monkeydo.bat launches shell.exe, and shell.exe - not the batch file -
# is what actually holds the connection to the simulator. It is not
# reliably a child of the batch process, so killing the batch's process
# tree can leave it running, still occupying the CIQ port. The next
# device's push then has nowhere to connect and hangs forever, which is
# the one failure mode that survives a simulator restart and is why
# restarting alone did not fix this.
#
# Matched by path, not just by name: only the SDK's own shell.exe is
# ever killed.
function Stop-CiqShell {
    Get-Process -Name 'shell' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Path -and $_.Path.StartsWith($sdk, [System.StringComparison]::OrdinalIgnoreCase)
        } |
        ForEach-Object { try { $_.Kill() } catch { } }
}

function Stop-Simulator {
    Stop-CiqShell

    $procs = @(Get-Process -Name 'simulator' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) {
        Wait-CiqPort -Listening $false -TimeoutSec 5 | Out-Null
        return
    }

    # Ask politely before killing. The simulator persists its session -
    # last device, last loaded app - and only writes that state on a
    # clean exit. Killed outright it comes back up on a half-written
    # session, tries to restore a .prg built for a different device
    # ("Unsupported app was removed: ...PRG"), and can end up refusing
    # the push that follows. That is the exact failure this function
    # exists to prevent, so it must not cause it.
    foreach ($p in $procs) {
        try { $p.CloseMainWindow() | Out-Null } catch { }
    }
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Process -Name 'simulator' -ErrorAction SilentlyContinue) -and
           (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }

    # Anything that ignored the request gets killed anyway - a stuck
    # simulator is worse than a lost session file.
    Get-Process -Name 'simulator' -ErrorAction SilentlyContinue |
        ForEach-Object {
            try { $_.Kill() } catch { }
        }
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Process -Name 'simulator' -ErrorAction SilentlyContinue) -and
           (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }

    # The listening socket outlives the process briefly, and connecting
    # into that gap looks exactly like a hang. Wait for the port to
    # actually clear rather than guessing how long that takes.
    Stop-CiqShell
    if (-not (Wait-CiqPort -Listening $false -TimeoutSec 15)) {
        Write-Host '  warning: CIQ port still held after shutdown' -ForegroundColor DarkYellow
    }
}

function Start-Simulator {
    param([int] $SettleSec = 4)

    Start-Process -FilePath $simulator | Out-Null
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Get-Process -Name 'simulator' -ErrorAction SilentlyContinue) -and
           (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    if (-not (Get-Process -Name 'simulator' -ErrorAction SilentlyContinue)) {
        throw "The Connect IQ simulator did not start ($simulator)"
    }

    # The process exists well before its IPC listener does. Waiting for
    # the port to open is a real readiness signal, so the settle below is
    # only a small cushion on top of it rather than a guess standing in
    # for one - on machines where the port state can't be read, it is the
    # fallback and the retry loop lengthens it each attempt.
    if (Wait-CiqPort -Listening $true -TimeoutSec 30) {
        Start-Sleep -Milliseconds 1200
    } else {
        Write-Host '  warning: simulator never opened its port' -ForegroundColor DarkYellow
        Start-Sleep -Seconds $SettleSec
    }
}

# Runs monkeydo with a hard ceiling, returning its output or $null on
# timeout. The whole process tree is killed on timeout: monkeydo.bat is
# a wrapper around a java process, and killing only the wrapper leaves
# java holding the simulator connection, which poisons the next device.
function Invoke-MonkeyDo {
    param([string] $Prg, [string] $Device, [int] $TimeoutSec)

    $stdout = Join-Path $outDir "$Device.out.log"
    $stderr = Join-Path $outDir "$Device.err.log"

    $proc = Start-Process -FilePath $monkeydo `
        -ArgumentList @($Prg, $Device, '/t') `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null
        # ...and the shell separately: it is what holds the port, and it
        # does not always die with the batch file that started it.
        Stop-CiqShell
        return $null
    }

    $text = ''
    if (Test-Path $stdout) { $text += (Get-Content $stdout -Raw) }
    if (Test-Path $stderr) { $text += (Get-Content $stderr -Raw) }

    # Even a clean run can leave shell.exe behind. The output has already
    # been read by this point, so there is nothing to lose by making sure
    # the port is free for whatever runs next.
    Stop-CiqShell
    return $text
}

if ($KeepSimulator -and
    -not (Get-Process -Name 'simulator' -ErrorAction SilentlyContinue)) {
    Write-Host 'Starting the Connect IQ simulator...' -ForegroundColor DarkGray
    Start-Simulator
}

$results = @()

foreach ($device in $Devices) {
    Write-Host "`n=== $device ===" -ForegroundColor Cyan
    $prg = Join-Path $outDir "AEDFinderTest-$device.prg"
    $started = Get-Date

    & $monkeyc -f $jungle -o $prg -y $DeveloperKey -d $device --unit-test 2>&1 |
        Where-Object { $_ -notmatch 'WARNING' }
    if ($LASTEXITCODE -ne 0) {
        $results += [pscustomobject]@{
            Device = $device; Result = 'BUILD FAILED'; Seconds = 0
        }
        continue
    }

    # Retry loop. A timeout here is almost never the code - the same
    # binary passes when its device is run on its own - it is the
    # simulator not being ready for the push. Rather than model Garmin's
    # startup state machine, give it another go with a longer settle:
    # cheap, and it turns a flaky external process into a deterministic
    # script. A genuine hang still fails, it just takes $Retries
    # attempts to say so.
    $output = $null
    for ($attempt = 1; $attempt -le ($Retries + 1); $attempt++) {
        if (-not $KeepSimulator) {
            $settle = 3 + (2 * $attempt)   # 5s, 7s, 9s...
            if ($attempt -gt 1) {
                Write-Host "retry $attempt/$($Retries + 1) (settle ${settle}s)..." `
                    -ForegroundColor Yellow
            } else {
                Write-Host 'restarting simulator...' -ForegroundColor DarkGray
            }
            Stop-Simulator
            Start-Simulator -SettleSec $settle
        }

        # Note: on Windows monkeydo takes slash-flags (/t), not -t.
        $output = Invoke-MonkeyDo -Prg $prg -Device $device -TimeoutSec $TimeoutSec
        if ($null -ne $output) { break }

        Write-Host "  timed out after ${TimeoutSec}s - killed" -ForegroundColor DarkYellow
        # A timed-out run leaves the simulator in an unknown state, so
        # never hand it to the next attempt or the next device.
        Stop-Simulator
        if ($KeepSimulator) { break }
    }

    $elapsed = [int]((Get-Date) - $started).TotalSeconds

    if ($null -eq $output) {
        Write-Host "TIMEOUT after $($Retries + 1) attempts" -ForegroundColor Red
        Write-Host "  log: $(Join-Path $outDir "$device.out.log")" -ForegroundColor DarkGray
        $results += [pscustomobject]@{
            Device = $device; Result = "TIMEOUT (${TimeoutSec}s x$($Retries + 1))"
            Seconds = $elapsed
        }
        continue
    }

    Write-Host $output

    $summary = $output -split "`r?`n" |
        Select-String -Pattern '^(PASSED|FAILED)' | Select-Object -First 1
    $results += [pscustomobject]@{
        Device  = $device
        Result  = if ($summary) { $summary.Line.Trim() } else { 'NO RESULT' }
        Seconds = $elapsed
    }
}

if (-not $KeepSimulator) {
    Stop-Simulator
}

Write-Host "`n================ SUMMARY ================" -ForegroundColor Yellow
$results | Format-Table -AutoSize
if ($results | Where-Object { $_.Result -notlike 'PASSED*' }) { exit 1 }
