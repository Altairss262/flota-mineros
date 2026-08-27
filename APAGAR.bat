@echo off
title APAGAR monitor
color 0C
cls
echo.
echo   ================================
echo      APAGANDO EL MONITOR
echo   ================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Unregister-ScheduledTask -TaskName 'MonitorFlotaMineros' -Confirm:$false -ErrorAction Stop; Write-Host '   LISTO. El monitor esta APAGADO.' } catch { Write-Host '   Ya estaba apagado.' }"
echo.
echo   El dashboard sigue online con los ultimos datos.
echo.
echo   Para volver a encenderlo: doble clic en ENCENDER.bat
echo.
pause
