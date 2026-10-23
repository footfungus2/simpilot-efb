@echo off
rem One-click launcher for building and installing SimPilot Link.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1"
if errorlevel 1 (
  echo.
  echo SimPilot Link installation failed. Read the message above, then press any key to close.
  pause >nul
  exit /b 1
)
echo.
echo Installation finished. Press any key to close.
pause >nul
