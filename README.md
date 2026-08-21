# ITCMon configuration distribution

This repository distributes the reviewed ITCMon WIU definitions, railroad data,
truck server profiles, update launcher, and a net-new Windows laptop installer
for ITCMon, ITCWatch, and ATCSMon.

## Net-new Windows laptop

Connect the laptop to the truck LAN, open **Windows PowerShell**, and paste the
following block into that already-open window. This resolves public `main` to
an immutable commit, downloads the new `itc-truck-mon.ps1` entry point, and
runs it in the same visible console:

```powershell
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repo = 'jeffreyfriesen-gh/itcmon-wiu-config'
$headers = @{ 'User-Agent'='ITCM-Truck-Net-New-Installer'; 'Accept'='application/vnd.github+json' }
$commit = (Invoke-RestMethod -UseBasicParsing -TimeoutSec 60 -Headers $headers -Uri "https://api.github.com/repos/$repo/commits/main").sha
if ($commit -notmatch '^[0-9a-fA-F]{40}$') { throw "GitHub returned an invalid commit: $commit" }
$script = Join-Path $env:TEMP "itc-truck-mon-$commit.ps1"
$uri = "https://raw.githubusercontent.com/$repo/$commit/itc-truck-mon.ps1"
if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
  & curl.exe --fail --location --retry 4 --retry-delay 2 --connect-timeout 20 --max-time 180 --output $script $uri
  if ($LASTEXITCODE -ne 0) { throw "Installer entry-point download failed with curl exit $LASTEXITCODE" }
} else {
  Invoke-WebRequest -UseBasicParsing -TimeoutSec 180 -Uri $uri -OutFile $script
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script
if ($LASTEXITCODE -ne 0) { throw "ITC truck client installer failed with exit code $LASTEXITCODE. The visible window and persistent log identify the failed stage." }
```

The entry point logs before doing work, downloads and validates the immutable
repository bundle, checks the truck artifact host's actual HTTP health, and
keeps the visible console open on failure. Before replacing any application
files, the elevated installer force-stops every executable launched from the
resolved ITCM installation tree plus the known legacy ATCSMon path. It also
uses Windows Restart Manager to identify file-handle owners, stops an owning
script host only when its command line references a file inside that exact
installation tree, and never force-stops an unrecognized lock owner. The
atomic rollback move is retried for up to 20 seconds so transient antivirus or
indexer locks can clear; a persistent failure reports the exact source,
destination, owning PID/application when Windows supplies one, and script line.

## Legacy inline bootstrap reference

The block below is retained as an implementation reference. Use the shorter
`itc-truck-mon.ps1` block above for normal net-new installations.

Connect the laptop to the truck LAN and paste this into an already-open Windows
PowerShell 5.1 or newer window:

