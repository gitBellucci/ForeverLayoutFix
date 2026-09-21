@echo off
setlocal
cd /d "%~dp0"
echo ForeverLayoutFix setup / publish
echo Close WoW first.
echo This copies your saved layout profile into the addon folder so alts can load it.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0FLF_Setup.ps1"
if errorlevel 1 (
  echo.
  echo Setup did not finish.
)
echo.
pause
