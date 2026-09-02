@echo off
title VIGILANCIA DE FLOTA
color 0B
mode con: cols=88 lines=40
cls
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0VIGILAR.ps1" -Segundos 20
pause
