@echo off
title Apagar el monitor de mineros
echo.
echo   Apagando el monitor...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0programar-actualizacion.ps1" -Quitar
echo.
echo   El dashboard seguira online, pero con los ultimos datos guardados.
echo.
pause
