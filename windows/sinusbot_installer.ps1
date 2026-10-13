<#
.SYNOPSIS
  SinusBot installer for Windows.

.DESCRIPTION
  The official Windows build of the SinusBot is discontinued. This script runs
  the current Linux build of the SinusBot on Windows instead, using one of two
  backends:

    Wsl     (default) Creates a dedicated WSL2 distribution (Ubuntu 22.04) with
            systemd enabled and runs the regular Linux installer
            (sinusbot_installer.sh) inside it. Always installs the latest
            SinusBot and TeamSpeak client release.

    Docker  Runs the official sinusbot/docker image with Docker Desktop.

  The web interface is reachable at http://localhost:8087 in both cases.

.PARAMETER Action
  Install, Update, Remove, Start, Stop, Status or PasswordReset.
  Without this parameter an interactive menu is shown.

.PARAMETER Mode
  Wsl (default) or Docker.

.PARAMETER Name
  Name of the WSL distribution or Docker container. Default: SinusBot

.PARAMETER InstallDir
  Directory holding the WSL distribution disk. Default: C:\SinusBot

.PARAMETER DiscordOnly
  Docker mode only: use the smaller discord-only image without TeamSpeak.

.PARAMETER Port
  Host port for the web interface. Default: 8087

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\sinusbot_installer.ps1

.EXAMPLE
  .\sinusbot_installer.ps1 -Action Install -Mode Docker
#>
[CmdletBinding()]
param(
  [ValidateSet('Install', 'Update', 'Remove', 'Start', 'Stop', 'Status', 'PasswordReset')]
  [string]$Action,
  [ValidateSet('Wsl', 'Docker')]
  [string]$Mode = 'Wsl',
  [string]$Name = 'SinusBot',
  [string]$InstallDir = 'C:\SinusBot',
  [switch]$DiscordOnly,
  [int]$Port = 8087
)

# Native tools (wsl.exe, docker) report progress on stderr, which Windows
# PowerShell turns into terminating errors under 'Stop'. Cmdlets that must
# not fail silently use -ErrorAction Stop instead.
$ErrorActionPreference = 'Continue'
$Instversion = '1.0'

$RootfsBaseUrl = 'https://cloud-images.ubuntu.com/wsl/jammy/current'
$RootfsFile = 'ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz'
$InstallerUrl = 'https://raw.githubusercontent.com/MYF540/installer-linux/master/sinusbot_installer.sh'
$TaskName = "$Name-KeepAlive"

# Functions

function Write-Green([string]$Text) { Write-Host $Text -ForegroundColor Green }
function Write-Cyan([string]$Text) { Write-Host $Text -ForegroundColor Cyan }
function Write-Yellow([string]$Text) { Write-Host $Text -ForegroundColor Yellow }
function Write-Red([string]$Text) { Write-Host $Text -ForegroundColor Red }

function Exit-WithError([string]$Text) {
  Write-Red $Text
  exit 1
}

function Read-Choice([string]$Question, [string[]]$Options) {
  Write-Red $Question
  for ($i = 0; $i -lt $Options.Count; $i++) {
    Write-Host ("{0}) {1}" -f ($i + 1), $Options[$i])
  }
  while ($true) {
    $answer = Read-Host '#?'
    $number = 0
    if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Options.Count) {
      return $Options[$number - 1]
    }
    Write-Red 'Invalid option.'
  }
}

function Confirm-Choice([string]$Question) {
  return (Read-Choice $Question @('Yes', 'No')) -eq 'Yes'
}

function Test-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Runs wsl.exe and returns its output as text. wsl.exe writes its own
# messages as UTF-16, so the console encoding is switched while it runs.
function Invoke-WslText([string[]]$Arguments) {
  $previous = [Console]::OutputEncoding
  try {
    [Console]::OutputEncoding = [Text.Encoding]::Unicode
    $output = & wsl.exe @Arguments 2>&1 | Out-String
  } finally {
    [Console]::OutputEncoding = $previous
  }
  return ($output -replace "`0", '').Trim()
}

