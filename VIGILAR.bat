@echo off
title VIGILANCIA CONTINUA DE FLOTA
color 0B
mode con: cols=90 lines=34
cls
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0VIGILAR.ps1"
pause
