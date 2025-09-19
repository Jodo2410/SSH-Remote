# SSH/RDP Connection Manager - OPTIMIERTE VERSION 2.0 (KORRIGIERT)
# Benutzerfreundliche API-Integration mit verbesserter UX

# Globale Variablen
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$CONFIG_FILE = Join-Path $SCRIPT_DIR "connection_config.json"
$SESSIONS_FILE = Join-Path $SCRIPT_DIR "recent_sessions.json"
$VPS_IP = ""
$VPS_USER = ""
$API_PORT = "8080"
$API_BASE_URL = ""

# UI Helper Funktionen
function Show-ColoredText {
    param(
        [string]$Text,
        [string]$Color = "White",
        [switch]$NoNewline
    )

    $colorMap = @{
        "Red" = [ConsoleColor]::Red
        "Green" = [ConsoleColor]::Green
        "Yellow" = [ConsoleColor]::Yellow
        "Blue" = [ConsoleColor]::Blue
        "Cyan" = [ConsoleColor]::Cyan
        "Magenta" = [ConsoleColor]::Magenta
        "White" = [ConsoleColor]::White
        "Gray" = [ConsoleColor]::Gray
    }

    if ($NoNewline) {
        Write-Host $Text -ForegroundColor $colorMap[$Color] -NoNewline
    } else {
        Write-Host $Text -ForegroundColor $colorMap[$Color]
    }
}

function Show-Box {
    param(
        [string[]]$Lines,
        [string]$Color = "Cyan",
        [string]$Title = ""
    )

    $maxLength = ($Lines | Measure-Object -Property Length -Maximum).Maximum
    if ($Title) {
        $maxLength = [Math]::Max($maxLength, $Title.Length + 4)
    }

    $border = "=" * ($maxLength + 4)

    Show-ColoredText "+$border+" $Color

    if ($Title) {
        $padding = " " * [Math]::Floor(($maxLength - $Title.Length) / 2)
        Show-ColoredText "|  $padding$Title$padding  |" $Color
        Show-ColoredText "+$border+" $Color
    }

    foreach ($line in $Lines) {
        $padding = " " * ($maxLength - $line.Length)
        Show-ColoredText "|  $line$padding  |" $Color
    }

    Show-ColoredText "+$border+" $Color
}

function Get-UserInput {
    param(
        [string]$Prompt,
        [string]$DefaultValue = "",
        [switch]$Secure,
        [string[]]$ValidOptions = @()
    )

    if ($DefaultValue) {
        Show-ColoredText "${Prompt} [$DefaultValue]" "Yellow" -NoNewline
        Write-Host ": " -NoNewline
    } else {
        Show-ColoredText "${Prompt}" "Yellow" -NoNewline
        Write-Host ": " -NoNewline
    }

    if ($Secure) {
        $input = Read-Host -AsSecureString
        return [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($input))
    }

    $input = Read-Host

    if ([string]::IsNullOrWhiteSpace($input) -and $DefaultValue) {
        return $DefaultValue
    }

    if ($ValidOptions.Count -gt 0) {
        while ($input -notin $ValidOptions) {
            Show-ColoredText "Ungueltige Eingabe! Gueltige Optionen: $($ValidOptions -join ', ')" "Red"
            Show-ColoredText "${Prompt}" "Yellow" -NoNewline
            Write-Host ": " -NoNewline
            $input = Read-Host
        }
    }

    return $input
}

