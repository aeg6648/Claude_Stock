@echo off
REM Korean Stock Mock Portfolio dashboard launcher
REM Step 1: git pull from GitHub to sync cloud agent writes
REM Step 2: regenerate dashboard.html
REM Step 3: open in default browser
REM Works after laptop reboot - all state lives in JSON/MD files.

setlocal
cd /d "%~dp0\.."

echo === Step 1/2: Sync from GitHub ===
git pull --rebase origin main
if errorlevel 1 (
  echo.
  echo [WARN] git pull failed. Offline or conflict. Continuing with local cache.
  echo.
)

echo.
echo === Step 2/2: Build dashboard ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_dashboard.ps1"
if errorlevel 1 (
  echo.
  echo [ERROR] Dashboard build failed. See messages above.
  pause
  exit /b 1
)

endlocal
