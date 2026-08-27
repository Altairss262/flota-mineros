@echo off
title ENCENDER monitor
color 0A
cls
echo.
echo   ================================
echo      ENCENDIENDO EL MONITOR
echo   ================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0programar-actualizacion.ps1" -Minutos 2
echo.
echo   Dashboard: https://altairss262.github.io/flota-mineros
echo.
pause
