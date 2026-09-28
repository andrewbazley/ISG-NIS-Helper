@echo off
REM  Double-click this to run the ISG-NIS-Helper pre-install scan.
REM  It reads this computer and writes three files next to this script.
REM  It changes nothing else.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ISG-NIS-Helper-PreScan.ps1" %*
echo.
pause
