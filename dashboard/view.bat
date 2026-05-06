@echo off
REM Korean Stock Mock Portfolio dashboard launcher
REM 더블클릭하면 PowerShell 스크립트가 dashboard.html을 생성하고 브라우저로 엽니다.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_dashboard.ps1"
if errorlevel 1 (
  echo.
  echo [ERROR] dashboard 생성 실패. 위 메시지를 확인하세요.
  pause
)
