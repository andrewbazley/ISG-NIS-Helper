@echo off
REM  ISG-NIS-Helper install launcher.
REM  RIGHT-CLICK THIS FILE AND CHOOSE "RUN AS ADMINISTRATOR".
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
