@echo off
rem Repair and verify an installed panel without running the MSFS SDK.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" -UpdateScript
if errorlevel 1 (
  echo.
  echo SimPilot Link repair failed. Read the message above, then press any key to close.
  pause >nul
  exit /b 1
)
echo.
echo Repair finished. Restart MSFS, then open SimPilot Link and check its displayed build.
echo A diagnostic report is saved in SimPilot-Link-diagnostics.log in this folder.
pause >nul
