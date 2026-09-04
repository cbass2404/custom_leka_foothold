<#
.SYNOPSIS
    Verifies that vendored Foothold still provides everything customizations/ borrows.

.DESCRIPTION
    Lekas-Foothold is vendored and re-pulled after every upstream release. Our
    scripts run inside that mission and read a small number of its globals,
    methods and table fields. Nothing warns when one of those is renamed or
    dropped: the script simply loads, and a report comes out empty or a menu
    never appears - in DCS, on the server, in front of pilots.

    This runs that list against the vendored source and fails loudly instead.
    build.ps1 calls it before compiling, so a re-pull that moved something
    stops the build rather than shipping a bundle that loads and does nothing.

    It also checks the language server library list in .vscode/settings.json,
    where a wrong path and an oversized file both fail in silence.

    WHAT IT CANNOT DO
    Every check is a text search over upstream source. It proves a name is still
    written somewhere in the file - not that the value behind it still means what
    it meant, and not that a field still hangs off the table we expect. A rename
    or a deletion is caught reliably; a change of meaning is not. Fields with
    common names are marked WEAK in the output for that reason.

.PARAMETER Quiet
    Print only failures and the final summary. Used by build.ps1 so a passing
    check stays out of the way of the build output.

.EXAMPLE
    .\check-upstream.ps1
    Full report, one line per check.

.EXAMPLE
    .\check-upstream.ps1 -Quiet
    Only what is broken.

.OUTPUTS
    Exit code 0 if every check passed, 1 if any failed.
