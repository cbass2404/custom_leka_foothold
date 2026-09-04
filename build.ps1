<#
.SYNOPSIS
    Compiles customizations/*.lua into bundled Lua files at the repo root.

.DESCRIPTION
    The mission loads one file via a DO SCRIPT FILE / dofile entry (see README).
    Keeping the sources split per feature and compiling them here means the
    mission side never has to change when a customization is added or dropped.

    Two bundles are produced:
      customizations.lua      every source, less anything -Exclude removes
      ww2_customizations.lua  only the sources named in $Ww2Sources below

    Each source is wrapped in its own do ... end block. Lua caps a scope at 200
    locals, and concatenation would otherwise pool every file's top level locals
    into one chunk scope until the whole build failed to load. The wrapper also
    makes concatenation behave exactly like the separate dofile calls the files
    were written for: file local stays file local, globals still cross freely.

.PARAMETER Exclude
    File names to leave out, with or without the .lua extension. Accepts
    wildcards. Applies to both bundles: an explicit exclude is a stronger
    signal than the WW2 include list, so an excluded file appears in neither.
    Omit to compile everything.

.PARAMETER SourceDir
    Directory to compile from. Defaults to customizations/ beside this script.

.PARAMETER OutFile
    Full bundle output path. Defaults to customizations.lua at the repo root.

.PARAMETER Ww2OutFile
    WW2 bundle output path. Defaults to ww2_customizations.lua at the repo root.

.PARAMETER NoWw2
    Skip the WW2 bundle and build only the full one.

.PARAMETER SkipUpstreamCheck
    Build without first running check-upstream.ps1. The check is the gate that
    catches a Foothold re-pull having renamed something customizations/ reads,
    so skipping it can ship a bundle that loads cleanly and then does nothing.
    Intended for working on a bundle while a known upstream break is unfixed.

.EXAMPLE
    .\build.ps1
    Runs the upstream contract check, then builds both bundles.

.EXAMPLE
    .\build.ps1 -Exclude hmd_enforcer
    Builds both, with the HMD enforcer left out of each.

.EXAMPLE
    .\build.ps1 -NoWw2
    Builds only customizations.lua.
#>
[CmdletBinding()]
param(
    [string[]] $Exclude = @(),
    [string]   $SourceDir,
    [string]   $OutFile,
    [string]   $Ww2OutFile,
    [switch]   $NoWw2,
    [switch]   $SkipUpstreamCheck
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Sources that belong in the WW2 bundle. Add a file name here to include it;
# names may be written with or without the .lua extension, and wildcards work.
# Anything not listed is simply not part of that bundle.
# --------------------------------------------------------------------------
$Ww2Sources = @(
    'comm_nav_menu.lua'
)

$root = $PSScriptRoot

# --------------------------------------------------------------------------
# Upstream contract gate.
#
# Runs before anything is compiled. Lekas-Foothold is re-pulled after every
# upstream release, and a rename there does not break the build or the load:
# the bundle compiles, the mission starts, and a report quietly comes out empty
# on the server. Checking here means the failure lands on this machine, at the
# moment of building, rather than in front of pilots.
#
# Quiet, so a passing check costs one line and stays out of the build output.
# --------------------------------------------------------------------------
if (-not $SkipUpstreamCheck) {
    $checkScript = Join-Path $root 'check-upstream.ps1'

    if (-not (Test-Path -LiteralPath $checkScript)) {
        throw "Upstream check not found: $checkScript (use -SkipUpstreamCheck to build anyway)"
    }

    & $checkScript -Quiet

    # The check prints its own report. Adding a PowerShell error record on top
    # would bury it, so this just says how to proceed and stops.
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Build stopped: upstream contract check failed.' -ForegroundColor Red
        Write-Host 'Run .\check-upstream.ps1 for the full report, or .\build.ps1 -SkipUpstreamCheck to build regardless.'
        exit 1
    }

    Write-Host 'Upstream contract check passed.' -ForegroundColor Green
}

if (-not $SourceDir)  { $SourceDir  = Join-Path $root 'customizations' }
if (-not $OutFile)    { $OutFile    = Join-Path $root 'customizations.lua' }
if (-not $Ww2OutFile) { $Ww2OutFile = Join-Path $root 'ww2_customizations.lua' }

if (-not (Test-Path -LiteralPath $SourceDir)) {
    throw "Source directory not found: $SourceDir"
}

# Match a name list against the available sources, tolerating a missing .lua
# extension so 'comm_nav_menu' and 'comm_nav_menu.lua' both work.
function Resolve-Sources {
    param(
        [object[]] $Available,
        [string[]] $Patterns,
        [string]   $Label
    )

    $matched = @()
    foreach ($pattern in $Patterns) {
        $bare = $pattern -replace '\.lua$', ''
        $hits = @($Available | Where-Object { $_.BaseName -like $bare -or $_.Name -like $pattern })

        # A name that matches nothing is almost always a typo or a file that got
        # renamed out from under the list. Silence here ships the wrong bundle:
        # an exclude that quietly does nothing, or a WW2 bundle missing a feature.
        if ($hits.Count -eq 0) {
            Write-Warning "$Label '$pattern' matched no file in $SourceDir."
            continue
        }

        $matched += $hits
    }

    return @($matched | Sort-Object Name -Unique)
}

# Sorted so the order does not depend on how the filesystem happens to enumerate
# the directory: a git diff then shows real edits rather than reordering noise.
# Only the header timestamp changes between two builds of unchanged sources.
$all = @(Get-ChildItem -LiteralPath $SourceDir -Filter '*.lua' -File | Sort-Object Name)

if ($all.Count -eq 0) {
    throw "No .lua files found in $SourceDir"
}

$excluded = Resolve-Sources -Available $all -Patterns $Exclude -Label 'Exclude'
$included = @($all | Where-Object { $excluded -notcontains $_ })

if ($included.Count -eq 0) {
    throw "Every source was excluded - refusing to write an empty bundle"
}

function Write-LuaBundle {
    param(
        [object[]] $Sources,
        [string]   $Path,
        [string]   $Selection,
        [object[]] $Omitted = @()
    )

    $nl = "`r`n"
    $rule = '-- ' + ('=' * 74)
    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.Append("$rule$nl")
    [void]$sb.Append("-- GENERATED FILE - DO NOT EDIT$nl")
    [void]$sb.Append("--$nl")
    [void]$sb.Append("-- Built from customizations/ by build.ps1. Edit the sources there and$nl")
    [void]$sb.Append("-- rebuild; any change made here is lost on the next build.$nl")
    [void]$sb.Append("--$nl")
    [void]$sb.Append("-- Built    : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))$nl")
    [void]$sb.Append("-- Contents : $Selection$nl")
    [void]$sb.Append("-- Sources  : $($Sources.Count) file(s)$nl")
    foreach ($f in $Sources) { [void]$sb.Append("--            $($f.Name)$nl") }
    if ($Omitted.Count -gt 0) {
        [void]$sb.Append("--$nl")
        [void]$sb.Append("-- Omitted  : $($Omitted.Count) file(s)$nl")
        foreach ($f in $Omitted) { [void]$sb.Append("--            $($f.Name)$nl") }
    }
    [void]$sb.Append("$rule$nl")

    foreach ($f in $Sources) {
        $body = [System.IO.File]::ReadAllText($f.FullName)
        $body = $body -replace '\s+$', ''   # trailing blank lines, so spacing is ours

        [void]$sb.Append($nl)
        [void]$sb.Append("$rule$nl")
        [void]$sb.Append("-- BEGIN $($f.Name)$nl")
        [void]$sb.Append("$rule$nl")
        [void]$sb.Append("do$nl")
        [void]$sb.Append($body)
        [void]$sb.Append("${nl}end$nl")
        [void]$sb.Append("-- END $($f.Name)$nl")
    }

    # UTF-8 with no BOM. A BOM is not a Lua comment: it would land before the
    # first token and the mission would fail to load the whole file.
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))

    Write-Host "Built $Path"
    Write-Host "  $($Sources.Count) file(s): $(($Sources | ForEach-Object Name) -join ', ')"
    if ($Omitted.Count -gt 0) {
        Write-Host "  omitted $($Omitted.Count): $(($Omitted | ForEach-Object Name) -join ', ')"
    }
}

Write-LuaBundle -Sources $included -Path $OutFile `
    -Selection 'all customizations' -Omitted $excluded

if (-not $NoWw2) {
    $ww2 = @(Resolve-Sources -Available $included -Patterns $Ww2Sources -Label 'WW2 source')

    if ($ww2.Count -eq 0) {
        # Leaving a stale bundle on disk is worse than not building one: the
        # mission would keep loading yesterday's file with no sign anything failed.
        Write-Warning "No WW2 sources resolved - $Ww2OutFile was not rebuilt."
        if (Test-Path -LiteralPath $Ww2OutFile) {
            Write-Warning "  the existing $Ww2OutFile is now STALE."
        }
    }
    else {
        Write-LuaBundle -Sources $ww2 -Path $Ww2OutFile `
            -Selection 'WW2 subset (see $Ww2Sources in build.ps1)'
    }
}

# Explicit, because the upstream gate above exits 1 on failure and that makes
# this script's exit code meaningful. Without it a successful build leaves
# $LASTEXITCODE at whatever the previous command set, which reads as a failure.
exit 0
