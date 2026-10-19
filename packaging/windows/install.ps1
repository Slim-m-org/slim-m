# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Lays this extracted zip out as the per-user install that can update itself
# (docs/decisions/0041): %LOCALAPPDATA%\slim-m\app-<version>\, a slim-m.exe
# launcher, and a `current` pointer file. Touches nothing outside the profile
# and needs no elevation.
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$versionFile = Join-Path $here 'VERSION'
if (-not (Test-Path $versionFile)) {
  throw 'run this from the extracted slim-m zip; it has no VERSION file beside it'
}
$version = (Get-Content $versionFile -Raw).Trim()

$root = Join-Path $env:LOCALAPPDATA 'slim-m'
New-Item -ItemType Directory -Force $root | Out-Null

$unpack = Join-Path $root ".unpack-$version"
$target = Join-Path $root "app-$version"
$closeFirst = "could not replace $target; close slim-m (including its tray icon) and run this again"

function Remove-Folder($path) {
  if (-not (Test-Path $path)) { return }
  try {
    Remove-Item -Recurse -Force $path -ErrorAction Stop
  } catch {
    throw $closeFirst
  }
  if (Test-Path $path) { throw $closeFirst }
}

Remove-Folder $unpack
Copy-Item -Recurse $here $unpack
Remove-Folder $target
Move-Item $unpack $target

Copy-Item (Join-Path $here 'slim-m.exe') (Join-Path $root 'slim-m.exe') -Force

function Set-Pointer($name, $value) {
  $temp = Join-Path $root ".$name.new"
  Set-Content -Path $temp -Value $value -NoNewline
  Move-Item -Force $temp (Join-Path $root $name)
}

$currentFile = Join-Path $root 'current'
if (Test-Path $currentFile) {
  $before = (Get-Content $currentFile -Raw).Trim()
  if ($before -and $before -ne $version) { Set-Pointer 'previous' $before }
}
Set-Pointer 'current' $version

$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut(
  (Join-Path ([Environment]::GetFolderPath('Programs')) 'slim-m.lnk'))
$shortcut.TargetPath = Join-Path $root 'slim-m.exe'
$shortcut.Save()

Write-Host "installed slim-m $version in $root; start it from the Start menu"
