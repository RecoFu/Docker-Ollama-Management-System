# Docker-Ollama-Manager.ps1
#Requires -RunAsAdministrator
#Requires -Version 5.1

param (
    [string]$InstallPath = "D:\VM",
    [string]$ConfigPath = "D:\VM\config",
    [string]$LogPath = "D:\VM\logs"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Configuration
$WebUIPort = 3000
$OllamaPort = 11434
$MinDriverVersion = "550.00"
$MinCudaVersion = "12.8"

# Global Paths
$dockerComposeFile = Join-Path $InstallPath "docker-compose.yml"
$logFile = Join-Path $LogPath "docker.log"

# System Requirements Check
function Test-SystemRequirements {
    $result = @{
        OS = $false
        RAM = $false
        GPU = $false
        CUDA = $false
        FreeRAM = 0
    }

    try {
        # OS Check
        $os = Get-CimInstance Win32_OperatingSystem
        $result.OS = $os.Caption -like "*Windows 11*"

        # RAM Check
        $result.FreeRAM = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $result.RAM = $result.FreeRAM -ge 8

        # GPU Check
        try {
            $gpu = nvidia-smi --query-gpu=gpu_name --format=csv,noheader 2>$null
            $result.GPU = $gpu -like "*4060*"
        } catch { $result.GPU = $false }

        # CUDA Check
        try {
            $cuda = nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>$null
            if ($cuda -match "(\d+\.\d+)") {
                $result.CUDA = [version]$Matches[1] -ge [version]$MinCudaVersion
            }
        } catch { $result.CUDA = $false }

    } catch { Write-Host "System check error: $_" -ForegroundColor Red }

    return $result
}

# Service Status Check
function Get-ServiceStatus {
    $status = @{
        Docker = $false
        Ollama = $false
        WebUI = $false
        Models = @()
        PortAvailable = $false
    }

    # Check Docker
    try {
        docker version 2>$null | Out-Null
        $status.Docker = $true
    } catch { $status.Docker = $false }

    if ($status.Docker) {
        # Check Containers
        $status.Ollama = (docker ps -f "name=ollama" --format "{{.Status}}" 2>$null) -match "Up"
        $status.WebUI = (docker ps -f "name=webui" --format "{{.Status}}" 2>$null) -match "Up"

        # Check Port
        try {
            $status.PortAvailable = (Test-NetConnection -ComputerName localhost -Port $WebUIPort -WarningAction SilentlyContinue).TcpTestSucceeded
        } catch { $status.PortAvailable = $false }

        # Check Models
        $modelPath = Join-Path $InstallPath "models"
        if (Test-Path $modelPath) {
            $status.Models = @(Get-ChildItem $modelPath -Filter "*.bin" | Select-Object -ExpandProperty Name)
        }
    }

    return $status
}

# Docker Service Management
function Test-DockerService {
    return [bool](Get-Service "com.docker.service" -ErrorAction SilentlyContinue)
}

function Start-DockerWithRetry {
    [CmdletBinding()]
    param(
        [int]$MaxRetries = 3,
        [int]$RetryDelay = 5
    )

    if (-not (Test-DockerService)) {
        Write-Host "Docker service not installed" -ForegroundColor Red
        return $false
    }

    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Start-Service "com.docker.service" -ErrorAction Stop
            $timeout = 30
            while ($timeout -gt 0) {
                if (docker info 2>$null) {
                    Write-Host "Docker started successfully" -ForegroundColor Green
                    return $true
                }
                Start-Sleep -Seconds 1
                $timeout--
            }
        } catch {
            Write-Host "Start attempt $i failed: $_" -ForegroundColor Yellow
            if ($i -lt $MaxRetries) {
                Write-Host "Retrying in $RetryDelay seconds..." -ForegroundColor Yellow
                Start-Sleep -Seconds $RetryDelay
            }
        }
    }
    Write-Host "Failed to start Docker after $MaxRetries attempts" -ForegroundColor Red
    return $false
}

