@echo off
setlocal
set "APP_DIR=%~dp0app"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%APP_DIR%\runtime\Start.ps1" -AppDirectory "%APP_DIR%"
endlocal
