@echo off
chcp 65001 >nul

title Remote-Freund Connection Manager
powershell.exe -ExecutionPolicy Bypass -File "connection-manager-v2-fixed.ps1"