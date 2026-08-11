[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\ITCMon-v0.9'),

    [string]$TruckHost = 'telemetry-node.lan',

    [string]$ReleaseArchivePath,

    [string]$ITCWatchExecutablePath,

    [string]$ConfigurationSourceRoot,

    [switch]$NoDesktopShortcut,

    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$releaseVersion = 'v0.9'
$releaseArchiveUrl = 'https://raw.githubusercontent.com/katsojuna/itcmon/v0.9/windows/itcmon-v09.zip'
$releaseArchiveSHA256 = '850AAFF5EB55987347FCEE870B57F972B62AD37C40FCA868014B45DBAD1557DD'
$releaseITCMonSHA256 = 'FE9EEC2D239ED42B74FB50AEAD1DD99EFF837DA7631CB2F0D5A5EFA363422241'
$itcWatchVersion = 'v0.4.0'
$itcWatchUrl = 'https://github.com/katsojuna/itcwatch/releases/download/v0.4.0/ITC.Watch.0.4.0.exe'
$itcWatchSHA256 = '11F0DDA9E1B61DE85760FFB3D5AC1F9CA05FC263F468341FA66F64A256409CF5'
$configurationUrl = 'https://github.com/jeffreyfriesen-gh/itcmon-wiu-config/archive/refs/heads/main.zip'
$profileName = 'truck-client'
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$workRoot = Join-Path $env:TEMP "itcmon-truck-client-$PID-$stamp"
$releaseArchive = "$workRoot-release.zip"
$itcWatchDownload = "$workRoot-itcwatch.exe"
$configurationArchive = "$workRoot-config.zip"
$packageRoot = Join-Path $workRoot 'package'
$configurationExtract = Join-Path $workRoot 'configuration'
$installFull = [IO.Path]::GetFullPath($InstallRoot).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)
$installParent = Split-Path -Parent $installFull
$backupRoot = $null
$previousMoved = $false
$newInstalled = $false
$success = $false

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF) | ConvertFrom-Json
}

function Test-TcpEndpoint {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMilliseconds = 800
    )

    $client = New-Object Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }
        $client.EndConnect($pending)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

