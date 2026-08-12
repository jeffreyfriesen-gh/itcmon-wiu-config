@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launch-ITCM-Truck-Client.ps1" -InstallRoot "%~dp0." -ProfileName "truck-client" -TruckHost "telemetry-node.lan" -DiagnoseOnly
set "ITCM_EXIT=%errorlevel%"
echo.
if "%ITCM_EXIT%"=="0" (
  echo Diagnostics completed. The persistent log and status paths are shown above.
) else (
  echo Diagnostics found an invalid or incomplete installation.
)
pause
exit /b %ITCM_EXIT%
