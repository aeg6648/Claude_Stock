@echo off
REM Korean Stock Mock Portfolio dashboard launcher
REM 더블클릭하면: (1) GitHub에서 클라우드 에이전트의 최신 상태 pull, (2) dashboard.html 생성, (3) 브라우저로 엽니다.
REM PC가 꺼진 동안 클라우드에서 진행된 매매 기록도 함께 동기화됩니다.

cd /d "%~dp0\.."
echo [1/2] GitHub 동기화 중...
git pull --rebase origin main
if errorlevel 1 (
  echo.
  echo [WARN] git pull 실패. 오프라인이거나 충돌 가능성. 로컬 캐시로 계속 진행합니다.
  echo.
)

echo [2/2] 대시보드 생성 중...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_dashboard.ps1"
if errorlevel 1 (
  echo.
  echo [ERROR] dashboard 생성 실패. 위 메시지를 확인하세요.
  pause
)
