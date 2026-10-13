# SinusBot Installer for Linux

![Build Status](https://github.com/sinusbot/installer-linux/workflows/CI/badge.svg)

## Officially supported Linux distributions

- Debian 9+
- Ubuntu 16.10+
- CentOS 7+

## Features

- Install the SinusBot to a selected folder
  - Automatic = /opt/sinusbot
  - or own dir
- Update the SinusBot and youtube-dl
- Reset the password
- Uninstall the bot

The following tasks will be done:

- Checks if the linux distribution is supported
- Installs the latest supported version of the teamspeak client
- Installs all the necessary dependencies
- Creates a separated user
- Installs the latest SinusBot version
- Installs youtube-dl
- Adds a cronjob for daily youtube-dl update
- Sets all the file permissions correctly
- Generates startup files:
  - systemd file => `service sinusbot {start|stop|restart|status}`
  - init.d => `/etc/init.d/sinusbot {start|stop|restart}`
- Removes all temporary files
- Starts the SinusBot after installation

The duration of the installation process depends on your system (how many packages need to be updated, internet connection, processing power) but typically takes about one to five minutes.

> There's *no support* for *Plesk* or outdated operating systems like *Debian 7*!

[![Watch video](https://img.youtube.com/vi/_GEd_ert7PA/0.jpg)](https://www.youtube.com/watch?v=_GEd_ert7PA)

## Installation

```bash
bash <(wget --no-check-certificate -O - 'https://raw.githubusercontent.com/SinusBot/installer-linux/master/sinusbot_installer.sh')
```

This command basically downloads the latest version of the installer-script and executes it via the bash.

## Windows

The official Windows build of the SinusBot is discontinued. [`windows/sinusbot_installer.ps1`](windows/sinusbot_installer.ps1) runs the current Linux build on Windows 10/11 (x64) instead, using one of two backends:

- **WSL2** (default): creates its own WSL2 distribution `SinusBot` (Ubuntu 22.04 with systemd) under `C:\SinusBot` and runs this Linux installer inside it, so you always get the latest SinusBot and TeamSpeak client. A scheduled task keeps the bot running while you are logged on. WSL itself is installed automatically if it is missing (needs administrator rights once and a reboot).
- **Docker**: runs the official [`sinusbot/docker`](https://hub.docker.com/r/sinusbot/docker) image with Docker Desktop. Data and scripts live in the Docker volumes `SinusBot-data` and `SinusBot-scripts`.

Open PowerShell in the repository folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\sinusbot_installer.ps1                # WSL2, interactive menu
powershell -ExecutionPolicy Bypass -File .\windows\sinusbot_installer.ps1 -Mode Docker   # Docker Desktop
```

Actions can also be passed directly: `-Action Install|Update|Remove|Start|Stop|Status|PasswordReset`. Afterwards the web interface is reachable at <http://localhost:8087>.

To reach the web interface from other devices in your network while using WSL2, enable mirrored networking (`networkingMode=mirrored` in `%UserProfile%\.wslconfig`) and allow port 8087 in the Windows firewall.

## Contribution

If you want to contribute, the sourcecode is formatted with the [shell-format](https://marketplace.visualstudio.com/items?itemName=foxundermoon.shell-format) extension from VS Code.