if ($TruckHost -notmatch '^[A-Za-z0-9.-]+$') {
    throw 'TruckHost must be an IPv4 address or DNS hostname containing only letters, digits, dots, and hyphens.'
}
if ([string]::IsNullOrWhiteSpace($installParent) -or $installFull -eq [IO.Path]::GetPathRoot($installFull)) {
    throw "Unsafe installation root: $installFull"
}
if ($installFull.StartsWith(
    [IO.Path]::GetFullPath($env:windir).TrimEnd('\') + '\',
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'Refusing to install ITCMon under the Windows system directory.'
}
if (@(Get-Process -Name itcmon, itcwatch -ErrorAction SilentlyContinue).Count -ne 0) {
    throw 'ITCMon or ITCWatch is running. Close both before provisioning or updating the client.'
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
try {
    if ([string]::IsNullOrWhiteSpace($ReleaseArchivePath)) {
        Invoke-WebRequest -UseBasicParsing -Uri $releaseArchiveUrl -OutFile $releaseArchive
    } else {
        Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ReleaseArchivePath).Path -Destination $releaseArchive
    }
    $releaseHash = (Get-FileHash -LiteralPath $releaseArchive -Algorithm SHA256).Hash
    if ($releaseHash -ne $releaseArchiveSHA256) {
        throw "Official ITCMon $releaseVersion archive failed SHA-256 validation: $releaseHash"
    }
    Expand-Archive -LiteralPath $releaseArchive -DestinationPath $packageRoot
    $releasedExecutable = Join-Path $packageRoot 'itcmon.exe'
    if ((Get-FileHash -LiteralPath $releasedExecutable -Algorithm SHA256).Hash -ne $releaseITCMonSHA256) {
        throw "Official ITCMon $releaseVersion executable failed SHA-256 validation."
    }

    if ([string]::IsNullOrWhiteSpace($ITCWatchExecutablePath)) {
        Invoke-WebRequest -UseBasicParsing -Uri $itcWatchUrl -OutFile $itcWatchDownload
    } else {
        Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ITCWatchExecutablePath).Path -Destination $itcWatchDownload
    }
    $itcWatchDownloadHash = (Get-FileHash -LiteralPath $itcWatchDownload -Algorithm SHA256).Hash
    if ($itcWatchDownloadHash -ne $itcWatchSHA256) {
        throw "Official ITCWatch $itcWatchVersion executable failed SHA-256 validation: $itcWatchDownloadHash"
    }

    if ([string]::IsNullOrWhiteSpace($ConfigurationSourceRoot)) {
        Invoke-WebRequest -UseBasicParsing -Uri $configurationUrl -OutFile $configurationArchive
        Expand-Archive -LiteralPath $configurationArchive -DestinationPath $configurationExtract
        $configurationRoots = @(Get-ChildItem -LiteralPath $configurationExtract -Directory)
        if ($configurationRoots.Count -ne 1) {
            throw "The configuration archive contained $($configurationRoots.Count) roots; expected one."
        }
        $configurationRoot = $configurationRoots[0].FullName
    } else {
        $configurationRoot = (Resolve-Path -LiteralPath $ConfigurationSourceRoot).Path
    }
    $updaterSource = Join-Path $configurationRoot 'scripts\Start-ITCMon-With-Update.ps1'
    $commandSource = Join-Path $configurationRoot 'scripts\Start-ITCMon-With-Update.cmd'
    foreach ($required in @($updaterSource, $commandSource, (Join-Path $configurationRoot 'manifest.json'))) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "The configuration package is incomplete: $required"
        }
    }

    New-Item -ItemType Directory -Path $installParent -Force | Out-Null
    if (Test-Path -LiteralPath $installFull) {
        $backupParent = Join-Path $installParent 'ITCMon-backups'
        New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
        $backupRoot = Join-Path $backupParent "ITCMon-before-$releaseVersion-$stamp"
        if (Test-Path -LiteralPath $backupRoot) {
            throw "Refusing to replace an existing backup: $backupRoot"
        }
        Move-Item -LiteralPath $installFull -Destination $backupRoot
        $previousMoved = $true
    }
    Move-Item -LiteralPath $packageRoot -Destination $installFull
    $newInstalled = $true

    $itcWatchInstalled = Join-Path $installFull 'itcwatch.exe'
    Copy-Item -LiteralPath $itcWatchDownload -Destination $itcWatchInstalled -Force
    $itcWatchInstalledHash = (Get-FileHash -LiteralPath $itcWatchInstalled -Algorithm SHA256).Hash
    if ($itcWatchInstalledHash -ne $itcWatchSHA256) {
        throw 'Installed ITCWatch executable failed SHA-256 acceptance.'
    }

    if ($backupRoot) {
        foreach ($name in @('packets.hex', 'config-backups')) {
            $preserved = Join-Path $backupRoot $name
            if (Test-Path -LiteralPath $preserved) {
                Copy-Item -LiteralPath $preserved -Destination (Join-Path $installFull $name) -Recurse -Force
            }
        }
    }

    $updaterInstalled = Join-Path $installFull 'Start-ITCMon-With-Update.ps1'
    $commandInstalled = Join-Path $installFull 'Start-ITCMon-With-Update.cmd'
    Copy-Item -LiteralPath $updaterSource -Destination $updaterInstalled -Force
    Copy-Item -LiteralPath $commandSource -Destination $commandInstalled -Force

    $manifest = Read-JsonFile -Path (Join-Path $configurationRoot 'manifest.json')
    $profileEntry = @($manifest.profiles | Where-Object name -eq $profileName)
    if ($profileEntry.Count -ne 1) {
        throw "Configuration manifest has no unique '$profileName' profile."
    }
    $profileSource = Join-Path $configurationRoot ([string]$profileEntry[0].path)
    $profilePath = Join-Path $installFull 'truck-client-profile.json'
    Copy-Item -LiteralPath $profileSource -Destination $profilePath -Force
    $profileHash = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    if ($profileHash -ne ([string]$profileEntry[0].sha256).ToUpperInvariant()) {
        throw "Truck-client profile failed manifest acceptance: $profileHash"
    }
    & $updaterInstalled -InstallRoot $installFull -SourceRoot $configurationRoot `
        -ServerProfilePath $profilePath `
        -ExpectedServerProfileSHA256 $profileHash `
        -ServerHostOverride $TruckHost -NoLaunch

    $truckCommand = Join-Path $installFull 'Start ITCMon - Truck.cmd'
    $truckCommandText = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-ITCMon-With-Update.ps1" -InstallRoot "%~dp0" -ServerProfilePath "%~dp0truck-client-profile.json" -ExpectedServerProfileSHA256 "$profileHash" -ServerHostOverride "$TruckHost" %*
"@
    [IO.File]::WriteAllText(
        $truckCommand,
        $truckCommandText.Replace("`n", "`r`n"),
        (New-Object Text.ASCIIEncoding)
    )

    $itcWatchCommand = Join-Path $installFull 'Start ITCWatch - Truck.cmd'
    $itcWatchCommandText = @"
