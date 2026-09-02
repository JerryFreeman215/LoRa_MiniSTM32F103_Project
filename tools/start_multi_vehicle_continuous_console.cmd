@echo off
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%multi_vehicle_console.ps1" -Pulses 0 -SafetyLockMs 58000
pause
