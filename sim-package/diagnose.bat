@echo off
rem Collect panel hashes and bridge status without changing the installed panel.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" -DiagnosticsOnly
if errorlevel 1 (
  echo.
  echo Could not collect the report. Read the error above, then press any key to close.
  pause >nul
  exit /b 1
)
echo.
echo Review SimPilot-Link-diagnostics.log in this folder before sharing it.
pause >nul
