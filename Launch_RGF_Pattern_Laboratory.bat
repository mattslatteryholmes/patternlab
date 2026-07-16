@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RGFPatternLaboratory.ps1"
echo.
pause
