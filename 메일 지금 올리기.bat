@echo off
REM PlanUP mail sync - run once now.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0planup-mail-sync.ps1"
echo.
pause
