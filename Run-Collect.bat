@echo off
REM  Double-click this when something looks wrong.
REM  It gathers the config, pre-scan, tasks, self-tests, health state and
REM  recent events into one folder and one zip under install-logs\.
REM  PINs are redacted. No image data is included.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ISG-NIS-Helper-Collect.ps1" %*
echo.
pause