# Directory Initialization
function Initialize-Environment {
    # Create directories
    $paths = $InstallPath, $ConfigPath, $LogPath
    foreach ($path in $paths) {
        if (-not (Test-Path $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }

    # Initialize log file
    if (-not (Test-Path $logFile)) {
        New-Item -Path $logFile -ItemType File -Force | Out-Null
    }
}

# Service Control
function Start-Services {
    # Generate docker-compose.yml
    $composeContent = @"
version: '3.8'
services:
  ollama:
    image: ollama/ollama
    ports:
      - "${OllamaPort}:11434"
    volumes:
      - "${InstallPath}/models:/root/.ollama"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
  webui:
    image: ghcr.io/open-webui/open-webui:main
    ports:
      - "${WebUIPort}:8080"
    environment:
      - OLLAMA_API_BASE_URL=http://ollama:11434
    depends_on:
      - ollama
"@
    $composeContent | Out-File $dockerComposeFile -Encoding utf8

    Write-Host "Starting Docker service..." -ForegroundColor Cyan
    if (-not (Start-DockerWithRetry)) {
        throw "Failed to start Docker service"
    }
    Write-Host "Starting Ollama and OpenWebUI containers..." -ForegroundColor Cyan
    try {
        docker-compose -f $dockerComposeFile up -d 2>&1 | Tee-Object -FilePath $logFile -Append
        Write-Host "Services started successfully" -ForegroundColor Green
    } catch {
        Write-Host "Failed to start services: $_" -ForegroundColor Red
        throw
    }
}

function Stop-Services {
    Write-Host "Stopping Ollama and OpenWebUI containers..." -ForegroundColor Cyan
    try {
        docker-compose -f $dockerComposeFile down 2>&1 | Tee-Object -FilePath $logFile -Append
        Write-Host "Stopping Docker service..." -ForegroundColor Cyan
        Stop-Service "com.docker.service" -ErrorAction SilentlyContinue
        Write-Host "Services stopped successfully" -ForegroundColor Green
    } catch {
        Write-Host "Error stopping services: $_" -ForegroundColor Red
        throw
    }
}

# Component Management
function Install-Components {
    # Check if Chocolatey is available
    $chocoAvailable = Get-Command choco -ErrorAction SilentlyContinue
    $wingetAvailable = Get-Command winget -ErrorAction SilentlyContinue

    if (-not $chocoAvailable -and -not $wingetAvailable) {
        Write-Host "Installing Chocolatey..." -ForegroundColor Cyan
        Set-ExecutionPolicy Bypass -Scope Process -Force
        iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        Refresh-Environment
        $chocoAvailable = Get-Command choco -ErrorAction SilentlyContinue
    }

    # Install Docker
    if (-not (Test-DockerService)) {
        Write-Host "Installing Docker Desktop..." -ForegroundColor Cyan
        if ($chocoAvailable) {
            choco install docker-desktop -y --force
        } elseif ($wingetAvailable) {
            winget install Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
        } else {
            throw "No package manager available to install Docker"
        }
    }

    # Install CUDA
    $sysReq = Test-SystemRequirements
    if (-not $sysReq.CUDA) {
        Write-Host "Installing CUDA Toolkit..." -ForegroundColor Cyan
        if ($chocoAvailable) {
            choco install cuda --version=12.8.0 -y --force
        } elseif ($wingetAvailable) {
            winget install NVIDIA.CUDA --accept-source-agreements --accept-package-agreements
        } else {
            throw "No package manager available to install CUDA"
        }
    }

    Initialize-Environment
    Refresh-Environment
}

function Reset-Configuration {
    Write-Host "Resetting configuration..." -ForegroundColor Cyan
    try {
        if (Test-Path $dockerComposeFile) {
            Remove-Item $dockerComposeFile -Force
        }
        if (Test-Path $logFile) {
            Remove-Item $logFile -Force
        }
        Write-Host "Configuration reset successfully" -ForegroundColor Green
    } catch {
        Write-Host "Error resetting configuration: $_" -ForegroundColor Red
        throw
    }
}

function Show-GPUInfo {
    Write-Host "GPU Information (nvidia-smi):" -ForegroundColor Cyan
    try {
        nvidia-smi --query-gpu=name,temperature.gpu,memory.used,memory.total --format=csv 2>&1 | Tee-Object -FilePath $logFile -Append
    } catch {
        Write-Host "Error retrieving GPU information: $_" -ForegroundColor Red
        throw
    }
}

# Refresh Environment Variables
function Refresh-Environment {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# User Interface
function Show-MainMenu {
    Clear-Host
    $sysReq = Test-SystemRequirements
    $svcStatus = Get-ServiceStatus

    Write-Host "Docker + Ollama Management System" -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    
    # System Status
    Write-Host "System: Windows 11: $(if($sysReq.OS){"[OK]"}else{"[NO]"}) " -NoNewline -ForegroundColor $(if($sysReq.OS){"Green"}else{"Red"})
    Write-Host "Free RAM: $($sysReq.FreeRAM)GB $(if($sysReq.RAM){"[OK]"}else{"[NO]"}) " -NoNewline -ForegroundColor $(if($sysReq.RAM){"Green"}else{"Red"})
    Write-Host "NVIDIA 4060: $(if($sysReq.GPU){"[OK]"}else{"[NO]"}) " -NoNewline -ForegroundColor $(if($sysReq.GPU){"Green"}else{"Red"})
    Write-Host "| CUDA 12.8: $(if($sysReq.CUDA){"[OK]"}else{"[NO]"})" -ForegroundColor $(if($sysReq.CUDA){"Green"}else{"Red"})

    # Service Status
    Write-Host "Service: Docker: $(if($svcStatus.Docker){"Running"}else{"Stopped"}) " -NoNewline -ForegroundColor $(if($svcStatus.Docker){"Green"}else{"Red"})
    Write-Host "Ollama: $(if($svcStatus.Ollama){"Running"}else{"Stopped"}) " -NoNewline -ForegroundColor $(if($svcStatus.Ollama){"Green"}else{"Red"})
    Write-Host "WebUI Port (${WebUIPort}): $(if($svcStatus.PortAvailable){"Available"}else{"Unavailable"}) " -NoNewline -ForegroundColor $(if($svcStatus.PortAvailable){"Green"}else{"Red"})
    Write-Host "Loaded Models: $($svcStatus.Models.Count)"
    if ($svcStatus.Models.Count -gt 0) {
        Write-Host "    $($svcStatus.Models -join "`n    ")"
    }
    Write-Host ""

    # Menu Options
    Write-Host "[Menu Options]" -ForegroundColor Green
    Write-Host "1) Install/Update Components (Docker, CUDA)"
    Write-Host "2) Start Services (Docker, Ollama, OpenWebUI)"
    Write-Host "3) Stop Services (Docker, Ollama, OpenWebUI)"
    Write-Host "4) View Service Logs"
    Write-Host "5) Update Docker Images (Ollama, OpenWebUI)"
    Write-Host "6) Reset Configuration"
    Write-Host "7) View GPU Information (nvidia-smi)"
    Write-Host "Q) Exit"
    Write-Host ""
}

# Main Program
function Start-Main {
    Initialize-Environment

    do {
        Show-MainMenu
        $choice = Read-Host "Select option"

        try {
            switch ($choice) {
                "1" { 
                    Install-Components
                    Write-Host "Components updated successfully" -ForegroundColor Green
                }
                "2" { 
                    if (-not (Test-DockerService)) { throw "Docker not installed" }
                    Start-Services 
                }
                "3" { 
                    Stop-Services 
                }
                "4" { 
                    if (Test-Path $logFile) {
                        Get-Content $logFile -Tail 50
                    } else {
                        Write-Host "No log file found" -ForegroundColor Yellow
                    }
                }
                "5" {
                    Write-Host "Updating Ollama image..." -ForegroundColor Cyan
                    docker pull ollama/ollama 2>&1 | Tee-Object -FilePath $logFile -Append
                    Write-Host "Updating OpenWebUI image..." -ForegroundColor Cyan
                    docker pull ghcr.io/open-webui/open-webui:main 2>&1 | Tee-Object -FilePath $logFile -Append
                    Write-Host "Docker images updated" -ForegroundColor Green
                }
                "6" {
                    Reset-Configuration
                }
                "7" {
                    Show-GPUInfo
                }
                "Q" { return }
                default { Write-Host "Invalid option" -ForegroundColor Red }
            }
        } catch {
            Write-Host "Error: $_" -ForegroundColor Red
        }

        if ($choice -ne "Q") {
            Write-Host "`nPress any key to continue..."
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
    } while ($true)
}

# Entry Point
try {
    Start-Main
} catch {
    Write-Host "Critical Error: $_" -ForegroundColor Red
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