# Runs a command as root inside the distribution. Start-Process hands this
# console to the process directly, so the interactive Linux installer can
# show its prompts. The command must not contain double quotes.
function Invoke-InDistro([string]$Command) {
  $process = Start-Process -FilePath 'wsl.exe' -NoNewWindow -Wait -PassThru `
    -ArgumentList "-d $Name -u root --exec bash -c `"$Command`""
  return $process.ExitCode
}

function Get-DistroOutput([string]$Command) {
  $output = & wsl.exe -d $Name -u root --exec bash -c $Command 2>$null | Out-String
  return $output.Trim()
}

function Test-DistroExists {
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
  $list = Invoke-WslText @('--list', '--quiet')
  return [bool]($list -split "\r?\n" | Where-Object { $_.Trim() -eq $Name })
}

# WSL mode

function Install-WslPlatform {
  $status = Invoke-WslText @('--status')
  if ($LASTEXITCODE -eq 0 -and $status -notmatch 'not installed|nicht installiert') {
    & wsl.exe --update | Out-Null
    & wsl.exe --set-default-version 2 | Out-Null
    return
  }

  if (-not (Test-Admin)) {
    Exit-WithError 'WSL is not installed yet. Please run this script once as administrator so it can be installed.'
  }

  Write-Green 'Installing the Windows Subsystem for Linux...'
  & wsl.exe --install --no-distribution
  if ($LASTEXITCODE -ne 0) {
    Exit-WithError 'Installing WSL failed. Make sure virtualization is enabled in the BIOS/UEFI.'
  }
  Write-Yellow 'WSL was installed. Please restart Windows and run this script again to continue.'
  exit 0
}

function Get-InstallerPath {
  New-Item -ItemType Directory -Force -Path $InstallDir -ErrorAction Stop | Out-Null
  # Prefer the installer next to this script (a checkout of the repository),
  # otherwise download the latest one.
  $local = ''
  if ($PSScriptRoot) {
    $local = Join-Path (Split-Path $PSScriptRoot -Parent) 'sinusbot_installer.sh'
  }
  if (-not $local -or -not (Test-Path $local)) {
    $local = Join-Path $InstallDir 'sinusbot_installer.sh'
    Write-Cyan "Downloading the Linux installer from $InstallerUrl"
    Invoke-WebRequest -UseBasicParsing -Uri $InstallerUrl -OutFile $local -ErrorAction Stop
  }
  # The installer has to keep Unix line endings to run inside Linux.
  $content = [IO.File]::ReadAllText($local) -replace "`r`n", "`n"
  $target = Join-Path $InstallDir 'sinusbot_installer.sh'
  [IO.File]::WriteAllText($target, $content, (New-Object Text.UTF8Encoding $false))
  return (Get-DistroOutput "wslpath -a '$($target -replace '\\', '/')'")
}

function New-WslDistro {
  New-Item -ItemType Directory -Force -Path $InstallDir -ErrorAction Stop | Out-Null
  $rootfs = Join-Path $InstallDir $RootfsFile

  Write-Green "Downloading Ubuntu 22.04 for WSL. This could take a while."
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -UseBasicParsing -Uri "$RootfsBaseUrl/$RootfsFile" -OutFile $rootfs -ErrorAction Stop

  $sums = (Invoke-WebRequest -UseBasicParsing -Uri "$RootfsBaseUrl/SHA256SUMS" -ErrorAction Stop).Content
  $expected = ($sums -split "\r?\n" | Where-Object { $_ -match [regex]::Escape($RootfsFile) } | Select-Object -First 1) -replace '\s.*$', ''
  $actual = (Get-FileHash -Algorithm SHA256 -Path $rootfs).Hash
  if (-not $expected -or $actual -ne $expected.ToUpper()) {
    Remove-Item $rootfs -Force
    Exit-WithError 'Checksum of the downloaded Ubuntu image does not match. Please try again.'
  }

  Write-Green "Creating WSL distribution '$Name' in $InstallDir"
  & wsl.exe --import $Name (Join-Path $InstallDir 'wsl') $rootfs --version 2
  if ($LASTEXITCODE -ne 0) {
    Exit-WithError 'Creating the WSL distribution failed.'
  }
  Remove-Item $rootfs -Force

  # The Linux installer creates a systemd service, so systemd has to run.
  Invoke-InDistro "printf '[boot]\nsystemd=true\n\n[user]\ndefault=root\n' > /etc/wsl.conf" | Out-Null
  & wsl.exe --terminate $Name | Out-Null
  Start-Sleep -Seconds 3

  # The Linux installer restarts systemd-timesyncd on Ubuntu 22.04.
  Invoke-InDistro 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd-timesyncd wget' | Out-Null
}

