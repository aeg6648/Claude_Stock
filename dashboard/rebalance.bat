@echo off
REM rebalance.bat - one-click portfolio processing
REM 1. git pull
REM 2. fetch fresh prices from Hankyung
REM 3. apply AGGRESSIVE rules and execute up to 4 trades
REM 4. update all state files
REM 5. rebuild dashboard.html + trades.html
REM 6. git commit + push
REM 7. open dashboard.html in browser

setlocal
echo ========================================
echo  Korean Stock Portfolio - Rebalance
echo ========================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0rebalance.ps1"
if errorlevel 1 (
  echo.
  echo [ERROR] Rebalance failed. See messages above.
  pause
  exit /b 1
)

endlocal
echo.
echo Press any key to close...
pause >nul
