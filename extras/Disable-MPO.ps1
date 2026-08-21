<#
.SYNOPSIS
    Turn off Windows Multi-Plane Overlay. REQUIRES ADMINISTRATOR. Last resort.

.DESCRIPTION
    Read extras\README.md before running this. It is here for completeness,
    not because you are likely to need it: once the one pixel of overscan is
    in place, MPO is almost never what is left flashing.

    What it is. MPO lets the compositor hand certain windows straight to the
    display engine, skipping composition. The driver enters and leaves that
    path on its own, based on what happens to be on screen, and every
    transition can make the panel resynchronise: a black of anything from a
    fraction of a second to a full second.

    It is intermittent by design, and that is exactly what "it worked for two
    minutes and then started flickering again" feels like. Nothing in your
    settings changed. What changed was what MPO decided to do.

    It is the most common cause of flicker on NVIDIA with several monitors
    running at different refresh rates - say a 240 Hz main panel next to a
    60 Hz second one.

    The change is a single registry value and it is reversible, but it is
    machine-wide, it affects every application and not just this game, and it
    needs a REBOOT (or at least a dwm.exe restart) to take effect. That is
    three good reasons to exhaust the other fixes first.

.PARAMETER Undo
    Put MPO back the way Windows ships it.

.EXAMPLE
    # Open PowerShell as administrator, then:
    .\Disable-MPO.ps1
    .\Disable-MPO.ps1 -Undo
#>
[CmdletBinding()]
param([switch] $Undo)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ''
    Write-Host '  This one needs administrator rights.' -ForegroundColor Yellow
    Write-Host '  Right-click PowerShell, "Run as administrator", and try again.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Nothing else in this repository needs elevation - only this.' -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}

$key = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'
$name = 'OverlayTestMode'

Write-Host ''
if ($Undo) {
    Remove-ItemProperty -LiteralPath $key -Name $name -ErrorAction SilentlyContinue
    Write-Host '  MPO restored to the Windows default.' -ForegroundColor Green
} else {
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -LiteralPath $key -Name $name -Value 5 -PropertyType DWord -Force | Out-Null
    Write-Host '  MPO disabled (OverlayTestMode = 5).' -ForegroundColor Green
}

$v = (Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction SilentlyContinue).$name
if ($null -eq $v) { Write-Host '  current value: not set (default)' -ForegroundColor DarkGray }
else { Write-Host ("  current value: {0}" -f $v) -ForegroundColor DarkGray }

Write-Host ''
Write-Host '  REBOOT for this to take effect.' -ForegroundColor Cyan
Write-Host ''