@echo off
powershell.exe -NoProfile -Command "if (Get-Process -Name itcmon -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
if not errorlevel 1 goto launch_watch
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-ITCMon-With-Update.ps1" -InstallRoot "%~dp0" -ServerProfilePath "%~dp0truck-client-profile.json" -ExpectedServerProfileSHA256 "$profileHash" -ServerHostOverride "$TruckHost" -NoLaunch
if errorlevel 1 goto launch_failed
start "" "%~dp0itcmon.exe"
timeout /t 2 /nobreak >nul
:launch_watch
start "" "%~dp0itcwatch.exe"
exit /b 0
:launch_failed
echo ITCMon configuration update failed; ITCWatch was not started.
pause
exit /b 1
"@
    [IO.File]::WriteAllText(
        $itcWatchCommand,
        $itcWatchCommandText.Replace("`n", "`r`n"),
        (New-Object Text.ASCIIEncoding)
    )

    $installedProfile = Read-JsonFile -Path (Join-Path $installFull 'itcmon.json')
    $installedServers = @($installedProfile.servers)
    $installedHosts = @($installedServers.ip | Sort-Object -Unique)
    $installedChannels = @($installedServers.channel | Sort-Object -Unique)
    if ($installedServers.Count -ne 52 -or
        @($installedServers | Where-Object enabled).Count -ne 52 -or
        $installedHosts.Count -ne 1 -or $installedHosts[0] -ne $TruckHost -or
        $installedChannels.Count -ne 26) {
        throw 'Installed truck-client server profile failed acceptance.'
    }

    $rrdataEntry = @($manifest.files | Where-Object path -eq ([string]$manifest.rrdata_path))
    if ($rrdataEntry.Count -ne 1) {
        throw 'Configuration manifest has no unique rrdata entry.'
    }
    $installedRRDataHash = (Get-FileHash -LiteralPath (Join-Path $installFull 'rrdata.json') -Algorithm SHA256).Hash
    if ($installedRRDataHash -ne ([string]$rrdataEntry[0].sha256).ToUpperInvariant()) {
        throw 'Installed rrdata.json failed manifest acceptance.'
    }

    $wiuIDs = New-Object 'System.Collections.Generic.HashSet[string]'
    Get-ChildItem -LiteralPath (Join-Path $installFull 'wius') -Filter '*.json' -File -Recurse |
        ForEach-Object {
            $wiu = Read-JsonFile -Path $_.FullName
            foreach ($property in @($wiu.waysides.PSObject.Properties)) {
                if (-not $wiuIDs.Add([string]$property.Name)) {
                    throw "Duplicate installed WIU ID: $($property.Name)"
                }
            }
        }
    if ($wiuIDs.Count -ne [int]$manifest.wiu_count) {
        throw "Installed WIU count $($wiuIDs.Count) does not match manifest count $($manifest.wiu_count)."
    }

    $desktopShortcut = $null
    $itcWatchDesktopShortcut = $null
    if (-not $NoDesktopShortcut) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        if (-not [string]::IsNullOrWhiteSpace($desktop)) {
            $desktopShortcut = Join-Path $desktop 'ITCMon - Truck.lnk'
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($desktopShortcut)
            $shortcut.TargetPath = $truckCommand
            $shortcut.WorkingDirectory = $installFull
            $shortcut.IconLocation = (Join-Path $installFull 'itcmon.exe')
            $shortcut.Save()

            $itcWatchDesktopShortcut = Join-Path $desktop 'ITCWatch - Truck.lnk'
            $itcWatchShortcut = $shell.CreateShortcut($itcWatchDesktopShortcut)
            $itcWatchShortcut.TargetPath = $itcWatchCommand
            $itcWatchShortcut.WorkingDirectory = $installFull
            $itcWatchShortcut.IconLocation = $itcWatchInstalled
            $itcWatchShortcut.Save()
        }
    }

    $connectivity = [ordered]@{
        host = $TruckHost
        fr_18101 = Test-TcpEndpoint -HostName $TruckHost -Port 18101
        hr_20101 = Test-TcpEndpoint -HostName $TruckHost -Port 20101
    }
    $result = [pscustomobject][ordered]@{
        schema = 'itcmon.truck-client.install.v1'
        installed_at = (Get-Date).ToUniversalTime().ToString('o')
        itcmon_release = $releaseVersion
        itcwatch_release = $itcWatchVersion
        itcwatch_sha256 = $itcWatchInstalledHash
        itcwatch_executable = $itcWatchInstalled
        install_root = $installFull
        rollback_root = $backupRoot
        server_profile = $profileName
        server_profile_sha256 = $profileHash
        server_host = $TruckHost
        servers = $installedServers.Count
        wius = $wiuIDs.Count
        rrdata_sha256 = $installedRRDataHash
        desktop_shortcut = $desktopShortcut
        itcwatch_desktop_shortcut = $itcWatchDesktopShortcut
        connectivity = $connectivity
    }
    [IO.File]::WriteAllText(
        (Join-Path $installFull 'truck-client-install.json'),
        ($result | ConvertTo-Json -Depth 5) + "`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $success = $true
    $result | Format-List

    if (-not $NoLaunch) {
        Start-Process -FilePath (Join-Path $installFull 'itcmon.exe') -WorkingDirectory $installFull
    }
} finally {
    if (-not $success -and $newInstalled) {
        if (Test-Path -LiteralPath $installFull) {
            Remove-Item -LiteralPath $installFull -Recurse -Force
        }
        if ($previousMoved -and $backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
            Move-Item -LiteralPath $backupRoot -Destination $installFull
        }
    }
    foreach ($temporary in @($releaseArchive, $itcWatchDownload, $configurationArchive, $workRoot)) {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Recurse -Force
        }
    }
}
