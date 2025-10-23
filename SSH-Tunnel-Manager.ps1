param(
    [string]$ConfigFile = "schools-config.json"
)

# Event-Handler fuer Programm-Beenden
$cleanup = {
    # Beende Hide-Jobs
    if ($global:hideJobList) {
        foreach ($job in $global:hideJobList) {
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -ErrorAction SilentlyContinue
        }
    }
    
    # Beende alle SSH-Prozesse die von diesem Skript gestartet wurden
    if ($global:sshProcessList) {
        foreach ($proc in $global:sshProcessList) {
            if ($proc -and -not $proc.HasExited) {
                $proc.Kill()
            }
        }
    }
    # Beende alle SSH-Prozesse (fallback)
    Get-Process -Name "ssh" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# Registriere Cleanup fuer verschiedene Exit-Szenarien
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $cleanup
$null = [Console]::add_CancelKeyPress($cleanup)

# Globale Listen fuer SSH-Prozesse und Jobs
$global:sshProcessList = @()
$global:hideJobList = @()

$ConfigPath = Join-Path $PSScriptRoot $ConfigFile

$DefaultConfig = @{
    schools = @{
        "ebs-elmshorn" = @{
            domain = "ebs-elmshorn.org"
            description = "EBS Elmshorn"
        }
    }
    settings = @{
        localPort = 4000
        targetPort = 3389
        sshPort = 22
    }
}

function Initialize-Config {
    if (-not (Test-Path $ConfigPath)) {
        Write-Host "Erstelle neue Konfigurationsdatei..." -ForegroundColor Yellow
        $DefaultConfig | ConvertTo-Json -Depth 3 | Set-Content $ConfigPath
    }
    return Get-Content $ConfigPath | ConvertFrom-Json
}

function Save-Config {
    param($Config)
    $Config | ConvertTo-Json -Depth 3 | Set-Content $ConfigPath
    Write-Host "Konfiguration gespeichert." -ForegroundColor Green
}

function Add-School {
    param($Config)
    
    Write-Host "`nNeue Schule hinzufuegen:" -ForegroundColor Cyan
    
    $schoolKey = Read-Host "Kurzer Name (oder 'back' fuer zurueck)"
    if ($schoolKey -eq "back" -or $schoolKey -eq "b") {
        return "back"
    }
    
    $domain = Read-Host "Domain (oder 'back' fuer zurueck)"
    if ($domain -eq "back" -or $domain -eq "b") {
        return "back"
    }
    
    $description = Read-Host "Beschreibung optional (oder 'back' fuer zurueck)"
    if ($description -eq "back" -or $description -eq "b") {
        return "back"
    }
    
    if (-not $description) { $description = $domain }
    
    $Config.schools.$schoolKey = @{
        domain = $domain
        description = $description
    }
    
    Save-Config $Config
    Write-Host "Schule hinzugefuegt." -ForegroundColor Green
    return "success"
}

function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "            SSH TUNNEL MANAGER" -ForegroundColor Cyan
    Write-Host "         fuer IServ Schulverwaltung" -ForegroundColor Gray
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Schools {
    param($Config)
    
    Write-Host "              SCHULEN" -ForegroundColor Cyan
    Write-Host "=================================" -ForegroundColor Gray
    
    $index = 1
    foreach ($school in $Config.schools.PSObject.Properties) {
        Write-Host "$index. $($school.Value.description)" -ForegroundColor White
        $index++
    }
    Write-Host "$index. Neue Schule hinzufuegen" -ForegroundColor Yellow
    Write-Host "$($index + 1). Exit" -ForegroundColor Red
    Write-Host ""
}

function Select-School {
    param($Config)
    
    do {
        Show-Schools $Config
        $choice = Read-Host "Waehlen Sie eine Option (oder 'back' fuer zurueck)"
        
        if ($choice -eq "back" -or $choice -eq "b") {
            return "back"
        }
        
        $schoolNames = @($Config.schools.PSObject.Properties.Name)
        
        if ($choice -match '^\d+$') {
            $choiceNum = [int]$choice
            
            if ($choiceNum -ge 1 -and $choiceNum -le $schoolNames.Count) {
                return $schoolNames[$choiceNum - 1]
            }
            elseif ($choiceNum -eq ($schoolNames.Count + 1)) {
                $result = Add-School $Config
                if ($result -eq "back") {
                    continue
                }
                $Config = Initialize-Config
            }
            elseif ($choiceNum -eq ($schoolNames.Count + 2)) {
                exit
            }
        }
        
        Write-Host "Ungueltige Auswahl." -ForegroundColor Red
    } while ($true)
}

function Test-SSHConnection {
    param($Server, $Port = 22)
    
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $tcpClient.ConnectAsync($Server, $Port).Wait(3000)
        $result = $tcpClient.Connected
        $tcpClient.Close()
        return $result
    }
    catch {
        return $false
    }
}

