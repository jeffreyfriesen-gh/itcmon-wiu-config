# ITCMon configuration distribution

This repository distributes the reviewed ITCMon WIU definitions, railroad data,
truck server profiles, update launcher, and a net-new Windows laptop installer
for both ITCMon and ITCWatch.

## Net-new Windows laptop

Connect the laptop to the truck LAN and use Windows PowerShell 5.1 or newer:

```powershell
$installer = Join-Path $env:TEMP 'Install-ITCMon-Truck-Client.ps1'
$installerUrl = 'https://raw.githubusercontent.com/jeffreyfriesen-gh/itcmon-wiu-config/main/scripts/Install-ITCMon-Truck-Client.ps1'
if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
  & curl.exe --fail --location --retry 4 --connect-timeout 20 --max-time 120 --output $installer $installerUrl
  if ($LASTEXITCODE -ne 0) { throw "Installer download failed with curl exit $LASTEXITCODE." }
} else {
  Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Uri $installerUrl -OutFile $installer
}
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
```

The installer downloads and validates the official ITCMon v0.9 Windows package
and the official [ITCWatch v0.4.0 release](https://github.com/katsojuna/itcwatch/releases/tag/v0.4.0).
It installs both under `%LOCALAPPDATA%\Programs\ITCMon-v0.9`, applies the
truck-client profile, `rrdata.json`, and 52 reviewed WIU definitions, and
creates `ITCMon - Truck` and `ITCWatch - Truck` desktop shortcuts. ITCWatch
shares ITCMon's `rrdata.json` and `wius` directory. Its shortcut starts ITCMon
first when necessary because ITCWatch consumes ITCMon's local `zjpub` stream.
Both shortcuts are update-first launchers: while the applications are closed,
they fetch and validate the current manifest, update the reviewed ITCMon and
ITCWatch packages when their published hashes change, update the launcher,
`rrdata.json`, WIUs, and the truck-client server profile, and then start the
selected application. If ITCMon is already running, the ITCWatch shortcut opens
ITCWatch immediately and defers updates until the next stopped-stack launch.
Large downloads use `curl.exe` with redirects, connection limits, bounded
per-attempt runtime, and up to five explicit attempts. A failed transfer keeps
its partial file and the next attempt resumes from the retained byte count when
the server supports HTTP ranges; it no longer silently restarts a large file
from byte zero. Each attempt is numbered. The installer also prints numbered
stages plus a download heartbeat every ten seconds with elapsed time and bytes
received. After 30 seconds without file growth, the heartbeat marks a possible
stall. A failure names the active stage and its final error. Windows
PowerShell's `Invoke-WebRequest` is only a three-attempt fallback when
`curl.exe` is absent; that fallback explicitly reports that it cannot resume a
partial file before restarting an attempt.

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
- `wius/802/802001.json`: reviewed Omaha-corridor definitions, including the
  v0.9 `MP` field on 13 WIUs whose working site assignment has a known
  milepost. No `MP` value is synthesized for unresolved WIUs or for 57th
  Street because its WIU has not yet been observed.
- `manifest.json`: expected counts and SHA-256 for every distributed machine
  file plus the reviewed ITCMon and ITCWatch application packages.
- `scripts/Install-ITCMon-Truck-Client.ps1`: complete Windows client installer.
- `scripts/Start-ITCMon-With-Update.ps1`: validation, update, and launch wrapper.

## Existing installation

From an ITCMon directory, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Start-ITCMon-With-Update.ps1 `
  -InstallRoot . `
  -ProfileName truck-client `
  -ServerHostOverride telemetry-node.lan `
  -UpdateApplications
```

If Git is installed, the wrapper performs a fast-forward-only pull into a
per-user cache. If Git is unavailable, it downloads the selected GitHub branch
archive over HTTPS. Native Git status text is captured separately, so it cannot
be mistaken for the repository-root return value.

The wrapper refuses to update while ITCMon or ITCWatch is running. It validates
every published file, refreshes itself, updates the reviewed application
packages, `rrdata.json`, WIUs, and selected server profile, and keeps
timestamped configuration and application backups before replacement. Software
updates are deliberately manifest-controlled: a newly released upstream build
is installed only after its version, URL, and hashes are published here. This
prevents an unreviewed upstream change from silently replacing the truck client.

For an offline bootstrap, `-SourceRoot <path>` applies a previously extracted
copy of this repository without contacting GitHub.

This repository contains no credentials, private keys, access tokens, raw RF
captures, or decoded event history.
