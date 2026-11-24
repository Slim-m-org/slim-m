# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Removes the per-user install that install.ps1 laid out, mirroring what the setup's
# uninstaller does: the app folders, the launcher, the shortcut, the slimm:// scheme,
# the notification identity and the start-on-login entry. Your data under
# %APPDATA%\top.npcserver\slim-m stays unless -RemoveData is given.
param([switch]$RemoveData)
$ErrorActionPreference = 'Stop'

$root = Join-Path $env:LOCALAPPDATA 'slim-m'

Get-Process -Name 'slimm_app' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'slim-m.lnk'
if (Test-Path $shortcut) { Remove-Item -Force $shortcut }

$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$login = (Get-ItemProperty -Path $run -Name 'slim-m' -ErrorAction SilentlyContinue).'slim-m'
if ($login -and $login.ToLowerInvariant().Contains($root.ToLowerInvariant() + '\')) {
  Remove-ItemProperty -Path $run -Name 'slim-m'
}

foreach ($key in @(
    'HKCU:\Software\Classes\slimm',
    'HKCU:\Software\Classes\AppUserModelId\top.npcserver.slimm',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\top.npcserver.slimm')) {
  if (Test-Path $key) { Remove-Item -Recurse -Force $key }
}

if (Test-Path $root) { Remove-Item -Recurse -Force $root }

if ($RemoveData) {
  $data = Join-Path $env:APPDATA 'top.npcserver\slim-m'
  if (Test-Path $data) { Remove-Item -Recurse -Force $data }
  $parent = Split-Path -Parent $data
  if ((Test-Path $parent) -and -not (Get-ChildItem $parent -Force)) { Remove-Item -Force $parent }
}

Write-Host "removed slim-m from $root"
if (-not $RemoveData) {
  Write-Host 'your data is kept; run this again with -RemoveData to delete it too'
}