#>
[CmdletBinding()]
param(
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# --------------------------------------------------------------------------
# Upstream files the contract is checked against.
# --------------------------------------------------------------------------
$Files = @{
    zoneCommander = 'Lekas-Foothold/Common Scripts/zoneCommanderv2.lua'
    coldwarSetup  = 'Lekas-Foothold/Setup files/COLDWAR_SETUP.lua'
}

# --------------------------------------------------------------------------
# The contract.
#
# One entry per thing customizations/ borrows from Foothold. Add an entry when
# our code starts reading a new upstream name - the same edit that adds the file
# to Lua.workspace.library in .vscode/settings.json.
#
#   Symbol   what we depend on, as our code writes it
#   File     key into $Files above
#   Pattern  .NET regex proving upstream still defines it. Anchored to the
#            definition site wherever there is one, so an incidental mention
#            elsewhere in a 3 MB file cannot pass the check on its own.
#   Used     where we consume it, so a failure points straight at the caller
#   Why      what breaks in the mission if it goes
#   Weak     name common enough that a hit is not strong evidence
#   Private  underscore-private upstream; no stability promise at all
# --------------------------------------------------------------------------
$Contract = @(
    # ---- BattleCommander ------------------------------------------------
    @{
        Symbol  = 'BattleCommander:getZones()'
        File    = 'zoneCommander'
        Pattern = 'function\s+BattleCommander:getZones\s*\('
        Used    = 'comm_nav_menu: BuildThreatenedZoneSet, ReportObjectives, ReportLandingZones, Arm'
        Why     = 'every zone-driven report; without it the nav menu never arms'
    }
    @{
        Symbol  = 'BattleCommander:getZones() returns an array'
        File    = 'zoneCommander'
        Pattern = 'function\s+BattleCommander:getZones\s*\(\s*\)\s*return\s+self\.zones'
        Used    = 'comm_nav_menu: every ipairs(bc:getZones())'
        Why     = 'we iterate with ipairs; a keyed table would yield nothing and report no zones at all'
    }
    @{
        Symbol  = 'BattleCommander.CAREER_AIRCRAFT'
        File    = 'zoneCommander'
        Pattern = 'BattleCommander\.CAREER_AIRCRAFT\s*=\s*\{'
        Used    = 'comm_nav_menu: AuditProfileCoverage'
        Why     = 'the airframe profile audit silently stops checking; a missing profile then ships unnoticed'
    }
    @{
        Symbol  = 'CAREER_AIRCRAFT[*].typeNames'
        File    = 'zoneCommander'
        Pattern = 'typeNames\s*=\s*\{'
        Used    = 'comm_nav_menu: AuditProfileCoverage inner loop'
        Why     = 'same audit; we iterate definition.typeNames'
    }
    @{
        Symbol  = 'bc._zoneAttackFlashes'
        File    = 'zoneCommander'
        Pattern = '_zoneAttackFlashes\s*=\s*\{\}'
        Used    = 'comm_nav_menu: BuildThreatenedZoneSet'
        Why     = 'zones under air attack stop being marked threatened in the objectives report'
        Private = $true
    }
    @{
        Symbol  = 'bc._zoneAttackFlashes keyed by zone name'
        File    = 'zoneCommander'
        Pattern = '_zoneAttackFlashes\[\s*zoneObj\.zone\s*\]'
        Used    = 'comm_nav_menu: for zoneName in pairs(bc._zoneAttackFlashes)'
        Why     = 'we use the key as a zone name; re-keying would mark the wrong zones threatened'
        Private = $true
    }

    # ---- Frontline ------------------------------------------------------
    @{
        Symbol  = 'Frontline (global)'
        File    = 'zoneCommander'
        Pattern = '(?m)^Frontline\s*=\s*Frontline\s+or\s+\{\}'
        Used    = 'comm_nav_menu: ObjectiveStatus'
        Why     = 'FRONT vs REAR classification falls back to unknown for every zone'
    }
    @{
        Symbol  = 'Frontline.ZoneDistToFrontNm(zoneName)'
        File    = 'zoneCommander'
        Pattern = 'function\s+Frontline\.ZoneDistToFrontNm\s*\('
        Used    = 'comm_nav_menu: ObjectiveStatus, NavFrontlineThresholdNm'
        Why     = 'no zone is ever reported FRONT; the threshold setting becomes dead'
    }

    # ---- ZoneCommander fields -------------------------------------------
    @{
        Symbol = 'zone.zone'; File = 'zoneCommander'; Pattern = 'zoneObj\.zone'
        Used = 'comm_nav_menu: zone naming throughout'
        Why  = 'zone names disappear from every report row'
        Weak = $true
    }
    @{
        Symbol = 'zone.side'; File = 'zoneCommander'; Pattern = 'zoneObj\.side'
        Used = 'comm_nav_menu: ZoneIsObjective, ObjectiveStatus, ReportLandingZones'
        Why  = 'red/blue/neutral cannot be told apart; objectives and landing fields both break'
        Weak = $true
    }
    @{
        Symbol = 'zone.airbaseName'; File = 'zoneCommander'; Pattern = 'airbaseName'
        Used = 'comm_nav_menu: GetZonePoint, ReportLandingZones'
        Why  = 'friendly landing zones lose their airfield lookup'
    }
    @{
        Symbol = 'zone.facility'; File = 'zoneCommander'; Pattern = 'obj\.facility\s*='
        Used = 'comm_nav_menu: ReportLandingZones eligibility'
        Why  = 'airframe-appropriate fields can no longer be filtered'
    }
    @{
        Symbol = 'zone.built'; File = 'zoneCommander'; Pattern = 'obj\.built\s*=\s*\{\}'
        Used = 'comm_nav_menu: DescribeDefences'
        Why  = 'the defences column empties; objectives report as undefended'
    }
    @{
        Symbol = 'zone.groups'; File = 'zoneCommander'; Pattern = 'obj\.groups\s*=\s*\{\}'
        Used = 'comm_nav_menu: BuildThreatenedZoneSet'
        Why  = 'inbound red attack groups stop being seen'
    }
    @{
        Symbol = 'zone.active'; File = 'zoneCommander'; Pattern = 'obj\.active\s*=\s*true'
        Used = 'comm_nav_menu: ZoneIsVisible'
        Why  = 'inactive zones start appearing in reports'
    }
    @{
        Symbol = 'zone.suspended'; File = 'zoneCommander'; Pattern = 'obj\.suspended\s*=\s*false'
        Used = 'comm_nav_menu: ZoneIsVisible'
        Why  = 'suspended zones start appearing in reports'
    }
    @{
        Symbol = 'zone.isHidden'; File = 'zoneCommander'; Pattern = 'isHidden'
        Used = 'comm_nav_menu: ZoneIsVisible'
        Why  = 'hidden zones leak into reports and give away mission state'
    }
    @{
        Symbol = 'zone.pendingCapture'; File = 'zoneCommander'; Pattern = 'pendingCapture'
        Used = 'comm_nav_menu: BuildThreatenedZoneSet'
        Why  = 'zones mid-capture stop being flagged threatened'
    }
    @{
        Symbol = 'zone.NeutralAtStart'; File = 'zoneCommander'; Pattern = 'NeutralAtStart'
        Used = 'comm_nav_menu: ZoneIsObjective'
        Why  = 'neutral capturable zones drop out of the objectives list'
    }
    @{
        Symbol = 'zone.firstCaptureByRed'; File = 'zoneCommander'; Pattern = 'firstCaptureByRed'
        Used = 'comm_nav_menu: ZoneIsObjective'
        Why  = 'neutral zones already taken once are misclassified'
    }

    # ---- GroupCommander -------------------------------------------------
    @{
        Symbol = 'groupCommander.mission == "attack"'; File = 'zoneCommander'
        Pattern = "mission\s*==\s*'attack'"
        Used = 'comm_nav_menu: BuildThreatenedZoneSet'
        Why  = 'attacking groups are no longer distinguished from patrols or supply runs'
    }
    @{
        Symbol = 'groupCommander.targetzone'; File = 'zoneCommander'; Pattern = 'targetzone'
        Used = 'comm_nav_menu: BuildThreatenedZoneSet'
        Why  = 'we cannot tell which zone an attack group is headed for'
    }
    @{
        Symbol = 'groupCommander.state values'; File = 'zoneCommander'
        Pattern = "'(inair|landed|enroute|atdestination)'"
        Used = 'comm_nav_menu: ACTIVE_GROUP_STATES'
        Why  = 'in-flight attacks are treated as inactive and never reported as threats'
    }

    # ---- Setup ----------------------------------------------------------
    @{
        Symbol  = 'bc = BattleCommander:new(...)'
        File    = 'coldwarSetup'
        Pattern = '(?m)^\s*bc\s*=\s*BattleCommander:new\s*\('
        Used    = 'comm_nav_menu: every use of bc'
        Why     = 'the global the whole nav menu hangs off; without it the menu never arms'
    }
)

# --------------------------------------------------------------------------
# Run the contract. Each upstream file is read once - zoneCommanderv2 is 3 MB
# and there is no reason to pay for that per check.
# --------------------------------------------------------------------------
$results = @()
$sources = @{}

foreach ($key in $Files.Keys) {
    $path = Join-Path $root $Files[$key]

    if (-not (Test-Path -LiteralPath $path)) {
        # A missing file is not one failed check, it is every check against it.
        # Say so once here rather than emitting a wall of identical failures.
        $results += [pscustomobject]@{
            Status = 'FAIL'
            Symbol = "(source) $($Files[$key])"
            Detail = 'not found - is Lekas-Foothold checked out?'
            Used   = ''
            Why    = 'the entire contract against this file is unverifiable'
            Tags   = ''
        }
        $sources[$key] = $null
        continue
    }

    $sources[$key] = [System.IO.File]::ReadAllText($path)
}

foreach ($check in $Contract) {
    $text = $sources[$check.File]

    if ($null -eq $text) { continue }   # already reported as a missing source

    $count = [regex]::Matches($text, $check.Pattern).Count

    $tags = @()
    if ($check.Private) { $tags += 'PRIVATE' }
    if ($check.Weak)    { $tags += 'WEAK' }

    $results += [pscustomobject]@{
        Status = $(if ($count -gt 0) { 'ok' } else { 'FAIL' })
        Symbol = $check.Symbol
        Detail = $(if ($count -gt 0) { "$count match(es)" } else { 'no match in upstream source' })
        Used   = $check.Used
        Why    = $check.Why
        Tags   = ($tags -join ' ')
    }
}

# --------------------------------------------------------------------------
# Language server library list.
#
# Both failure modes here are silent: lua-language-server ignores a path that
# does not exist without a word, and skips a file over preloadFileSize the same
# way. Either one leaves an upstream global untyped, which reads in the editor
# as a bug in our code rather than a misconfiguration.
# --------------------------------------------------------------------------
$settingsPath = Join-Path $root '.vscode/settings.json'

if (-not (Test-Path -LiteralPath $settingsPath)) {
    $results += [pscustomobject]@{
        Status = 'FAIL'; Symbol = '.vscode/settings.json'; Detail = 'not found'
        Used = 'editor only'; Why = 'no upstream typing in the editor'; Tags = ''
    }
}
else {
    # Strip // line comments so this parses as plain JSON. Safe for this file:
    # the only strings in it are relative paths, none of which contain '//'.
    $json = [System.IO.File]::ReadAllText($settingsPath) -replace '(?m)^\s*//.*$', ''
    $settings = $json | ConvertFrom-Json

    $capKb = $settings.'Lua.workspace.preloadFileSize'
    if (-not $capKb) { $capKb = 500 }   # lua-language-server default

    foreach ($entry in $settings.'Lua.workspace.library') {
        $libPath = Join-Path $root $entry
        $item = Get-Item -LiteralPath $libPath -ErrorAction SilentlyContinue

        if (-not $item) {
            $results += [pscustomobject]@{
                Status = 'FAIL'
                Symbol = "library: $entry"
                Detail = 'path does not exist'
                Used   = '.vscode/settings.json'
                Why    = 'silently ignored by the language server; the globals it defines stay untyped'
                Tags   = ''
            }
            continue
        }

        # Only files are size-capped; a directory is walked entry by entry.
        if ($item.PSIsContainer) {
            $results += [pscustomobject]@{
                Status = 'ok'; Symbol = "library: $entry"; Detail = 'directory, present'
                Used = '.vscode/settings.json'; Why = ''; Tags = ''
            }
            continue
        }

        $sizeKb = [math]::Round($item.Length / 1KB)

        if ($sizeKb -gt $capKb) {
            $results += [pscustomobject]@{
                Status = 'FAIL'
                Symbol = "library: $entry"
                Detail = "$sizeKb KB exceeds preloadFileSize $capKb KB"
                Used   = '.vscode/settings.json'
                Why    = 'skipped without warning; raise Lua.workspace.preloadFileSize'
                Tags   = ''
            }
            continue
        }

        $results += [pscustomobject]@{
            Status = 'ok'; Symbol = "library: $entry"
            Detail = "$sizeKb KB, under the $capKb KB cap"
            Used = '.vscode/settings.json'; Why = ''; Tags = ''
        }
    }
}

# --------------------------------------------------------------------------
# Report.
# --------------------------------------------------------------------------
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })

