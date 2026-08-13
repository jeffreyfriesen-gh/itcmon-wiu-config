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
truck-client profile, `rrdata.json`, and 95 reviewed WIU definitions, and
creates `ITCMon - Truck`, `ITCWatch - Truck`, and `Diagnose ITCM Truck Client`
desktop shortcuts. ITCWatch shares ITCMon's `rrdata.json` and `wius` directory.
Its shortcut starts ITCMon first when necessary because ITCWatch consumes
ITCMon's local `zjpub` stream. The installer and launcher force ITCWatch's
`%APPDATA%\itcmon-viewer\viewer-config.json` to exactly one enabled endpoint,
`127.0.0.1:18001`; ITCWatch must not point directly at either receiver.

The application shortcuts use a common resilient launcher. When both programs
are stopped, it fetches and validates the current manifest, updates the reviewed
ITCMon and ITCWatch packages when their published hashes change, updates the
launchers, `rrdata.json`, WIUs, and truck-client server profile, and then starts
the selected application. When either program is already running, it safely
defers updates instead of rejecting the launch. Selecting an already-running
application reports that state and points the operator to the Windows
notification area rather than silently closing.

An unavailable GitHub connection no longer prevents a healthy installed client
from opening. The launcher records the failed update, validates the installed
executables and configuration, and starts the last-known-good copy. It refuses
that fallback only when local validation fails.
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

The truck-client profile combines 36 ITCM-PVE endpoints with Railfan-01's 17
resource-bounded endpoints, for 53 enabled ITCMon servers. ITCM-PVE monitors
both HR and FR on the nine operator-selected base/mobile pairs: 101/141,
102/142, 113/153, 114/154, 125/165, 126/166, 127/167, 131/171, and 132/172.
These are the normal 25 kHz blocks marked Nationwide/National or Regional in
the operator-reviewed channel-plan workbook; the separate 5 kHz allocations
are intentionally excluded.

Railfan-01 uses the requested seven-pair subset: 101/141, 102/142, 113/153,
114/154, 125/165, 126/166, and 127/167. It runs HR on all 14 frequencies and
retains FR only on packet-observed channels 141, 142, and 153. This preserves
the already-validated 17-decoder ceiling because the Pi was thermally capped
near that workload; enabling both modes on all 14 frequencies would expand it
to 28 decoders without evidence that the Pi can sustain that load.

The GL.iNet truck router must be the laptop's DNS server and must resolve
`telemetry-node.lan` to the receiver VM. `railfan-01` must resolve through its
validated network path. The aliases are deliberately generic, but they are not
a security boundary; this public repository still documents the service port
pattern. Use
`-TruckHost <name-or-address>` only when an alternate endpoint is intentional.

## Layout

- `profiles/truck-client/profile.json`: public laptop profile using the generic
  router DNS name.
- `profiles/truck-vm201/profile.json`: local VM201 profile.
- `receiver-profiles/railfan-01/`: the Pi's exact frequency, decoder, and local
  recorder-listener profiles.
- `recording-profiles/truck-vm202/profile.json`: the 36 VM201 endpoints that
  both `itcm-capture` and `itcmhub` must consume.
- `rrdata.json`: railroad-number and signal-aspect mappings.
- `wius/`: reviewed WIU decoder definitions.
- `wius/802/802001.json`: reviewed Omaha-corridor definitions, including the
  v0.9 `MP` field on WIUs whose working site assignment has a known
  milepost. No `MP` value is synthesized for unresolved WIUs or for 57th
  Street because its WIU has not yet been observed.
- `manifest.json`: expected counts and SHA-256 for every distributed machine
  file plus the reviewed ITCMon and ITCWatch application packages.
- `scripts/Install-ITCMon-Truck-Client.ps1`: complete Windows client installer.
- `scripts/Start-ITCMon-With-Update.ps1`: validation, update, and launch wrapper.
- `scripts/Launch-ITCM-Truck-Client.ps1`: process-aware launcher,
  last-known-good fallback, endpoint diagnostics, persistent status, and
  bounded launch logs.

## WIU naming convention

- Keep the display `name` free of mileposts; store a known milepost as the
  string property `MP` on the same wayside object.
- Prefix every non-empty Union Pacific display name with `UP `. Railroad
  prefixes for other carriers are intentionally deferred until defined.
- Use `UP Location - Main 1` or `UP Location - Main 2` for track-specific WIUs.
  Do not abbreviate the track as `M1` or `M2`.
- Use `UP Location (CP Bxxx)` only for a control point tied to a confirmed
  ATCSMon/MCP output, followed by ` - Main 1`/` - Main 2` only when the WIU is
  track-specific. Intermediate automatic signals use `UP Location - Main N`
  without a CP designation. If a proposed CP association has no confirmed
  ATCSMon/MCP mapping, keep the WIU unresolved rather than displaying the CP.
- Keep confidence and evidence status in the supporting records rather than
  adding `candidate`, `automatic`, or `WIU` to a confirmed display name.

Repository validation rejects a non-empty UP name lacking the `UP ` prefix, a
name that embeds an `MP` value or uses the `M1`/`M2` abbreviations, or a name
that claims a CP without an `atcs` mapping so later updates preserve this
convention.

## Launch diagnostics

Every shortcut launch writes a timestamped log under
`%LOCALAPPDATA%\ITCMon\Logs` and atomically refreshes
`%LOCALAPPDATA%\ITCMon\last-launch-status.json`. The newest 30 logs are kept.
On failure, the error remains in the console, a message box names the persistent
log, and the batch launcher waits for a keypress.

`Diagnose ITCM Truck Client` validates both executables, the manifest-selected
combined server count, ITCWatch's exact local endpoint, `rrdata.json`, the installed
WIU inventory, DNS resolution, current ITCMon/ITCWatch processes, local zjpub
port 18001, representative telemetry-node HR/FR ports, and representative
Railfan-01 HR/FR ports. Endpoint failures are
reported but do not mark an otherwise valid offline laptop installation as
corrupt.

`receiver-profiles/itcm-pve/channels.json` is the receiver-side frequency table
for the 18 selected logical channels. ITCM-PVE launches MCR with `-a` to
instantiate both HR and FR decoders for every entry: 36 S2P processes.
`channel-plans/ptc-220.json` preserves the complete FCC/25 kHz formulas while
separately recording the narrower operator monitoring policy. On VM202, both
recording consumers subscribe to all 36 endpoints, so a healthy system has 72
established VM202-to-VM201 TCP connections.

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