```powershell
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repo = 'jeffreyfriesen-gh/itcmon-wiu-config'
$run = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$logRoot = Join-Path $env:LOCALAPPDATA 'ITCMon\InstallerLogs'
try { New-Item -ItemType Directory -Path $logRoot -Force | Out-Null } catch {
  $logRoot = Join-Path $env:TEMP 'ITCMon-InstallerLogs'
  New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
}
$preLog = Join-Path $logRoot "prebootstrap-$run.log"
$preStatus = Join-Path $logRoot 'last-prebootstrap-status.json'
$work = Join-Path $env:TEMP "itcm-prebootstrap-$run-$PID"
$failed = $false
$stage = 'initialize diagnostics'
function Save-PrebootstrapStatus([string]$outcome, [string]$errorMessage = '') {
  [ordered]@{
    schema='itcm.client.prebootstrap.status.v1'; run_id=$run
    updated_at=(Get-Date).ToUniversalTime().ToString('o'); outcome=$outcome
    stage=$stage; error=$errorMessage; prebootstrap_log=$preLog; work_root=$work
  } | ConvertTo-Json | Set-Content -LiteralPath $preStatus -Encoding UTF8
}
Start-Transcript -LiteralPath $preLog -Force | Out-Null
try {
  Save-PrebootstrapStatus 'running'
  Write-Host "[prebootstrap] Log: $preLog"
  $stage = 'resolve GitHub main to an immutable commit'
  $headers = @{ 'User-Agent'='ITCM-Client-Prebootstrap'; 'Accept'='application/vnd.github+json' }
  $commit = (Invoke-RestMethod -UseBasicParsing -TimeoutSec 60 -Headers $headers -Uri "https://api.github.com/repos/$repo/commits/main").sha
  if ($commit -notmatch '^[0-9a-fA-F]{40}$') { throw "GitHub returned an invalid main commit: $commit" }
  $stage = 'download immutable GitHub archive'
  New-Item -ItemType Directory -Path $work -Force | Out-Null
  $zip = "$work.zip"
  if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
    & curl.exe --fail --location --retry 4 --connect-timeout 20 --max-time 180 --output $zip "https://github.com/$repo/archive/$commit.zip"
    if ($LASTEXITCODE -ne 0) { throw "Immutable archive download failed with curl exit $LASTEXITCODE." }
  } else {
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 180 -Uri "https://github.com/$repo/archive/$commit.zip" -OutFile $zip
  }
  $stage = 'validate bootstrap against manifest'
  Expand-Archive -LiteralPath $zip -DestinationPath $work -Force
  $roots = @(Get-ChildItem -LiteralPath $work -Directory)
  if ($roots.Count -ne 1) { throw "GitHub archive contained $($roots.Count) roots; expected one." }
  $manifest = Get-Content -Raw -LiteralPath (Join-Path $roots[0].FullName 'manifest.json') | ConvertFrom-Json
  $entry = @($manifest.files | Where-Object path -eq 'scripts/Bootstrap-ITCM-Truck-Client.ps1')
  if ($entry.Count -ne 1) { throw 'Manifest has no unique net-new bootstrap entry.' }
  $bootstrap = Join-Path $roots[0].FullName 'scripts\Bootstrap-ITCM-Truck-Client.ps1'
  $actual = (Get-FileHash -LiteralPath $bootstrap -Algorithm SHA256).Hash
  if ($actual -ne ([string]$entry[0].sha256).ToUpperInvariant()) { throw "Bootstrap SHA-256 mismatch: $actual" }
  $stage = 'run validated bootstrap'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrap -LogRoot $logRoot
  if ($LASTEXITCODE -ne 0) { throw "Validated bootstrap exited with code $LASTEXITCODE." }
  $stage = 'complete'
  Save-PrebootstrapStatus 'success'
} catch {
  $failed = $true
  $failureMessage = $_.Exception.Message
  Save-PrebootstrapStatus 'failed' $failureMessage
  Write-Host '========== NET-NEW PREBOOTSTRAP FAILED ==========' -ForegroundColor Red
  Write-Host "Stage: $stage" -ForegroundColor Red
  Write-Host $failureMessage -ForegroundColor Red
  Write-Host "Prebootstrap log: $preLog" -ForegroundColor Yellow
  Write-Host "Prebootstrap status: $preStatus" -ForegroundColor Yellow
  if (Test-Path -LiteralPath $work) {
    Write-Host "Retained work directory: $work" -ForegroundColor Yellow
  }
  Write-Host '=================================================' -ForegroundColor Red
} finally {
  if (-not $failed) {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    if (Test-Path -LiteralPath "$work.zip") { Remove-Item -LiteralPath "$work.zip" -Force }
  }
  Stop-Transcript | Out-Null
}
if ($failed) {
  [void](Read-Host 'Installation failed. Press Enter after recording the log path')
  throw "Net-new installation failed. See $preLog"
}
```

The installer downloads SHA-256-pinned packages for ITCMon v1.0, ITCWatch
v0.5.0, and ATCSMon v4.2.6 from the truck-only `svc-cache.lan` artifact host.
GitHub supplies the public installer, configuration, WIUs, and package hashes;
the application binaries are not stored in this repository. The laptop must
be able to reach both GitHub and the truck LAN during first installation.

The applications are installed under the existing managed client directory
when one can be identified, or `%LOCALAPPDATA%\Programs\ITCM-Client` for a new
installation. The installer applies the truck-client profile, `rrdata.json`,
and 95 reviewed WIU definitions, and creates `ITCMon - Truck`,
`ITCWatch - Truck`, `ATCSMon - Truck`, and `Diagnose ITCM Truck Client`
desktop shortcuts. The ITCMon shortcut uses the managed red-and-white ITCMon
icon; the updater checksum-validates the icon and repairs both the local icon
and shortcut on later launches.