function Register-KeepAliveTask {
  # WSL stops a distribution shortly after its last process exits. This task
  # keeps it (and with it the SinusBot service) running from logon on.
  $command = "wsl.exe -d $Name -u root --exec sleep infinity"
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -Command `"$command`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
  Start-ScheduledTask -TaskName $TaskName
  Write-Green "Added scheduled task '$TaskName' so the SinusBot starts when you log on."
}

function Start-WslBot {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3
  }
  Invoke-InDistro 'systemctl start sinusbot' | Out-Null
}

function Invoke-WslAction([string]$Selected) {
  $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
  if ($arch -ne 'AMD64') {
    Exit-WithError 'The SinusBot for Linux only runs on x86_64 (AMD64) systems.'
  }

  if ($Selected -ne 'Install' -and -not (Test-DistroExists)) {
    Exit-WithError "WSL distribution '$Name' not found. Please install the SinusBot first."
  }

  switch ($Selected) {
    'Install' {
      Install-WslPlatform
      if (Test-DistroExists) {
        Write-Yellow "WSL distribution '$Name' already exists, reusing it."
      } else {
        New-WslDistro
      }
      $installer = Get-InstallerPath
      Write-Yellow 'The Linux installer starts now. Choose "Install" and answer its questions.'
      if ((Invoke-InDistro "bash '$installer'") -ne 0) {
        Exit-WithError 'The Linux installer did not finish. Check its output above.'
      }
      Register-KeepAliveTask
      Write-Green "Done. Open http://localhost:$Port in your browser."
    }
    'Update' {
      $installer = Get-InstallerPath
      Write-Yellow 'The Linux installer starts now. Choose "Update".'
      $null = Invoke-InDistro "bash '$installer'"
      Start-WslBot
    }
    'PasswordReset' {
      $installer = Get-InstallerPath
      Write-Yellow 'The Linux installer starts now. Choose "PW Reset".'
      $null = Invoke-InDistro "bash '$installer'"
    }
    'Start' {
      Start-WslBot
      Write-Green "SinusBot started: http://localhost:$Port"
    }
    'Stop' {
      Invoke-InDistro 'systemctl stop sinusbot' | Out-Null
      Write-Green 'SinusBot stopped.'
    }
    'Status' {
      $null = Invoke-InDistro 'systemctl status sinusbot --no-pager'
    }
    'Remove' {
      Write-Red "This deletes the WSL distribution '$Name' including the SinusBot, its data and all scripts."
      if (-not (Confirm-Choice 'Remove everything?')) { return }
      Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
      & wsl.exe --unregister $Name
      Write-Green 'SinusBot removed.'
    }
  }
}

# Docker mode

function Test-Docker {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Exit-WithError 'Docker was not found. Install Docker Desktop (https://www.docker.com/products/docker-desktop/) and start it, or use -Mode Wsl.'
  }
  & docker info *> $null
  if ($LASTEXITCODE -ne 0) {
    Exit-WithError 'Docker is installed but not running. Please start Docker Desktop and try again.'
  }
}

function Test-ContainerExists {
  $names = & docker ps -a --filter "name=^/$Name$" --format '{{.Names}}'
  return [bool]$names
}

