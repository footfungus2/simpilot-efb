@echo off
rem Starts the SimPilot EFB bridge on the MSFS PC. Requires Node.js 20+ (https://nodejs.org).
cd /d "%~dp0"
if not exist node_modules (
  echo Installing dependencies...
  call npm ci --include=dev --no-audit --no-fund || goto :fail
)
echo.
echo  SimPilot EFB bridge - leave this window open while you fly.
echo  If Windows Firewall asks, allow access on PRIVATE networks so the iPad can connect.
echo.
call npm start || goto :fail
goto :eof

:fail
echo Bridge setup or startup failed.
pause