ITCMon v1.0's active managed JSON files are under the release-native `local`
directory. ITCWatch shares ITCMon's `rrdata.json` and `wius` directory.
Its shortcut starts ITCMon first when necessary because ITCWatch consumes
ITCMon's local `zjpub` stream. The installer and launcher force ITCWatch's
`%APPDATA%\itcmon-viewer\viewer-config.json` to exactly one enabled endpoint,
`127.0.0.1:18001`; ITCWatch must not point directly at either receiver.

The application shortcuts use a common resilient launcher. When all three
programs are stopped, it fetches and validates the current manifest, updates
the reviewed application packages when their published hashes change, updates
the launchers, `rrdata.json`, WIUs, icon, shortcuts, and truck-client server
profile, and then starts the selected application. When any program is already running, it safely
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
The paste-in prebootstrap logs before downloading executable PowerShell. It
resolves GitHub `main` to an immutable commit, downloads that commit ZIP, and
checks the bootstrap against the ZIP's manifest instead of trusting a mutable
raw-branch cache. The validated bootstrap then independently validates every
manifest-managed file, checks DNS and TCP reachability for the internal
artifact host, resolves a safe current-user installation root before elevation,
and only then starts the elevated runner and installer. Existing shortcut
locations under the Windows system directory are rejected and recorded instead
of being reused; a new install falls back to
`%LOCALAPPDATA%\Programs\ITCM-Client`.
Prebootstrap, bootstrap, elevated-runner, and installer transcripts plus
structured last-status JSON are retained under
`%LOCALAPPDATA%\ITCMon\InstallerLogs`.
On failure, both the elevated window and the original bootstrap window remain
open until Enter is pressed; the bootstrap prints the exact failed stage,
error, relevant log paths, and the final 120 lines of the installer log.

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
  file plus the reviewed ITCMon, ITCWatch, and ATCSMon packages and the ITCMon
  shortcut icon.
- `runtime/vm202/up-omaha.json`: the manifest-pinned curated decoder catalog
  consumed by VM202. Its Linux timer downloads this exact GitHub `main` file,
  validates its manifest hash and schema, and restarts `itcmhub` only when the
  installed hash changes.
- `scripts/Bootstrap-ITCM-Truck-Client.ps1`: pre-elevation diagnostics,
  immutable GitHub archive validation, artifact-host preflight, structured
  status, failure pause, and orchestration of the elevated runner.
- `scripts/Invoke-ITCM-ElevatedInstaller.ps1`: captures failures that occur
  before the installer body can initialize its own transcript.
- `scripts/Install-ITCMon-Truck-Client.ps1`: complete Windows client installer.
- `scripts/Start-ITCMon-With-Update.ps1`: validation, update, and launch wrapper.
- `scripts/Invoke-ITCM-BackgroundUpdate.ps1`: non-interactive, process-safe,
  logged GitHub `main` updater for scheduled execution.
- `scripts/Register-ITCM-GitHub-UpdateTask.ps1`: installs the SYSTEM startup
  and 15-minute retry task used by VM201.
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

`Diagnose ITCM Truck Client` validates all three executables, the manifest-selected
combined server count, ITCWatch's exact local endpoint, `rrdata.json`, the installed
WIU inventory, DNS resolution, current ITCMon/ITCWatch/ATCSMon processes, local zjpub
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

The wrapper refuses to update while ITCMon, ITCWatch, or ATCSMon is running. It validates
every published file, refreshes itself, updates the reviewed application
packages, shortcut icon, shortcuts, `rrdata.json`, WIUs, and selected server profile, and keeps
timestamped configuration and application backups before replacement. Software
updates are deliberately manifest-controlled: a newly released upstream build
is installed only after its version, URL, and hashes are published here. This
prevents an unreviewed upstream change from silently replacing the truck client.

VM201 also uses the `ITCM GitHub Configuration Update` scheduled task. It runs
at startup and every 15 minutes as SYSTEM, pulls only branch `main` into the
machine cache under `C:\ProgramData\ITCMon`, validates the complete manifest,
and applies configuration only while ITCMon, ITCWatch, and ATCSMon are stopped.
A busy client is a successful deferral, not an unsafe in-use replacement.
Status and bounded transcripts are retained under
`C:\ProgramData\ITCMon\GitHubUpdater`.

For an offline bootstrap, `-SourceRoot <path>` applies a previously extracted
copy of this repository without contacting GitHub.

This repository contains no credentials, private keys, access tokens, raw RF
captures, or decoded event history.
