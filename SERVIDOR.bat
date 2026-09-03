@echo off
title DASHBOARD EN VIVO
color 0A
cls
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SERVIDOR.ps1"
pause
