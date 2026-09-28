@echo off
REM  ISG-NIS-Helper uninstall launcher.
REM  RIGHT-CLICK THIS FILE AND CHOOSE "RUN AS ADMINISTRATOR".
REM  Removes the scheduled tasks, the programs, the state folder, the
REM  build workspace and this folder. It asks before touching your logs.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
echo.
pause