# API Helper Funktionen
function Test-APIConnection {
    param([int]$TimeoutSeconds = 5)

    try {
        $response = Invoke-RestMethod -Uri "$API_BASE_URL/health" -Method GET -TimeoutSec $TimeoutSeconds
        return @{
            Success = $true
            Status = $response.status
            Version = $response.version
            ServerIP = $response.server_ip
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Request-TunnelUser {
    param(
        [string]$ClientName,
        [string]$ClientDescription = ""
    )

    $clientId = "$env:COMPUTERNAME-$ClientName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    $requestData = @{
        client_id = $clientId
        client_name = $ClientName
        client_description = $ClientDescription
        hostname = $env:COMPUTERNAME
        username = $env:USERNAME
        timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    } | ConvertTo-Json

    try {
        Write-Progress -Activity "Erstelle Tunnel-User..." -PercentComplete 30

        $response = Invoke-RestMethod -Uri "$API_BASE_URL/api/request_tunnel" `
                                     -Method POST `
                                     -Body $requestData `
                                     -ContentType "application/json" `
                                     -TimeoutSec 30

        Write-Progress -Activity "Tunnel-User erstellt!" -PercentComplete 100
        Start-Sleep 1
        Write-Progress -Completed -Activity "Tunnel-User erstellt!"

        # Session in Recent Sessions speichern
        Save-RecentSession -SessionData $response -Type "Created"

        return @{
            Success = $true
            Data = $response
        }
    }
    catch {
        Write-Progress -Completed -Activity "Fehler"
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Get-TunnelConnection {
    param([string]$SessionId)

    try {
        Write-Progress -Activity "Lade Verbindungsinformationen..." -PercentComplete 50

        $response = Invoke-RestMethod -Uri "$API_BASE_URL/api/get_connection/$SessionId" `
                                     -Method GET `
                                     -TimeoutSec 15

        Write-Progress -Activity "Verbindungsinformationen geladen!" -PercentComplete 100
        Start-Sleep 1
        Write-Progress -Completed -Activity "Verbindungsinformationen geladen!"

        # Session in Recent Sessions speichern
        Save-RecentSession -SessionData $response -Type "Connected"

        return @{
            Success = $true
            Data = $response
        }
    }
    catch {
        Write-Progress -Completed -Activity "Fehler"

        if ($_.Exception.Response.StatusCode -eq 404) {
            return @{
                Success = $false
                Error = "Session nicht gefunden oder abgelaufen"
                ErrorType = "NotFound"
            }
        } else {
            return @{
                Success = $false
                Error = $_.Exception.Message
                ErrorType = "General"
            }
        }
    }
}

function Update-TunnelStatus {
    param(
        [string]$SessionId,
        [bool]$Active
    )

    $statusData = @{
        active = $Active
    } | ConvertTo-Json

    try {
        Invoke-RestMethod -Uri "$API_BASE_URL/api/update_tunnel/$SessionId" `
                         -Method POST `
                         -Body $statusData `
                         -ContentType "application/json" `
                         -TimeoutSec 10
        return $true
    }
    catch {
        return $false
    }
}

# Session Management
function Save-RecentSession {
    param(
        $SessionData,
        [string]$Type
    )

    try {
        $recentSessions = @()
        if (Test-Path $SESSIONS_FILE) {
            $recentSessions = Get-Content $SESSIONS_FILE -Raw | ConvertFrom-Json
        }

        $sessionEntry = @{
            SessionId = $SessionData.session_id
            ClientName = $SessionData.client_name
            Username = $SessionData.username
            Ports = $SessionData.ports
            ServerIP = $SessionData.server_ip
            Created = $SessionData.created
            Type = $Type
            LastUsed = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }

        # Neueste Session an den Anfang
        $recentSessions = @($sessionEntry) + $recentSessions

        # Nur die letzten 10 Sessions behalten
        if ($recentSessions.Count -gt 10) {
            $recentSessions = $recentSessions[0..9]
        }

        $recentSessions | ConvertTo-Json -Depth 10 | Out-File -FilePath $SESSIONS_FILE -Encoding UTF8
    }
    catch {
        # Fehler beim Speichern ignorieren
    }
}

function Get-RecentSessions {
    try {
        if (Test-Path $SESSIONS_FILE) {
            return Get-Content $SESSIONS_FILE -Raw | ConvertFrom-Json
        }
    }
    catch {
        # Fehler beim Laden ignorieren
    }
    return @()
}

# Konfigurationsfunktionen
function Load-Configuration {
    if (Test-Path $CONFIG_FILE) {
        try {
            $configData = Get-Content $CONFIG_FILE -Raw | ConvertFrom-Json
            $script:VPS_IP = $configData.VPS_IP
            $script:VPS_USER = $configData.VPS_USER
            $script:API_PORT = $configData.API_PORT
            $script:API_BASE_URL = "http://$VPS_IP`:$API_PORT"

            return $true
        } catch {
            Show-ColoredText "Fehler beim Laden der Konfiguration: $($_.Exception.Message)" "Red"
            return $false
        }
    }
    return $false
}

function Save-Configuration {
    $configData = @{
        VPS_IP = $VPS_IP
        VPS_USER = $VPS_USER
        API_PORT = $API_PORT
        LastUpdated = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }

    try {
        $configData | ConvertTo-Json -Depth 10 | Out-File -FilePath $CONFIG_FILE -Encoding UTF8
        Show-ColoredText "Konfiguration gespeichert" "Green"
    } catch {
        Show-ColoredText "Fehler beim Speichern der Konfiguration: $($_.Exception.Message)" "Red"
    }
}

function Get-InitialConfiguration {
    Clear-Host

    Show-Box @("API-basierte Erstkonfiguration", "", "Bitte geben Sie Ihre VPS-Daten ein:") "Green" "ERSTEINRICHTUNG"

    Write-Host ""

    # VPS-Konfiguration abfragen
    $script:VPS_IP = Get-UserInput "VPS IP-Adresse"
    $script:VPS_USER = Get-UserInput "VPS Benutzername" "root"
    $script:API_PORT = Get-UserInput "API Port" "8080"

    $script:API_BASE_URL = "http://$VPS_IP`:$API_PORT"

    Write-Host ""
    Show-Box @(
        "VPS-Konfiguration:",
        "IP: $VPS_IP",
        "User: $VPS_USER",
        "API: $API_BASE_URL"
    ) "Yellow" "KONFIGURATION"

    Write-Host ""

    # API-Verbindung testen
    Show-ColoredText "Teste API-Verbindung..." "Cyan"

    $apiTest = Test-APIConnection -TimeoutSeconds 10

    if ($apiTest.Success) {
        Show-ColoredText "API-Verbindung erfolgreich!" "Green"
        Show-ColoredText "  Version: $($apiTest.Version)" "Gray"
        Show-ColoredText "  Server: $($apiTest.ServerIP)" "Gray"
        Save-Configuration
    } else {
        Show-ColoredText "API-Verbindung fehlgeschlagen!" "Red"
        Show-ColoredText "  Fehler: $($apiTest.Error)" "Red"

        Write-Host ""
        $continue = Get-UserInput "Trotzdem fortfahren?" "" @("j", "n", "ja", "nein")

        if ($continue.ToLower() -in @("j", "ja")) {
            Save-Configuration
        } else {
            return
        }
    }

    Write-Host ""
    Show-ColoredText "Konfiguration abgeschlossen!" "Green"
    Write-Host ""
    Show-ColoredText "Druecken Sie Enter um fortzufahren..." "Gray"
    Read-Host
}

function Show-Header {
    Clear-Host

    $headerLines = @(
        "SSH/RDP Connection Manager (API-Mode)",
        "",
        "VPS: $VPS_USER@$VPS_IP"
    )

    if ($VPS_IP -ne "") {
        $apiTest = Test-APIConnection -TimeoutSeconds 2
        if ($apiTest.Success) {
            $headerLines += "API: Online"
        } else {
            $headerLines += "API: Offline"
        }
    }

    Show-Box $headerLines "Cyan" "REMOTE-FREUND"
    Write-Host ""
}

function Show-MainMenu {
    $menuLines = @(
        "1. Ziel-PC Modus (Tunnel starten)",
        "2. Steuer-PC Modus (Verbinden)",
        "3. API-Status und Statistiken",
        "4. VPS-Konfiguration bearbeiten",
        "5. Session-Verlauf anzeigen",
        "6. Erweiterte Optionen",
        "7. Beenden"
    )

    Show-Box $menuLines "Green" "HAUPTMENUE"
    Write-Host ""
}

function Start-TargetPCMode {
    Clear-Host

    Show-Box @(
        "ZIEL-PC MODUS",
        "",
        "Dieser PC wird fuer Remote-Zugriff verfuegbar gemacht",
        "Ein temporaerer User wird auf dem VPS erstellt"
    ) "Green" "TUNNEL STARTEN"

    Write-Host ""

    # API-Verbindung prüfen
    $apiTest = Test-APIConnection
    if (-not $apiTest.Success) {
        Show-Box @(
            "API nicht erreichbar!",
            "",
            "Fehler: $($apiTest.Error)",
            "",
            "Bitte ueberpruefen Sie:",
            "- VPS-Verbindung",
            "- API-Server Status",
            "- Firewall-Einstellungen"
        ) "Red" "VERBINDUNGSFEHLER"

        Write-Host ""
        Show-ColoredText "Druecken Sie Enter um fortzufahren..." "Gray"
        Read-Host
        return
    }

    # Benutzer-freundliche Eingabe
    $clientName = Get-UserInput "Name fuer diesen PC" $env:COMPUTERNAME
    $description = Get-UserInput "Beschreibung (optional)" "Remote-Zugriff"

    Write-Host ""
    Show-ColoredText "Erstelle Tunnel-User..." "Cyan"

    # Tunnel-User anfordern
    $result = Request-TunnelUser -ClientName $clientName -ClientDescription $description

    if ($result.Success) {
        $tunnelInfo = $result.Data

        Clear-Host

        # Erfolgs-Anzeige
        $successLines = @(
            "Tunnel-User erfolgreich erstellt!",
            "",
            "Session-ID: $($tunnelInfo.session_id)",
            "Temporaerer User: $($tunnelInfo.username)",
            "Passwort: $($tunnelInfo.password)",
            "SSH Port: $($tunnelInfo.ports.ssh)",
            "RDP Port: $($tunnelInfo.ports.rdp)",
            "",
            "SSH-Befehl wird automatisch ausgefuehrt"
        )

        Show-Box $successLines "Green" "TUNNEL ERSTELLT"

        Write-Host ""

        # Session-ID hervorheben
        Show-Box @(
            "WICHTIG: Session-ID fuer Steuer-PC:",
            "",
            "$($tunnelInfo.session_id)"
        ) "Yellow" "SESSION-ID"

        Write-Host ""
        Show-ColoredText "Diese Session-ID an den Steuer-PC weitergeben!" "Yellow"

        # In Zwischenablage kopieren (falls möglich)
        try {
            $tunnelInfo.session_id | Set-Clipboard
            Show-ColoredText "Session-ID wurde in die Zwischenablage kopiert" "Green"
        } catch {
            # Clipboard nicht verfügbar
        }

        Write-Host ""
        Show-ColoredText "Druecken Sie Enter um den SSH-Tunnel zu starten..." "Cyan"
        Read-Host

        Clear-Host

        Show-Box @(
            "SSH-TUNNEL AKTIV",
            "",
            "Client: $clientName",
            "Session: $($tunnelInfo.session_id)",
            "",
            "WICHTIG:",
            "- Halten Sie dieses Fenster geoeffnet!",
            "- Der Tunnel laeuft dauerhaft",
            "- Zum Beenden: Strg+C druecken"
        ) "Cyan" "TUNNEL-STATUS"

        Write-Host ""

        try {
            # Tunnel-Status als aktiv markieren
            Update-TunnelStatus -SessionId $tunnelInfo.session_id -Active $true

            # SSH-Tunnel starten
            Show-ColoredText "Ausgefuehrter Befehl:" "Gray"
            Show-ColoredText $tunnelInfo.ssh_command "Gray"
            Write-Host ""
            Show-ColoredText "Passwort: $($tunnelInfo.password)" "Yellow"
            Show-ColoredText "Starte SSH-Tunnel..." "Green"
            Write-Host ""

            Invoke-Expression $tunnelInfo.ssh_command
        }
        finally {
            # Tunnel-Status deaktivieren
            Clear-Host
            Show-ColoredText "Tunnel wird beendet..." "Yellow"
            Update-TunnelStatus -SessionId $tunnelInfo.session_id -Active $false

            Show-Box @(
                "Tunnel erfolgreich beendet",
                "",
                "Der temporaere User wird automatisch",
                "nach 1 Stunde geloescht"
            ) "Green" "TUNNEL BEENDET"
        }
    } else {
        Show-Box @(
            "Fehler beim Erstellen des Tunnel-Users",
            "",
            "Fehler: $($result.Error)",
            "",
            "Moegliche Ursachen:",
            "- VPS-Verbindung unterbrochen",
            "- API-Server Probleme",
            "- Keine freien Ports verfuegbar"
        ) "Red" "FEHLER"
    }

    Write-Host ""
    Show-ColoredText "Druecken Sie Enter um fortzufahren..." "Gray"
    Read-Host
}

function Start-ControlPCMode {
    Clear-Host

    Show-Box @(
        "STEUER-PC MODUS",
        "",
        "Verbindung zu einem Remote-PC ueber Session-ID",
        "Sie benoetigen die Session-ID vom Ziel-PC"
    ) "Green" "VERBINDEN"

    Write-Host ""

    # API-Verbindung prüfen
    $apiTest = Test-APIConnection
    if (-not $apiTest.Success) {
        Show-Box @(
            "API nicht erreichbar!",
            "",
            "Fehler: $($apiTest.Error)"
        ) "Red" "VERBINDUNGSFEHLER"

        Write-Host ""
        Show-ColoredText "Druecken Sie Enter um fortzufahren..." "Gray"
        Read-Host
        return
    }

    # Recent Sessions anzeigen
    $recentSessions = Get-RecentSessions
    if ($recentSessions.Count -gt 0) {
        Write-Host ""
        Show-ColoredText "Kuerzlich verwendete Sessions:" "Cyan"
        Write-Host ""

        for ($i = 0; $i -lt [Math]::Min(3, $recentSessions.Count); $i++) {
            $session = $recentSessions[$i]
            Show-ColoredText "  [$($i+1)] $($session.ClientName) - $($session.SessionId)" "Yellow"
            Show-ColoredText "      Zuletzt: $($session.LastUsed)" "Gray"
        }

        Write-Host ""
        Show-ColoredText "Moechten Sie eine der letzten Sessions verwenden? (1-3 oder Enter fuer neue)" "Cyan"
        $recentChoice = Read-Host

        if ($recentChoice -match '^[1-3]$' -and [int]$recentChoice -le $recentSessions.Count) {
            $selectedSession = $recentSessions[[int]$recentChoice - 1]
            $sessionId = $selectedSession.SessionId
            Show-ColoredText "Ausgewaehlte Session: $($selectedSession.ClientName)" "Green"
        } else {
            $sessionId = Get-UserInput "Session-ID eingeben"
        }
    } else {
        $sessionId = Get-UserInput "Session-ID eingeben"
    }

    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        Show-ColoredText "Keine Session-ID eingegeben!" "Red"
        Write-Host ""
        Show-ColoredText "Druecken Sie Enter um fortzufahren..." "Gray"
        Read-Host
        return
    }

    Write-Host ""
    Show-ColoredText "Lade Verbindungsinformationen..." "Cyan"

    # Verbindungsinformationen abrufen
    $result = Get-TunnelConnection -SessionId $sessionId

    if ($result.Success) {
        $connectionInfo = $result.Data

        Clear-Host

        # Verbindungsinfo anzeigen
        $statusText = if ($connectionInfo.tunnel_active) { "Aktiv" } else { "Inaktiv" }

        $infoLines = @(
            "Session-ID: $($connectionInfo.session_id)",
            "Client: $($connectionInfo.client_name)",
            "Beschreibung: $($connectionInfo.client_description)",
            "",
            "Temporaerer User: $($connectionInfo.username)",
            "Passwort: $($connectionInfo.password)",
            "SSH Port: $($connectionInfo.ports.ssh)",
            "RDP Port: $($connectionInfo.ports.rdp)",
            "",
            "Tunnel Status: $statusText"
        )

        Show-Box $infoLines "Cyan" "VERBINDUNGSINFO"

        if (-not $connectionInfo.tunnel_active) {
            Write-Host ""
            Show-Box @(
                "WARNUNG: Tunnel ist nicht aktiv!",
                "",
                "Der Ziel-PC muss zuerst einen Tunnel starten.",
                "Sie koennen trotzdem versuchen sich zu verbinden."
            ) "Yellow" "TUNNEL INAKTIV"
        }

        Write-Host ""

        # Verbindungsoptionen
        $connectionLines = @(
            "1. SSH-Verbindung (Kommandozeile)",
            "2. RDP-Verbindung (Grafische Oberflaeche)",
            "3. Befehle in Zwischenablage kopieren",
            "4. Zurueck"
        )

        Show-Box $connectionLines "Green" "VERBINDUNGSOPTIONEN"

        Write-Host ""
        $choice = Get-UserInput "Ihre Wahl" "" @("1", "2", "3", "4")

        switch ($choice) {
            "1" {
                Write-Host ""
                Show-ColoredText "Starte SSH-Verbindung..." "Green"
                Show-ColoredText "Befehl: $($connectionInfo.ssh_command)" "Gray"
                Write-Host ""

                try {
                    Invoke-Expression $connectionInfo.ssh_command
                } catch {
                    Show-ColoredText "SSH-Verbindung fehlgeschlagen: $($_.Exception.Message)" "Red"
                }
            }
            "2" {
                Write-Host ""
                Show-ColoredText "Starte RDP-Verbindung..." "Green"
                Show-ColoredText "Endpoint: $($connectionInfo.rdp_endpoint)" "Gray"
                Write-Host ""

                Start-RDPConnectionOptimized -ConnectionInfo $connectionInfo
            }
            "3" {
                try {
                    $commands = @(
                        "SSH-Befehl: $($connectionInfo.ssh_command)",
                        "RDP-Server: $($connectionInfo.rdp_endpoint)",
                        "Benutzername: $($connectionInfo.username)"
                    )

                    ($commands -join "`n") | Set-Clipboard
                    Show-ColoredText "Verbindungsbefehle in Zwischenablage kopiert!" "Green"
                } catch {
                    Show-ColoredText "Zwischenablage nicht verfuegbar" "Red"
                }
            }
            "4" {
                return
            }
        }
    } else {
        if ($result.ErrorType -eq "NotFound") {
            Show-Box @(
                "Session nicht gefunden!",
                "",
                "Moegliche Ursachen:",
                "- Session-ID falsch eingegeben",
                "- Session ist abgelaufen (>1h)",
                "- Tunnel wurde beendet",
                "",
                "Bitte ueberpruefen Sie die Session-ID"
            ) "Red" "SESSION NICHT GEFUNDEN"
        } else {
            Show-Box @(
                "Verbindungsfehler!",
                "",
                "Fehler: $($result.Error)"
            ) "Red" "FEHLER"
        }
    }

    Write-Host ""
    Show-ColoredText "Druecken Sie Enter um fortzufahren..." "Gray"
    Read-Host
}

function Start-RDPConnectionOptimized {
    param($ConnectionInfo)

    # Verbesserter RDP-Inhalt mit optimierten Einstellungen
    $rdpContent = @"
full address:s:$($ConnectionInfo.rdp_endpoint)
username:s:$($ConnectionInfo.username)
screen mode id:i:2
desktopwidth:i:1920
desktopheight:i:1080
session bpp:i:32
compression:i:1
keyboardhook:i:2
audiocapturemode:i:0
videoplaybackmode:i:1
connection type:i:7
displayconnectionbar:i:1
disable wallpaper:i:1
allow font smoothing:i:1
allow desktop composition:i:0
disable full window drag:i:1
disable menu anims:i:1
disable themes:i:0
disable cursor setting:i:0
bitmapcachepersistenable:i:1
redirectclipboard:i:1
redirectprinters:i:0
redirectcomports:i:0
redirectsmartcards:i:0
redirectdrives:i:0
"@

    $tempRdpFile = "$env:TEMP\tunnel_connection_$($ConnectionInfo.session_id).rdp"

    try {
        $rdpContent | Out-File -FilePath $tempRdpFile -Encoding ASCII

        Show-ColoredText "Oeffne Remote Desktop..." "Cyan"
        Start-Process "mstsc" -ArgumentList $tempRdpFile

        Start-Sleep 3
        Remove-Item $tempRdpFile -ErrorAction SilentlyContinue

        Show-ColoredText "Remote Desktop gestartet" "Green"
    } catch {
        Show-ColoredText "RDP-Verbindung fehlgeschlagen: $($_.Exception.Message)" "Red"
    }
}

function Show-APIStats {
    Clear-Host

    Show-Box @("API-STATUS UND STATISTIKEN") "Green" "SYSTEM-STATUS"

    Write-Host ""

    # API-Verbindung testen
    Show-ColoredText "Teste API-Verbindung..." "Cyan"
    $apiTest = Test-APIConnection

    if (-not $apiTest.Success) {
        Show-Box @(
            "API ist nicht erreichbar!",
            "",
            "URL: $API_BASE_URL",
            "Fehler: $($apiTest.Error)",
            "",
            "Moegliche Ursachen:",
            "- API-Service ist nicht gestartet",
            "- Firewall blockiert Port $API_PORT",
            "- VPS ist nicht erreichbar"
        ) "Red" "VERBINDUNGSFEHLER"

        Write-Host ""
        Show-ColoredText "Druecken Sie Enter um fortzufahren..." "Gray"
        Read-Host
        return
    }

    Show-ColoredText "API ist online!" "Green"
    Write-Host ""

    # Statistiken abrufen
    Show-ColoredText "Lade Statistiken..." "Cyan"
    try {
        $response = Invoke-RestMethod -Uri "$API_BASE_URL/api/stats" -Method GET -TimeoutSec 10

        $statsLines = @(
            "Aktive Sessions: $($response.total_sessions)",
            "Aktive Tunnels: $($response.active_tunnels)",
            "Inaktive Sessions: $($response.inactive_sessions)",
            "Server-Uptime: $([math]::Round($response.uptime / 3600, 2)) Stunden",
            "",
            "Server-IP: $($response.server_ip)",
            "Port-Bereich: $($response.port_range)"
        )

        Show-Box $statsLines "Cyan" "STATISTIKEN"
    } catch {
        Show-ColoredText "Statistiken konnten nicht geladen werden" "Red"
    }

    Write-Host ""
    Show-ColoredText "Druecken Sie Enter um fortzufahren..." "Gray"
    Read-Host
}

function Show-SessionHistory {
    Clear-Host

    Show-Box @("SESSION-VERLAUF") "Green" "VERLAUF"

    Write-Host ""

    $recentSessions = Get-RecentSessions

    if ($recentSessions.Count -eq 0) {
        Show-Box @(
            "Keine Sessions im Verlauf",
            "",
            "Sessions werden automatisch hier",
            "gespeichert, wenn Sie sie verwenden"
        ) "Yellow" "KEIN VERLAUF"
    } else {
        for ($i = 0; $i -lt $recentSessions.Count; $i++) {
            $session = $recentSessions[$i]
            $typeIcon = if ($session.Type -eq "Created") { "ERSTELLT" } else { "VERBUNDEN" }

            $sessionLines = @(
                "${typeIcon}: $($session.ClientName)",
                "Session-ID: $($session.SessionId)",
                "SSH Port: $($session.Ports.ssh) | RDP Port: $($session.Ports.rdp)",
                "Zuletzt verwendet: $($session.LastUsed)"
            )

            Show-Box $sessionLines "Cyan" "SESSION $($i + 1)"

            if ($i -lt $recentSessions.Count - 1) {
                Write-Host ""
            }
        }
    }

    Write-Host ""
    Show-ColoredText "Druecken Sie Enter um fortzufahren..." "Gray"
    Read-Host
}

function Show-AdvancedOptions {
    Clear-Host

    Show-Box @("ERWEITERTE OPTIONEN") "Green" "EINSTELLUNGEN"

    Write-Host ""

    $advancedLines = @(
        "1. Sessions-Verlauf loeschen",
        "2. API-Verbindung neu testen",
        "3. Konfiguration anzeigen",
        "4. Konfiguration zuruecksetzen",
        "5. Zurueck"
    )

    Show-Box $advancedLines "Yellow" "OPTIONEN"

    Write-Host ""
    $choice = Get-UserInput "Ihre Wahl" "" @("1", "2", "3", "4", "5")

    switch ($choice) {
        "1" {
            if (Test-Path $SESSIONS_FILE) {
                Remove-Item $SESSIONS_FILE -Force
                Show-ColoredText "Sessions-Verlauf geloescht" "Green"
            } else {
                Show-ColoredText "Kein Sessions-Verlauf vorhanden" "Yellow"
            }
        }
        "2" {
            Write-Host ""
            Show-ColoredText "Teste API-Verbindung..." "Cyan"
            $apiTest = Test-APIConnection -TimeoutSeconds 10

            if ($apiTest.Success) {
                Show-Box @(
                    "API-Verbindung erfolgreich!",
                    "",
                    "Status: $($apiTest.Status)",
                    "Version: $($apiTest.Version)",
                    "Server-IP: $($apiTest.ServerIP)"
                ) "Green" "VERBINDUNG OK"
            } else {
                Show-Box @(
                    "API-Verbindung fehlgeschlagen!",
                    "",
                    "Fehler: $($apiTest.Error)"
                ) "Red" "VERBINDUNGSFEHLER"
            }
        }
        "3" {
            Write-Host ""
            $configLines = @(
                "VPS-IP: $VPS_IP",
                "VPS-User: $VPS_USER",
                "API-Port: $API_PORT",
                "API-URL: $API_BASE_URL",
                "",
                "Konfigurationsdatei: $CONFIG_FILE",
                "Sessions-Datei: $SESSIONS_FILE"
            )

            Show-Box $configLines "Cyan" "AKTUELLE KONFIGURATION"
        }
        "4" {
            Write-Host ""
            $confirm = Get-UserInput "Konfiguration wirklich zuruecksetzen?" "" @("j", "n", "ja", "nein")

            if ($confirm.ToLower() -in @("j", "ja")) {
                if (Test-Path $CONFIG_FILE) {
                    Remove-Item $CONFIG_FILE -Force
                }
                if (Test-Path $SESSIONS_FILE) {
                    Remove-Item $SESSIONS_FILE -Force
                }
                Show-ColoredText "Konfiguration zurueckgesetzt" "Green"
                Show-ColoredText "Das Programm wird beim naechsten Start neu konfiguriert" "Yellow"
            } else {
                Show-ColoredText "Zuruecksetzen abgebrochen" "Yellow"
            }
        }
        "5" {
            return
        }
    }

    if ($choice -ne "5") {
        Write-Host ""
        Show-ColoredText "Druecken Sie Enter um fortzufahren..." "Gray"
        Read-Host
    }
}

# Hauptprogramm - Initialisierung und Hauptschleife
function Start-Application {
    # Begrüßung
    Clear-Host

    Show-Box @(
        "Willkommen zum Remote-Freund Connection Manager!",
        "",
        "Version 2.0 - Optimierte Benutzeroberflaeche",
        "Mit API-basierter dynamischer User-Verwaltung"
    ) "Green" "REMOTE-FREUND"

    Write-Host ""
    Show-ColoredText "Initialisiere Anwendung..." "Cyan"
    Start-Sleep 1

    # Konfiguration laden oder erstellen
    if (-not (Load-Configuration)) {
        Write-Host ""
        Show-ColoredText "Keine Konfiguration gefunden. Starte Ersteinrichtung..." "Yellow"
        Start-Sleep 2
        Get-InitialConfiguration
    } else {
        # Kurzer API-Test
        $apiTest = Test-APIConnection -TimeoutSeconds 3
        if (-not $apiTest.Success) {
            Write-Host ""
            Show-ColoredText "API-Verbindung nicht verfuegbar" "Yellow"
            Show-ColoredText "Sie koennen die Konfiguration spaeter in den Einstellungen anpassen" "Gray"
            Start-Sleep 2
        }
    }

    # Hauptschleife
    do {
        try {
            Show-Header
            Show-MainMenu

            $mainChoice = Get-UserInput "Ihre Wahl" "" @("1", "2", "3", "4", "5", "6", "7")

            switch ($mainChoice) {
                "1" {
                    Start-TargetPCMode
                }
                "2" {
                    Start-ControlPCMode
                }
                "3" {
                    Show-APIStats
                }
                "4" {
                    Get-InitialConfiguration
                }
                "5" {
                    Show-SessionHistory
                }
                "6" {
                    Show-AdvancedOptions
                }
                "7" {
                    Clear-Host
                    Show-Box @(
                        "Vielen Dank fuer die Nutzung!",
                        "",
                        "Remote-Freund Connection Manager",
                        "Auf Wiedersehen!"
                    ) "Green" "BIS BALD"
                    Start-Sleep 2
                    exit
                }
                default {
                    Show-ColoredText "Ungueltige Auswahl!" "Red"
                    Start-Sleep 1
                }
            }
        }
        catch {
            Show-Box @(
                "Unerwarteter Fehler aufgetreten!",
                "",
                "Fehler: $($_.Exception.Message)",
                "",
                "Die Anwendung wird fortgesetzt..."
            ) "Red" "SYSTEMFEHLER"

            Write-Host ""
            Show-ColoredText "Druecken Sie Enter um fortzufahren..." "Gray"
            Read-Host
        }

    } while ($true)
}

# Anwendung starten
Start-Application