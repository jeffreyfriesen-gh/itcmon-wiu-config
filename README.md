# ITCMon configuration distribution

This repository distributes the reviewed ITCMon WIU definitions, railroad data,
truck server profiles, update launcher, and a net-new Windows laptop installer.

## Net-new Windows laptop

Connect the laptop to the truck LAN and use Windows PowerShell 5.1 or newer:

```powershell
$installer = Join-Path $env:TEMP 'Install-ITCMon-Truck-Client.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/jeffreyfriesen-gh/itcmon-wiu-config/main/scripts/Install-ITCMon-Truck-Client.ps1' -OutFile $installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
```

The installer downloads and validates the official ITCMon v0.9 Windows package,
installs it under `%LOCALAPPDATA%\Programs\ITCMon-v0.9`, applies the truck-client
profile, `rrdata.json`, and 52 reviewed WIU definitions, and creates an
`ITCMon - Truck` desktop shortcut.

The truck-client profile uses `telemetry-node.lan`. The GL.iNet truck router
must be the laptop's DNS server and must resolve that alias to the receiver VM.
The alias is deliberately generic, but it is not a security boundary; this
public repository still documents the service port pattern. Use
`-TruckHost <name-or-address>` only when an alternate endpoint is intentional.

## Layout

- `profiles/truck-client/profile.json`: public laptop profile using the generic
  router DNS name.
- `profiles/truck-vm201/profile.json`: local VM201 profile.
- `rrdata.json`: railroad-number and signal-aspect mappings.
- `wius/`: reviewed WIU decoder definitions.
- `manifest.json`: expected counts and SHA-256 for every distributed machine
  file.
- `scripts/Install-ITCMon-Truck-Client.ps1`: complete Windows client installer.
- `scripts/Start-ITCMon-With-Update.ps1`: validation, update, and launch wrapper.

## Existing installation

From an ITCMon directory, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Start-ITCMon-With-Update.ps1 `
  -InstallRoot .
```

If Git is installed, the wrapper performs a fast-forward-only pull into a
per-user cache. If Git is unavailable, it downloads the selected GitHub branch
archive over HTTPS. Native Git status text is captured separately, so it cannot
be mistaken for the repository-root return value.

The wrapper refuses to update while `itcmon.exe` is running. It validates every
published file, updates `rrdata.json` and the WIUs, and keeps a timestamped
backup before replacement. A server profile can regenerate `itcmon.json` when
its expected SHA-256 is supplied; without a profile, the existing server list
is preserved.

For an offline bootstrap, `-SourceRoot <path>` applies a previously extracted
copy of this repository without contacting GitHub.

This repository contains no credentials, private keys, access tokens, raw RF
captures, or decoded event history.
