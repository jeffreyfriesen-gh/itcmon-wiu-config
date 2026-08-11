[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\ITCMon-v0.9'),

    [string]$TruckHost = 'telemetry-node.lan',

    [string]$ReleaseArchivePath,

    [string]$ITCWatchExecutablePath,

    [string]$ConfigurationSourceRoot,

    [string]$DesktopPath,

    [switch]$NoDesktopShortcut,

    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
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

function Save-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Description
    )

    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        Write-Host "${Description}: downloading with retry support (maximum 10 minutes)..."
        $arguments = @(
            '--fail', '--location', '--silent', '--show-error',
            '--connect-timeout', '20', '--max-time', '600',
            '--retry', '4', '--retry-delay', '2', '--retry-connrefused',
            '--output', $Destination, $Uri
        )
        $previousErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& $curl.Source @arguments 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorAction
        }
        if ($exitCode -ne 0 -or
            -not (Test-Path -LiteralPath $Destination -PathType Leaf) -or
            (Get-Item -LiteralPath $Destination).Length -le 0) {
            if (Test-Path -LiteralPath $Destination) {
                Remove-Item -LiteralPath $Destination -Force
            }
            $detail = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
            throw "${Description} download failed from $Uri (curl exit $exitCode).$([Environment]::NewLine)$detail"
        }
    } else {
        $lastError = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            Write-Host "${Description}: download attempt $attempt of 3 (10-minute timeout)..."
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination -TimeoutSec 600
                if ((Get-Item -LiteralPath $Destination).Length -le 0) {
                    throw 'The server returned an empty file.'
                }
                $lastError = $null
                break
            } catch {
                $lastError = $_
                if (Test-Path -LiteralPath $Destination) {
                    Remove-Item -LiteralPath $Destination -Force
                }
                if ($attempt -lt 3) {
                    Start-Sleep -Seconds (3 * $attempt)
                }
            }
        }
        if ($lastError) {
            throw "${Description} download failed after 3 attempts from $Uri. $($lastError.Exception.Message)"
        }
    }

    $length = (Get-Item -LiteralPath $Destination).Length
    Write-Host ("{0}: downloaded {1:N1} MiB." -f $Description, ($length / 1MB))
}

function Get-ApplicationEntry {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$PackageType,
        [Parameter(Mandatory)][string]$Executable
    )

    $match = @($Manifest.applications | Where-Object name -eq $Name)
    if ($match.Count -ne 1) {
        throw "Configuration manifest has no unique '$Name' application entry."
    }
    $entry = $match[0]
    if ([string]$entry.package_type -ne $PackageType -or [string]$entry.executable -ne $Executable) {
        throw "Application '$Name' has an unsupported package definition."
    }
    foreach ($field in @('version', 'url', 'sha256', 'executable_sha256')) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.$field)) {
            throw "Application '$Name' has no $field value."
        }
    }
    if ([string]$entry.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        [string]$entry.executable_sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "Application '$Name' has an invalid SHA-256 value."
    }
    $uri = [Uri]([string]$entry.url)
    if ($uri.Scheme -ne 'https' -or
        $uri.Host -notin @('github.com', 'raw.githubusercontent.com') -or
        -not $uri.AbsolutePath.StartsWith('/katsojuna/', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Application '$Name' does not use an allowed official katsojuna GitHub URL."
    }
    return $entry
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
    if ([string]::IsNullOrWhiteSpace($ConfigurationSourceRoot)) {
        Save-RemoteFile -Uri $configurationUrl -Destination $configurationArchive `
            -Description 'Truck configuration package'
        Expand-Archive -LiteralPath $configurationArchive -DestinationPath $configurationExtract
        $configurationRoots = @(Get-ChildItem -LiteralPath $configurationExtract -Directory)
        if ($configurationRoots.Count -ne 1) {
            throw "The configuration archive contained $($configurationRoots.Count) roots; expected one."
        }
        $configurationRoot = $configurationRoots[0].FullName
    } else {
        $configurationRoot = (Resolve-Path -LiteralPath $ConfigurationSourceRoot).Path
    }
    $manifest = Read-JsonFile -Path (Join-Path $configurationRoot 'manifest.json')
    $itcmonApplication = Get-ApplicationEntry -Manifest $manifest -Name 'itcmon' `
        -PackageType 'zip' -Executable 'itcmon.exe'
    $itcWatchApplication = Get-ApplicationEntry -Manifest $manifest -Name 'itcwatch' `
        -PackageType 'file' -Executable 'itcwatch.exe'
    $releaseVersion = [string]$itcmonApplication.version
    $releaseArchiveUrl = [string]$itcmonApplication.url
    $releaseArchiveSHA256 = ([string]$itcmonApplication.sha256).ToUpperInvariant()
    $releaseITCMonSHA256 = ([string]$itcmonApplication.executable_sha256).ToUpperInvariant()
    $itcWatchVersion = [string]$itcWatchApplication.version
    $itcWatchUrl = [string]$itcWatchApplication.url
    $itcWatchSHA256 = ([string]$itcWatchApplication.executable_sha256).ToUpperInvariant()

    if ([string]::IsNullOrWhiteSpace($ReleaseArchivePath)) {
        Save-RemoteFile -Uri $releaseArchiveUrl -Destination $releaseArchive `
            -Description "ITCMon $releaseVersion package"
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
        Save-RemoteFile -Uri $itcWatchUrl -Destination $itcWatchDownload `
            -Description "ITCWatch $itcWatchVersion package"
    } else {
        Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ITCWatchExecutablePath).Path -Destination $itcWatchDownload
    }
    $itcWatchDownloadHash = (Get-FileHash -LiteralPath $itcWatchDownload -Algorithm SHA256).Hash
    if ($itcWatchDownloadHash -ne $itcWatchSHA256) {
        throw "Official ITCWatch $itcWatchVersion executable failed SHA-256 validation: $itcWatchDownloadHash"
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
        foreach ($name in @('packets.hex', 'config-backups', 'application-backups')) {
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
        -ProfileName $profileName -ServerHostOverride $TruckHost `
        -UpdateApplications -ITCMonArchivePath $releaseArchive `
        -ITCWatchExecutablePath $itcWatchDownload -NoLaunch

    $truckCommand = Join-Path $installFull 'Start ITCMon - Truck.cmd'
    $truckCommandText = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-ITCMon-With-Update.ps1" -InstallRoot "%~dp0" -ProfileName "$profileName" -ServerHostOverride "$TruckHost" -UpdateApplications -LaunchTarget ITCMon %*
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-ITCMon-With-Update.ps1" -InstallRoot "%~dp0" -ProfileName "$profileName" -ServerHostOverride "$TruckHost" -UpdateApplications -LaunchTarget ITCWatch
if errorlevel 1 goto launch_failed
exit /b 0
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
        $desktop = if ([string]::IsNullOrWhiteSpace($DesktopPath)) {
            [Environment]::GetFolderPath('Desktop')
        } else {
            [IO.Path]::GetFullPath($DesktopPath)
        }
        if (-not [string]::IsNullOrWhiteSpace($desktop)) {
            New-Item -ItemType Directory -Path $desktop -Force | Out-Null
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
