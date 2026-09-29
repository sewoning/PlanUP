@echo off
REM PlanUP mail sync - one-time setup. Double-click this file.
REM (ASCII only on purpose: cmd.exe garbles Korean in .bat files.)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0planup-mail-sync.ps1" -InstallTask
echo.
pause