function Start-RDPTunnelWithMenu {
    param($SchoolDomain, $Username, $TargetIP, $LocalPort, $TargetPort, $SSHPort)
    
    Write-Host "Verbinde zu $SchoolDomain..." -ForegroundColor Yellow
    
    if (-not (Test-SSHConnection $SchoolDomain 22)) {
        Write-Host "FEHLER: Verbindung fehlgeschlagen!" -ForegroundColor Red
        return
    }
    
    $sshTarget = "${Username}@${SchoolDomain}"
    
    Write-Host "Starte SSH-Tunnel..." -ForegroundColor Yellow
    
    try {
        # Erstelle Batch-Datei die sich nach Passwort-Eingabe selbst versteckt
        $batchFile = Join-Path $env:TEMP "ssh_tunnel_$(Get-Random).bat"
        $batchContent = "@echo off`ntitle SSH Tunnel - Passwort eingeben`necho.`necho SSH-Tunnel wird gestartet...`necho Geben Sie Ihr Passwort ein:`necho.`nssh -o StrictHostKeyChecking=no -L ${LocalPort}:${TargetIP}:${TargetPort} -N $sshTarget"
        
        Set-Content -Path $batchFile -Value $batchContent -Encoding ASCII
        
        # Speichere aktuelles PowerShell-Fenster Handle
        Add-Type -TypeDefinition @"
public class WindowHelper {
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern System.IntPtr GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(System.IntPtr hWnd);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    public static extern uint GetCurrentProcessId();
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint processId);
}
"@
        
        $currentWindow = [WindowHelper]::GetForegroundWindow()
        
        # Starte SSH-Fenster im Vordergrund
        $sshProcess = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $batchFile -WindowStyle Normal -PassThru
        
        # Job zum Verwalten der Fenster
        $windowJob = Start-Job -ScriptBlock {
            param($ProcessId, $BatchFile, $MainWindowHandle)
            
            Add-Type -TypeDefinition @"
public class Win32 {
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(System.IntPtr hWnd);
}
"@
            
            # Warte bis SSH-Prozess laeuft (Passwort eingegeben)
            Start-Sleep -Seconds 8
            
            # Bringe Hauptfenster wieder in den Vordergrund
            if ($MainWindowHandle -ne [System.IntPtr]::Zero) {
                [Win32]::SetForegroundWindow($MainWindowHandle)
            }
            
            # Warte noch etwas, dann verstecke SSH-Fenster
            Start-Sleep -Seconds 3
            
            # Verstecke SSH-Fenster
            $hwnd = [Win32]::FindWindow($null, "SSH Tunnel - Passwort eingeben")
            if ($hwnd -ne [System.IntPtr]::Zero) {
                [Win32]::ShowWindow($hwnd, 0) # SW_HIDE
            }
            
            # Cleanup Batch-Datei
            Start-Sleep -Seconds 5
            Remove-Item $BatchFile -Force -ErrorAction SilentlyContinue
            
        } -ArgumentList $sshProcess.Id, $batchFile, $currentWindow
        
        Write-Host "Warte auf Tunnel-Verbindung..." -ForegroundColor Yellow
        
        # Test ob Tunnel aktiv ist
        $tunnelActive = $false
        for ($i = 1; $i -le 8; $i++) {
            try {
                $tcpTest = New-Object System.Net.Sockets.TcpClient
                $tcpTest.ConnectAsync("localhost", $LocalPort).Wait(1000)
                if ($tcpTest.Connected) {
                    $tunnelActive = $true
                    $tcpTest.Close()
                    break
                }
                $tcpTest.Close()
            } catch { }
            Start-Sleep -Seconds 1
        }
        
        # Fuege Prozess zur globalen Liste hinzu fuer Cleanup
        $global:sshProcessList += $sshProcess
        $global:hideJobList += $windowJob
        
    } catch {
        Write-Host "Fehler beim Starten: $_" -ForegroundColor Red
        return
    }
    
    Clear-Host
    
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "            SSH TUNNEL MANAGER" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host ""
    
    if ($tunnelActive) {
        Write-Host "              TUNNEL AKTIV" -ForegroundColor Green
        Write-Host "=================================" -ForegroundColor Green
        Write-Host "Ziel: localhost:$LocalPort -> ${TargetIP}:${TargetPort}" -ForegroundColor White
        Write-Host "Via: $SchoolDomain" -ForegroundColor White
    } else {
        Write-Host "             TUNNEL STATUS" -ForegroundColor Yellow
        Write-Host "=================================" -ForegroundColor Yellow
        Write-Host "Status unbekannt - versuchen Sie Option 1" -ForegroundColor White
    }
    Write-Host ""
    
    # Menu mit File Transfer
    Write-Host ""
    do {
        Write-Host "               OPTIONEN" -ForegroundColor Cyan
        Write-Host "=================================" -ForegroundColor Gray
        Write-Host "[1] Remote Desktop starten" -ForegroundColor White
        Write-Host "[2] Tunnel beenden und Exit" -ForegroundColor White
        Write-Host ""
        
        $choice = Read-Host "Waehlen Sie eine Option (1-2)"
        
        Clear-Host
        
        switch ($choice) {
            "1" {
                Write-Host "Starte Remote Desktop..." -ForegroundColor Yellow
                Start-Process "mstsc" "/v:localhost:$LocalPort"
                Write-Host "Remote Desktop gestartet" -ForegroundColor Green
                Write-Host ""
                Start-Sleep -Seconds 2
                Clear-Host
            }
            "2" {
                Write-Host "Beende Tunnel und Programm..." -ForegroundColor Yellow
                
                # Fuehre Cleanup aus
                & $cleanup
                
                Write-Host "Alle Tunnel beendet" -ForegroundColor Green
                Start-Sleep -Seconds 1
                exit
            }
            default {
                Write-Host "Bitte waehlen Sie 1 oder 2" -ForegroundColor Red
                Start-Sleep -Seconds 1
                Clear-Host
            }
        }
    } while ($true)
    
    # SSH-Prozess laeuft jetzt komplett versteckt im Hintergrund
}


