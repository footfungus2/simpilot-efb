@echo off
rem Starts the SimPilot EFB bridge on the MSFS PC. Requires Node.js 20+ (https://nodejs.org).
cd /d "%~dp0"
where node >nul 2>&1 || goto :node_required
node -e "process.exit(Number(process.versions.node.split('.')[0]) >= 20 ? 0 : 1)" >nul 2>&1 || goto :node_required
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
exit /b 1

:node_required
echo Node.js 20 or newer is required to run the SimPilot bridge.
echo Opening the Node.js download page. Install the LTS version, then double-click this file again.
start "" "https://nodejs.org/en/download"
pause
exit /b 1
