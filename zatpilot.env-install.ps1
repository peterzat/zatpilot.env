<#
.SYNOPSIS
    Windows launcher for zatpilot.env-install.sh.

.DESCRIPTION
    The installer, like the rest of this repo, is bash. This launcher exists
    so a Windows user can install from the shell they already have open
    instead of hunting for a Git Bash prompt. It locates bash.exe, reports
    the two prerequisites clearly when they are missing, and hands over to
    the real installer with any arguments passed through.

    There is deliberately no install logic here. One installer, one place
    where the wiring is defined; this file only finds an interpreter for it.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\zatpilot.env-install.ps1
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $InstallerArgs
)

$ErrorActionPreference = 'Stop'

function Find-BashExe {
    $onPath = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $candidates = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }

    # Git for Windows records its install root here when present.
    try {
        $root = (Get-ItemProperty 'HKLM:\SOFTWARE\GitForWindows' -ErrorAction Stop).InstallPath
        $fromRegistry = Join-Path $root 'bin\bash.exe'
        if (Test-Path -LiteralPath $fromRegistry) { return $fromRegistry }
    } catch { }

    return $null
}

$bash = Find-BashExe
if (-not $bash) {
    Write-Host 'ERROR: Git Bash is required and was not found.' -ForegroundColor Red
    Write-Host '  Install it with:  winget install Git.Git'
    Write-Host '  Then re-run this script from a new terminal.'
    exit 1
}

if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    Write-Host 'ERROR: jq is required and was not found.' -ForegroundColor Red
    Write-Host '  Install it with:  winget install jqlang.jq'
    Write-Host '  Then re-run this script from a new terminal.'
    exit 1
}

# Developer Mode is not required, but without it the installer falls back to
# junctions and copies, and copies go stale after a pull. Say so up front
# rather than letting the installer's warning be the first the user hears.
$devMode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
if ($devMode -ne 1) {
    Write-Host 'NOTE: Developer Mode is off, so this account cannot create symbolic links.' -ForegroundColor Yellow
    Write-Host '      The installer will use junctions and file copies instead, and copies'
    Write-Host '      must be refreshed by re-running the installer after every pull.'
    Write-Host '      Turn it on at Settings > System > For developers for live links.'
    Write-Host ''
}

$installer = Join-Path $PSScriptRoot 'zatpilot.env-install.sh'
if (-not (Test-Path -LiteralPath $installer)) {
    Write-Host "ERROR: cannot find $installer" -ForegroundColor Red
    exit 1
}

# Let bash do the path translation rather than guessing at drive-letter
# rewriting rules that differ between Git for Windows builds.
$posixInstaller = (& $bash -c "cygpath -u '$installer'") | Select-Object -First 1
if (-not $posixInstaller) {
    Write-Host 'ERROR: could not translate the installer path for bash.' -ForegroundColor Red
    exit 1
}

& $bash -lc "'$posixInstaller' $($InstallerArgs -join ' ')"
exit $LASTEXITCODE