function Main {
    while ($true) {
        Show-Menu
        
        $Config = Initialize-Config
        
        $selectedSchool = Select-School $Config
        if ($selectedSchool -eq "back") {
            continue
        }
        $schoolInfo = $Config.schools.$selectedSchool

        # Öffne Schul-Website automatisch
        $schoolUrl = "https://$($schoolInfo.domain)/iserv/admin/hosts"
        Write-Host "Öffne Schul-Website: $schoolUrl" -ForegroundColor Yellow
        Start-Process $schoolUrl
        
        while ($true) {
            Write-Host "              VERBINDUNG" -ForegroundColor Green
            Write-Host "=================================" -ForegroundColor Gray
            Write-Host "Schule: $($schoolInfo.description)" -ForegroundColor White
            Write-Host "Domain: $($schoolInfo.domain)" -ForegroundColor White
            Write-Host ""
            
            do {
                $targetIP = Read-Host "Ziel-IP des PCs (oder 'back' fuer zurueck)"
                if ($targetIP -eq "back" -or $targetIP -eq "b") {
                    $backRequested = $true
                    break
                }
                if ($targetIP -match '^(\d{1,3}\.){3}\d{1,3}$') {
                    $backRequested = $false
                    break
                }
                Write-Host "Ungueltire IP-Adresse" -ForegroundColor Red
            } while ($true)
            
            if ($backRequested) {
                Clear-Host
                break
            }
            
            $username = Read-Host "Benutzername (oder 'back' fuer zurueck)"
            if ($username -eq "back" -or $username -eq "b") {
                continue
            }
            
            $result = Start-RDPTunnelWithMenu -SchoolDomain $schoolInfo.domain -Username $username -TargetIP $targetIP -LocalPort $Config.settings.localPort -TargetPort $Config.settings.targetPort -SSHPort $Config.settings.sshPort
            
            if ($result -eq "retry") {
                Write-Host "`nMoechten Sie die Eingaben wiederholen? (j/n)" -ForegroundColor Yellow
                $retry = Read-Host
                if ($retry -eq "j" -or $retry -eq "y") {
                    Clear-Host
                    continue
                } else {
                    Clear-Host
                    break
                }
            } else {
                # Erfolgreich - Skript beendet sich
                break
            }
        }
    }
}

Main