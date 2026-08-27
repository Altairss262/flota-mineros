@echo off
title Encender el monitor de mineros
echo.
echo   Encendiendo el monitor...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0programar-actualizacion.ps1" -Minutos 2
echo.
pause
