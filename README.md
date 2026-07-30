# ITCMon configuration distribution

This repository distributes reviewed ITCMon WIU decoder definitions and a
validated update-first launcher. Machine-specific server profiles remain local
and are never published.

## Layout

- `wius/`: shared WIU decoder definitions.
- `manifest.json`: version, expected counts, and SHA-256 for every distributed
  configuration file.
- `scripts/Start-ITCMon-With-Update.ps1`: validates and applies the WIUs before
  launching ITCMon.

The wrapper refuses to update while `itcmon.exe` is running because ITCMon
rewrites configuration from memory when it exits. It validates every published
file, preserves the existing machine-local `itcmon.json`, and keeps a
timestamped local backup before replacing the WIU directory.

The repository contains no credentials, private keys, access tokens, raw RF
captures, decoded event history, or internal receiver addresses.

## Launch

From the ITCMon installation directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Start-ITCMon-With-Update.ps1
```

If Git is installed, the wrapper performs a fast-forward-only pull into the
per-user cache. If Git is unavailable, it downloads the selected GitHub branch
archive over HTTPS. A failed update or validation stops the launch; stale or
partially downloaded configuration is never applied.

For an offline bootstrap, `-SourceRoot <path>` applies a previously extracted
copy of this repository without contacting GitHub. Normal launches should omit
that option so every start checks the canonical repository first.
