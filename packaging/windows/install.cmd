@echo off
rem SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
rem Double-click entry for install.ps1, which Windows would otherwise refuse to run from a download.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
rem Keep a double-clicked window open only when there is a failure to read.
if errorlevel 1 pause
