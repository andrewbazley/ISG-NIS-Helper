@echo off
REM  ISG-NIS-Helper build launcher.
REM
REM  If you use conda: activate the environment first, then TYPE build.bat
REM  in that same window. Double-clicking opens a fresh shell with no
REM  environment active and the build would use the wrong Python.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
echo.
pause
