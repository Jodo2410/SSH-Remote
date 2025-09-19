@echo off
chcp 65001 >nul
title Ziel-PC Setup für Remote-Freund

:: Admin-Rechte prüfen
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo FEHLER: Dieses Skript muss als Administrator ausgeführt werden!
    echo Rechtsklick auf die Datei und "Als Administrator ausführen" wählen
    pause
    exit /b 1
)

echo ======================================
echo   Ziel-PC Setup für Remote-Freund
echo ======================================
echo.

:: SSH-Server installieren
echo [1/4] Installiere OpenSSH Server...
powershell -Command "Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'"
powershell -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"

if %errorlevel% equ 0 (
    echo     ✓ SSH-Server erfolgreich installiert
) else (
    echo     ✗ Fehler bei SSH-Server Installation
    goto error
)

:: SSH-Service konfigurieren
echo [2/4] Konfiguriere SSH-Service...
powershell -Command "Set-Service -Name sshd -StartupType 'Automatic'"
powershell -Command "Start-Service sshd"

if %errorlevel% equ 0 (
    echo     ✓ SSH-Service gestartet
) else (
    echo     ✗ Fehler beim Starten des SSH-Service
    goto error
)

:: Firewall-Regel hinzufügen
echo [3/4] Konfiguriere Windows Firewall...
powershell -Command "New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22" >nul 2>&1

if %errorlevel% equ 0 (
    echo     ✓ Firewall-Regel hinzugefügt
) else (
    echo     ✓ Firewall-Regel bereits vorhanden oder hinzugefügt
)

:: PowerShell Execution Policy setzen
echo [4/4] Konfiguriere PowerShell...
powershell -Command "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force"

if %errorlevel% equ 0 (
    echo     ✓ PowerShell Execution Policy gesetzt
) else (
    echo     ✗ Fehler bei PowerShell-Konfiguration
)

echo.
echo ======================================
echo         Setup erfolgreich!
echo ======================================
echo.
echo Der Ziel-PC ist jetzt bereit für Remote-Verbindungen:
echo.
echo ✓ SSH-Server installiert und gestartet
echo ✓ Windows Firewall konfiguriert
echo ✓ PowerShell bereit
echo.
echo Nächste Schritte:
echo 1. Start.bat ausführen
echo 2. "Ziel-PC Modus" wählen
echo 3. Session-ID an Steuer-PC weitergeben
echo.
echo Computer-Name: %COMPUTERNAME%
echo Benutzer: %USERNAME%
echo.
goto end

:error
echo.
echo ======================================
echo           Setup fehlgeschlagen!
echo ======================================
echo.
echo Bitte prüfen Sie:
echo - Sind Sie als Administrator angemeldet?
echo - Ist Windows 10/11 installiert?
echo - Ist eine Internetverbindung vorhanden?
echo.

:end
echo Drücken Sie eine beliebige Taste zum Beenden...
pause >nul