@echo off
title Estado de la flota
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t = Get-ScheduledTask -TaskName 'MonitorFlotaMineros' -ErrorAction SilentlyContinue; if ($t) { Write-Host ''; Write-Host '  MONITOR: ENCENDIDO' -ForegroundColor Green; $i = Get-ScheduledTaskInfo -TaskName 'MonitorFlotaMineros'; Write-Host ('  ultima vez: ' + $i.LastRunTime); Write-Host ('  proxima vez: ' + $i.NextRunTime) } else { Write-Host ''; Write-Host '  MONITOR: APAGADO' -ForegroundColor Yellow }; Write-Host ''"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0recolector.ps1" -SinSubir -SinAvisos -Ver
echo.
pause
