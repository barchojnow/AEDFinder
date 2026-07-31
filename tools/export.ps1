<#
.SYNOPSIS
    Builds the signed .iq package for the Connect IQ store.

.DESCRIPTION
    Runs the pre-flight checks, then packages every product in the
    manifest into one .iq file.

    The check worth having is the last one: it compares the grid the app
    was compiled against with the grid actually being served from GitHub
    Pages, and refuses to build if they disagree. That mismatch is
    invisible in every other test - the watch compiles, the tiles are
    valid, the Python suite is green - and it produces an app that
    returns "no AED nearby" everywhere, for everyone. It has already
    happened once: the grid moved to 0.03 while Pages kept serving 0.05.

.EXAMPLE
    .\tools\export.ps1
    .\tools\export.ps1 -SkipTests          # after a green run-tests.ps1
#>
[CmdletBinding()]
param(
    [string] $DeveloperKey,
    [string] $OutFile,
    # The Monkey C suite needs a simulator per device and takes minutes;
    # skip it when run-tests.ps1 has just passed.
    [switch] $SkipTests,
    # Ship anyway. For a data outage you have already diagnosed - not
    # for one you have just been told about.
    [switch] $IgnoreLiveData
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$jungle  = Join-Path $project 'monkey.jungle'
if (-not $OutFile) { $OutFile = Join-Path $project 'bin\AEDFinder.iq' }

function Write-Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Write-Ok($text)   { Write-Host "   $text" -ForegroundColor Green }

# --- static checks ---------------------------------------------------

# Same discovery as run-tests.ps1: `py` is the Windows launcher and the
# most reliable way in. Not `??` - that is PowerShell 7 only, and this
# has to run under the 5.1 that ships with Windows.
$py = if (Get-Command py -ErrorAction SilentlyContinue) { 'py' } else { 'python' }

Write-Step 'Grid agreement and source structure'
& $py (Join-Path $project 'tools\check_grid.py')    | Out-Null
if ($LASTEXITCODE) { throw 'check_grid.py failed' }
& $py (Join-Path $project 'tools\check_sources.py') | Out-Null
if ($LASTEXITCODE) { throw 'check_sources.py failed' }
Write-Ok 'grid and sources consistent'

if (-not $SkipTests) {
    Write-Step 'Python suite'
    # From the project root, so pytest.ini is the rootdir. Anywhere else
    # and collection drags in bin/ and gen/.
    Push-Location $project
    try { & $py -m pytest -q } finally { Pop-Location }
    if ($LASTEXITCODE) { throw 'pytest failed' }
}

# --- the published data ----------------------------------------------

Write-Step 'Published data matches the compiled grid'
$localGrid = (Get-Content (Join-Path $project 'tools\build_tiles.py') |
    Select-String -Pattern '^CELL_DEG\s*=\s*([\d.]+)').Matches[0].Groups[1].Value

try {
    $live = Invoke-RestMethod -Uri 'https://barchojnow.github.io/AEDFinder/meta.json' `
                              -TimeoutSec 20
    $liveGrid = $live.grid.cellDeg
    if ("$liveGrid" -ne "$localGrid") {
        $message = @"
Published data is on a different grid than this build.

    this build serves cells of : $localGrid deg
    Pages is currently serving : $liveGrid deg
    published                  : $($live.generated)

Every user of this package would request tile paths that do not exist
and see "no AED nearby". Run the 'Build AED tiles' workflow, wait for
the Pages deploy, then export again.
"@
        if ($IgnoreLiveData) { Write-Warning $message }
        else { throw $message }
    }
    Write-Ok "Pages serving $liveGrid deg, $($live.aedCount) AEDs, published $($live.generated)"
} catch [System.Net.WebException], [System.Net.Http.HttpRequestException] {
    # Not fatal on its own: no network here says nothing about the data.
    Write-Warning "Could not reach GitHub Pages to verify the live data: $($_.Exception.Message)"
}

# --- package ---------------------------------------------------------

if (-not $DeveloperKey) {
    $DeveloperKey = @(
        "$project\..\..\developer_key",
        "$project\..\developer_key",
        "$env:APPDATA\Garmin\ConnectIQ\developer_key"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $DeveloperKey -or -not (Test-Path $DeveloperKey)) {
    throw "Developer key not found. Pass it explicitly: .\tools\export.ps1 -DeveloperKey C:\path\to\developer_key"
}
$DeveloperKey = (Resolve-Path $DeveloperKey).Path

$sdkCfg = Join-Path $env:APPDATA 'Garmin\ConnectIQ\current-sdk.cfg'
$sdk = if (Test-Path $sdkCfg) { (Get-Content $sdkCfg -Raw).Trim() }
       else { (Get-ChildItem "$env:APPDATA\Garmin\ConnectIQ\Sdks" -Directory |
               Sort-Object Name -Descending | Select-Object -First 1).FullName }
$monkeyc = Join-Path $sdk 'bin\monkeyc.bat'

Write-Step 'Packaging'
New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null

# -e packages every product in the manifest into one .iq; -r builds
# release rather than debug. No -d: the store build is not per-device.
& $monkeyc -f $jungle -o $OutFile -y $DeveloperKey -e -r
if ($LASTEXITCODE) { throw "monkeyc failed with exit code $LASTEXITCODE" }

$size = [math]::Round((Get-Item $OutFile).Length / 1MB, 2)
Write-Ok "$OutFile ($size MB)"

Write-Host @"

Next:
  1. https://apps.garmin.com/developer/dashboard -> upload $([IO.Path]::GetFileName($OutFile))
  2. Icon and copy: store\LISTING.md
  3. Screenshots: capture from the simulator, see the list in LISTING.md
"@ -ForegroundColor DarkGray