function New-BotContainer([string]$OverridePassword) {
  $image = if ($DiscordOnly) { 'sinusbot/docker:discord' } else { 'sinusbot/docker:latest' }
  $arguments = @('run', '-d', '--name', $Name, '--restart', 'unless-stopped',
    '-p', "${Port}:8087",
    '-v', "$Name-data:/opt/sinusbot/data",
    '-v', "$Name-scripts:/opt/sinusbot/scripts")
  if ($OverridePassword) {
    $arguments += @('-e', "OVERRIDE_PASSWORD=$OverridePassword")
  }
  $arguments += $image
  & docker pull $image
  & docker @arguments | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Exit-WithError 'Starting the SinusBot container failed.'
  }
}

function Remove-BotContainer {
  & docker rm -f $Name *> $null
}

function Get-InitialPassword {
  for ($i = 0; $i -lt 30; $i++) {
    $logs = & docker logs $Name 2>&1 | Out-String
    if ($logs -match "account 'admin' and password '([^']+)'") {
      return $Matches[1]
    }
    Start-Sleep -Seconds 2
  }
  return $null
}

function New-RandomPassword {
  $chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
  return -join (1..12 | ForEach-Object { $chars | Get-Random })
}

function Invoke-DockerAction([string]$Selected) {
  Test-Docker

  if ($Selected -notin @('Install', 'Update') -and -not (Test-ContainerExists)) {
    Exit-WithError "Container '$Name' not found. Please install the SinusBot first."
  }

  switch ($Selected) {
    'Install' {
      if (Test-ContainerExists) {
        Write-Yellow "Container '$Name' already exists. Use -Action Update to update it."
        return
      }
      if (-not (Confirm-Choice 'This SinusBot version is only for private use! Accept?')) { return }
      New-BotContainer
      $password = Get-InitialPassword
      Write-Green "Done. Open http://localhost:$Port in your browser."
      if ($password) {
        Write-Green "Login with user 'admin' and password '$password'. Change the password after your first login!"
      } else {
        Write-Yellow "Could not read the password yet. Run: docker logs $Name"
      }
      Write-Cyan "Copy a license file into the bot with: docker cp private.dat ${Name}:/opt/sinusbot/data/ ; docker restart $Name"
    }
    'Update' {
      Write-Green 'Updating the SinusBot image. Data and scripts are kept.'
      Remove-BotContainer
      New-BotContainer
      Write-Green "SinusBot updated: http://localhost:$Port"
    }
    'PasswordReset' {
      $password = New-RandomPassword
      Remove-BotContainer
      New-BotContainer $password
      Start-Sleep -Seconds 15
      # Recreate without the override, otherwise every restart resets the password.
      Remove-BotContainer
      New-BotContainer
      Write-Green "Password of user 'admin' reset to '$password'. Change it after logging in!"
    }
    'Start' {
      & docker start $Name | Out-Null
      Write-Green "SinusBot started: http://localhost:$Port"
    }
    'Stop' {
      & docker stop $Name | Out-Null
      Write-Green 'SinusBot stopped.'
    }
    'Status' {
      & docker ps -a --filter "name=^/$Name$"
      & docker logs --tail 20 $Name
    }
    'Remove' {
      if (-not (Confirm-Choice "Remove the SinusBot container '$Name'?")) { return }
      Remove-BotContainer
      if (Confirm-Choice 'Also delete all data and scripts (Docker volumes)?') {
        & docker volume rm "$Name-data" "$Name-scripts" | Out-Null
      }
      Write-Green 'SinusBot removed.'
    }
  }
}

# Main

Write-Green 'This is the automatic installer for the latest SinusBot on Windows. USE AT YOUR OWN RISK!'
Write-Cyan "The SinusBot for Linux runs on Windows via $Mode. You're using installer $Instversion"

if (-not $Action) {
  $choice = Read-Choice 'What should the installer do?' @('Install', 'Update', 'Remove', 'Start', 'Stop', 'Status', 'PW Reset', 'Quit')
  if ($choice -eq 'Quit') { exit 0 }
  $Action = if ($choice -eq 'PW Reset') { 'PasswordReset' } else { $choice }
}

if ($Mode -eq 'Wsl') {
  Invoke-WslAction $Action
} else {
  Invoke-DockerAction $Action
}