if (-not $Quiet) {
    Write-Host ''
    Write-Host 'Upstream contract' -ForegroundColor Cyan
    Write-Host ('-' * 78)

    foreach ($r in $results) {
        if ($r.Status -eq 'ok') {
            $tag = if ($r.Tags) { " [$($r.Tags)]" } else { '' }
            Write-Host '  ok    ' -ForegroundColor Green -NoNewline
            Write-Host ("{0}{1}" -f $r.Symbol, $tag) -NoNewline
            Write-Host ("  - {0}" -f $r.Detail) -ForegroundColor DarkGray
        }
        else {
            Write-Host '  FAIL  ' -ForegroundColor Red -NoNewline
            Write-Host $r.Symbol -ForegroundColor Red
        }
    }

    Write-Host ''
}

if ($failed.Count -gt 0) {
    Write-Host 'Broken by upstream' -ForegroundColor Red
    Write-Host ('-' * 78)

    foreach ($r in $failed) {
        Write-Host ''
        Write-Host ("  {0}" -f $r.Symbol) -ForegroundColor Red
        Write-Host ("    what happened : {0}" -f $r.Detail)
        if ($r.Used) { Write-Host ("    we use it in  : {0}" -f $r.Used) }
        if ($r.Why)  { Write-Host ("    breaks        : {0}" -f $r.Why) }
    }

    Write-Host ''
    Write-Host ("{0} of {1} checks failed." -f $failed.Count, $results.Count) -ForegroundColor Red
    Write-Host 'Fix the callers, or update the contract in this script if upstream renamed something deliberately.'
    Write-Host ''
    exit 1
}

if (-not $Quiet) {
    Write-Host ("All {0} checks passed." -f $results.Count) -ForegroundColor Green
    Write-Host ''
}

exit 0
