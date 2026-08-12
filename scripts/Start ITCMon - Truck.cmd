@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launch-ITCM-Truck-Client.ps1" -InstallRoot "%~dp0." -ProfileName "truck-client" -TruckHost "telemetry-node.lan" -LaunchTarget ITCMon %*
set "ITCM_EXIT=%errorlevel%"
if not "%ITCM_EXIT%"=="0" (
  echo.
  echo ITCMon could not be started. The error and log path are shown above.
  pause
)
exit /b %ITCM_EXIT%
