[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\ITCMon-v0.9'),

    [string]$TruckHost = 'telemetry-node.lan',

    [string]$RailfanHost = 'railfan-01',

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
$currentStage = 'initial validation'

function Write-InstallStage {
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Description
    )

    $script:currentStage = "stage $Number of 7: $Description"
    Write-Host "[stage $Number/7] $Description"
}

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

    $downloadStarted = [Diagnostics.Stopwatch]::StartNew()
    $lastLength = -1L
    $lastGrowthSeconds = 0

    function Wait-DownloadJob {
        param(
            [Parameter(Mandatory)]$Job,
            [string]$HeartbeatDescription = $Description
        )

        $nextHeartbeatSeconds = 10
        while ($Job.State -in @('NotStarted', 'Running')) {
            Wait-Job -Job $Job -Timeout 2 | Out-Null
            if ($Job.State -notin @('NotStarted', 'Running')) {
                break
            }
            $elapsedSeconds = [int][Math]::Floor($downloadStarted.Elapsed.TotalSeconds)
            if ($elapsedSeconds -lt $nextHeartbeatSeconds) {
                continue
            }
            $length = if (Test-Path -LiteralPath $Destination -PathType Leaf) {
                (Get-Item -LiteralPath $Destination).Length
            } else {
                0L
            }
            if ($length -ne $lastLength) {
                $lastLength = $length
                $lastGrowthSeconds = $elapsedSeconds
            }
            $sizeText = if ($length -lt 1MB) {
                '{0:N1} KiB' -f ($length / 1KB)
            } else {
                '{0:N1} MiB' -f ($length / 1MB)
            }
            $quietSeconds = $elapsedSeconds - $lastGrowthSeconds
            $growthText = if ($quietSeconds -ge 30) {
                "; no file growth for ${quietSeconds}s (the client may be retrying)"
            } else {
                ''
            }
            Write-Host ("[download] {0}: running {1:c}, {2} received{3}." -f `
                $HeartbeatDescription, $downloadStarted.Elapsed, $sizeText, $growthText)
            $nextHeartbeatSeconds = $elapsedSeconds + 10
        }

        try {
            return @(Receive-Job -Job $Job -Wait)
        } finally {
            Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
        }
    }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $maximumAttempts = 5
        $downloadSucceeded = $false
        $exitCode = -1
        $detail = ''
        Write-Host "[download] ${Description}: resumable curl transfer started (up to $maximumAttempts attempts)."
        for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
            $retainedLength = if (Test-Path -LiteralPath $Destination -PathType Leaf) {
                (Get-Item -LiteralPath $Destination).Length
            } else {
                0L
            }
            $retainedText = if ($retainedLength -lt 1MB) {
                '{0:N1} KiB' -f ($retainedLength / 1KB)
            } else {
                '{0:N1} MiB' -f ($retainedLength / 1MB)
            }
            if ($retainedLength -gt 0) {
                Write-Host "[download] ${Description}: attempt $attempt of $maximumAttempts resuming after $retainedText."
            } else {
                Write-Host "[download] ${Description}: attempt $attempt of $maximumAttempts starting at byte zero."
            }
            $job = Start-Job -ScriptBlock {
                param($CurlPath, $SourceUri, $OutputPath, $Resume)
                $arguments = @(
                    '--fail', '--location', '--silent', '--show-error',
                    '--connect-timeout', '20', '--max-time', '600'
                )
                if ($Resume) {
                    $arguments += @('--continue-at', '-')
                }
                $arguments += @('--output', $OutputPath, $SourceUri)
                $nativeOutput = @(& $CurlPath @arguments 2>&1)
                $nativeExitCode = $LASTEXITCODE
                [pscustomobject]@{
                    Succeeded = ($nativeExitCode -eq 0)
                    ExitCode = $nativeExitCode
                    Detail = (($nativeOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
                }
            } -ArgumentList $curl.Source, $Uri, $Destination, ($retainedLength -gt 0)
            $attemptLabel = "${Description} attempt $attempt/$maximumAttempts"
            $jobResult = @(Wait-DownloadJob -Job $job -HeartbeatDescription $attemptLabel)
            $downloadResult = @($jobResult |
                Where-Object { $_.PSObject.Properties.Name -contains 'Succeeded' } |
                Select-Object -Last 1)
            $exitCode = if ($downloadResult.Count -eq 1) {
                [int]$downloadResult[0].ExitCode
            } else {
                -1
            }
            $detail = if ($downloadResult.Count -eq 1) {
                [string]$downloadResult[0].Detail
            } else {
                'The background download worker returned no status record.'
            }
            if ($downloadResult.Count -eq 1 -and [bool]$downloadResult[0].Succeeded -and
                (Test-Path -LiteralPath $Destination -PathType Leaf) -and
                (Get-Item -LiteralPath $Destination).Length -gt 0) {
                $downloadSucceeded = $true
                break
            }

            $partialLength = if (Test-Path -LiteralPath $Destination -PathType Leaf) {
                (Get-Item -LiteralPath $Destination).Length
            } else {
                0L
            }
            if ($exitCode -eq 33 -and $partialLength -gt 0) {
                Write-Host "[download] ${Description}: server rejected resume; discarding the partial file before retry."
                Remove-Item -LiteralPath $Destination -Force
            } elseif ($partialLength -gt 0) {
                $partialText = if ($partialLength -lt 1MB) {
                    '{0:N1} KiB' -f ($partialLength / 1KB)
                } else {
                    '{0:N1} MiB' -f ($partialLength / 1MB)
                }
                Write-Host "[download] ${Description}: attempt $attempt ended with curl exit $exitCode; retaining $partialText for resume."
            } else {
                Write-Host "[download] ${Description}: attempt $attempt ended with curl exit $exitCode and no partial file."
            }
            if ($attempt -lt $maximumAttempts) {
                Start-Sleep -Seconds 2
            }
        }
        if (-not $downloadSucceeded) {
            if (Test-Path -LiteralPath $Destination) {
                Remove-Item -LiteralPath $Destination -Force
            }
            throw "${Description} download failed after $maximumAttempts attempts from $Uri (last curl exit $exitCode).$([Environment]::NewLine)$detail"
        }
    } else {
        $lastError = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            Write-Host "[download] ${Description}: Invoke-WebRequest attempt $attempt of 3 started (10-minute timeout)."
            $downloadStarted.Restart()
            $lastLength = -1L
            $lastGrowthSeconds = 0
            $job = Start-Job -ScriptBlock {
                param($SourceUri, $OutputPath)
                $ErrorActionPreference = 'Stop'
                try {
                    Invoke-WebRequest -UseBasicParsing -Uri $SourceUri -OutFile $OutputPath -TimeoutSec 600
                    [pscustomobject]@{ Succeeded = $true; ExitCode = 0; Detail = '' }
                } catch {
                    [pscustomobject]@{ Succeeded = $false; ExitCode = 1; Detail = $_.Exception.Message }
                }
            } -ArgumentList $Uri, $Destination
            $jobResult = @(Wait-DownloadJob -Job $job `
                -HeartbeatDescription "${Description} Invoke-WebRequest attempt $attempt/3")
            $downloadResult = @($jobResult | Where-Object { $_.PSObject.Properties.Name -contains 'Succeeded' } |
                Select-Object -Last 1)
            if ($downloadResult.Count -eq 1 -and [bool]$downloadResult[0].Succeeded -and
                (Test-Path -LiteralPath $Destination -PathType Leaf) -and
                (Get-Item -LiteralPath $Destination).Length -gt 0) {
                $lastError = $null
                break
            } else {
                $lastError = if ($downloadResult.Count -eq 1) {
                    [string]$downloadResult[0].Detail
                } else {
                    'The background download worker returned no status record.'
                }
                if (Test-Path -LiteralPath $Destination) {
                    Remove-Item -LiteralPath $Destination -Force
                }
                if ($attempt -lt 3) {
                    Write-Host "[download] ${Description}: Invoke-WebRequest cannot resume this partial file; retry will restart at byte zero."
                    Start-Sleep -Seconds (3 * $attempt)
                }
            }
        }
        if ($lastError) {
            throw "${Description} download failed after 3 attempts from $Uri. $lastError"
        }
    }

    $length = (Get-Item -LiteralPath $Destination).Length
    if ($length -lt 1MB) {
        Write-Host ("[download] {0}: completed in {1:c}; downloaded {2:N1} KiB." -f `
            $Description, $downloadStarted.Elapsed, ($length / 1KB))
    } else {
        Write-Host ("[download] {0}: completed in {1:c}; downloaded {2:N1} MiB." -f `
            $Description, $downloadStarted.Elapsed, ($length / 1MB))
    }
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
Write-Host ("[install] ITCMon truck client provisioning started at {0}." -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
try {
    Write-InstallStage -Number 1 -Description 'Acquire and validate the truck configuration catalog.'
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

    Write-InstallStage -Number 2 -Description "Acquire and validate ITCMon $releaseVersion."
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

    Write-InstallStage -Number 3 -Description "Acquire and validate ITCWatch $itcWatchVersion."
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

    $clientScriptNames = @(
        'Start-ITCMon-With-Update.ps1',
        'Start-ITCMon-With-Update.cmd',
        'Launch-ITCM-Truck-Client.ps1',
        'Start ITCMon - Truck.cmd',
        'Start ITCWatch - Truck.cmd',
        'Diagnose ITCM Truck Client.cmd'
    )
    $clientScriptSources = @($clientScriptNames | ForEach-Object {
        Join-Path $configurationRoot "scripts\$_"
    })
    foreach ($required in @($clientScriptSources + (Join-Path $configurationRoot 'manifest.json'))) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "The configuration package is incomplete: $required"
        }
    }

    Write-InstallStage -Number 4 -Description 'Install application files and preserve prior local data.'
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

    foreach ($name in $clientScriptNames) {
        Copy-Item -LiteralPath (Join-Path $configurationRoot "scripts\$name") `
            -Destination (Join-Path $installFull $name) -Force
    }
    $updaterInstalled = Join-Path $installFull 'Start-ITCMon-With-Update.ps1'
    $launcherInstalled = Join-Path $installFull 'Launch-ITCM-Truck-Client.ps1'

    $profileEntry = @($manifest.profiles | Where-Object name -eq $profileName)
    if ($profileEntry.Count -ne 1) {
        throw "Configuration manifest has no unique '$profileName' profile."
    }
    $profileSource = Join-Path $configurationRoot ([string]$profileEntry[0].path)
    $profileSpec = Read-JsonFile -Path $profileSource
    $expectedServerCount = [int]$profileSpec.expected_server_count
    if ($expectedServerCount -le 0 -or $expectedServerCount -ne [int]$profileEntry[0].server_count) {
        throw 'Truck-client profile and manifest disagree on expected server count.'
    }
    $profilePath = Join-Path $installFull 'truck-client-profile.json'
    Copy-Item -LiteralPath $profileSource -Destination $profilePath -Force
    $profileHash = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    if ($profileHash -ne ([string]$profileEntry[0].sha256).ToUpperInvariant()) {
        throw "Truck-client profile failed manifest acceptance: $profileHash"
    }
    Write-InstallStage -Number 5 -Description 'Apply both truck receiver endpoints, local ITCWatch endpoint, WIUs, railroad data, and automatic updater.'
    & $updaterInstalled -InstallRoot $installFull -SourceRoot $configurationRoot `
        -ProfileName $profileName -ServerHostOverride $TruckHost `
        -UpdateApplications -ITCMonArchivePath $releaseArchive `
        -ITCWatchExecutablePath $itcWatchDownload -NoLaunch

    Write-InstallStage -Number 6 -Description 'Create the ITCMon and ITCWatch truck launchers and desktop shortcuts.'
    $truckCommand = Join-Path $installFull 'Start ITCMon - Truck.cmd'
    $itcWatchCommand = Join-Path $installFull 'Start ITCWatch - Truck.cmd'
    $diagnosticCommand = Join-Path $installFull 'Diagnose ITCM Truck Client.cmd'
    foreach ($requiredLauncher in @($launcherInstalled, $truckCommand, $itcWatchCommand, $diagnosticCommand)) {
        if (-not (Test-Path -LiteralPath $requiredLauncher -PathType Leaf)) {
            throw "Installed launcher is missing: $requiredLauncher"
        }
    }

    $installedProfile = Read-JsonFile -Path (Join-Path $installFull 'itcmon.json')
    $installedServers = @($installedProfile.servers)
    $installedHosts = @($installedServers.ip | Sort-Object -Unique)
    $telemetryServers = @($installedServers | Where-Object {
        [string]::Equals([string]$_.ip, $TruckHost, [StringComparison]::OrdinalIgnoreCase)
    })
    $railfanServers = @($installedServers | Where-Object {
        [string]::Equals([string]$_.ip, $RailfanHost, [StringComparison]::OrdinalIgnoreCase)
    })
    $actualHosts = @($installedHosts | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object)
    $expectedHosts = @($TruckHost.ToLowerInvariant(), $RailfanHost.ToLowerInvariant()) | Sort-Object
    $duplicateEndpoints = @($installedServers | Group-Object { "$($_.ip):$($_.port)" } | Where-Object Count -ne 1)
    if ($installedServers.Count -ne $expectedServerCount -or
        @($installedServers | Where-Object enabled).Count -ne $expectedServerCount -or
        ($actualHosts -join '|') -ne ($expectedHosts -join '|') -or
        $telemetryServers.Count -eq 0 -or
        $railfanServers.Count -eq 0 -or
        $duplicateEndpoints.Count -ne 0) {
        throw 'Installed truck-client server profile failed acceptance.'
    }

    $itcWatchConfigPath = Join-Path $env:APPDATA 'itcmon-viewer\viewer-config.json'
    if (-not (Test-Path -LiteralPath $itcWatchConfigPath -PathType Leaf)) {
        throw "ITCWatch viewer configuration was not created: $itcWatchConfigPath"
    }
    $itcWatchViewer = Read-JsonFile -Path $itcWatchConfigPath
    $itcWatchServers = @($itcWatchViewer.servers)
    if ($itcWatchServers.Count -ne 1 -or
        [string]$itcWatchServers[0].host -ne '127.0.0.1' -or
        [int]$itcWatchServers[0].port -ne 18001 -or
        -not [bool]$itcWatchServers[0].enabled) {
        throw 'ITCWatch viewer configuration must contain only the enabled local ITCMon endpoint 127.0.0.1:18001.'
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
    $diagnosticDesktopShortcut = $null
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
            $shortcut.TargetPath = $env:ComSpec
            $shortcut.Arguments = '/d /c ""{0}""' -f $truckCommand
            $shortcut.WorkingDirectory = $installFull
            $shortcut.IconLocation = (Join-Path $installFull 'itcmon.exe')
            $shortcut.Description = 'Start ITCMon with truck configuration, automatic updates, and persistent diagnostics.'
            $shortcut.Save()

            $itcWatchDesktopShortcut = Join-Path $desktop 'ITCWatch - Truck.lnk'
            $itcWatchShortcut = $shell.CreateShortcut($itcWatchDesktopShortcut)
            $itcWatchShortcut.TargetPath = $env:ComSpec
            $itcWatchShortcut.Arguments = '/d /c ""{0}""' -f $itcWatchCommand
            $itcWatchShortcut.WorkingDirectory = $installFull
            $itcWatchShortcut.IconLocation = $itcWatchInstalled
            $itcWatchShortcut.Description = 'Start ITCWatch with the truck ITCMon stack and persistent diagnostics.'
            $itcWatchShortcut.Save()

            $diagnosticDesktopShortcut = Join-Path $desktop 'Diagnose ITCM Truck Client.lnk'
            $diagnosticShortcut = $shell.CreateShortcut($diagnosticDesktopShortcut)
            $diagnosticShortcut.TargetPath = $env:ComSpec
            $diagnosticShortcut.Arguments = '/d /c ""{0}""' -f $diagnosticCommand
            $diagnosticShortcut.WorkingDirectory = $installFull
            $diagnosticShortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,23"
            $diagnosticShortcut.Description = 'Validate the truck client and show the persistent log and status paths.'
            $diagnosticShortcut.Save()

            foreach ($shortcutCheck in @(
                [pscustomobject]@{ Path = $desktopShortcut; Command = $truckCommand },
                [pscustomobject]@{ Path = $itcWatchDesktopShortcut; Command = $itcWatchCommand },
                [pscustomobject]@{ Path = $diagnosticDesktopShortcut; Command = $diagnosticCommand }
            )) {
                $savedShortcut = $shell.CreateShortcut($shortcutCheck.Path)
                $expectedArguments = '/d /c ""{0}""' -f $shortcutCheck.Command
                if (-not [string]::Equals($savedShortcut.TargetPath, $env:ComSpec, [StringComparison]::OrdinalIgnoreCase) -or
                    $savedShortcut.Arguments -ne $expectedArguments -or
                    -not [string]::Equals($savedShortcut.WorkingDirectory, $installFull, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Desktop shortcut failed acceptance: $($shortcutCheck.Path)"
                }
            }
        }
    }

    Write-InstallStage -Number 7 -Description 'Run final acceptance checks and record installation status.'
    $connectivity = [ordered]@{
        local_zjpub_18001 = Test-TcpEndpoint -HostName '127.0.0.1' -Port 18001
        telemetry_host = $TruckHost
        telemetry_fr_18101 = Test-TcpEndpoint -HostName $TruckHost -Port 18101
        telemetry_hr_20101 = Test-TcpEndpoint -HostName $TruckHost -Port 20101
        railfan_host = $RailfanHost
        railfan_fr_18077 = Test-TcpEndpoint -HostName $RailfanHost -Port 18077
        railfan_hr_20077 = Test-TcpEndpoint -HostName $RailfanHost -Port 20077
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
        server_hosts = @($TruckHost, $RailfanHost)
        servers = $installedServers.Count
        telemetry_servers = $telemetryServers.Count
        railfan_servers = $railfanServers.Count
        itcwatch_endpoint = '127.0.0.1:18001'
        itcwatch_config = $itcWatchConfigPath
        wius = $wiuIDs.Count
        rrdata_sha256 = $installedRRDataHash
        desktop_shortcut = $desktopShortcut
        itcwatch_desktop_shortcut = $itcWatchDesktopShortcut
        diagnostic_desktop_shortcut = $diagnosticDesktopShortcut
        launch_log_root = (Join-Path $env:LOCALAPPDATA 'ITCMon\Logs')
        launch_status = (Join-Path $env:LOCALAPPDATA 'ITCMon\last-launch-status.json')
        connectivity = $connectivity
    }
    [IO.File]::WriteAllText(
        (Join-Path $installFull 'truck-client-install.json'),
        ($result | ConvertTo-Json -Depth 5) + "`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $success = $true
    $result | Format-List
    Write-Host ("[complete] Provisioning finished successfully at {0}." -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))

    if (-not $NoLaunch) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcherInstalled `
            -InstallRoot $installFull -ProfileName $profileName `
            -TruckHost $TruckHost -RailfanHost $RailfanHost -LaunchTarget ITCMon -NoUpdate
        if ($LASTEXITCODE -ne 0) {
            throw "Initial ITCMon launch failed with exit code $LASTEXITCODE."
        }
    }
} catch {
    Write-Host "[failed] Installer stopped during $currentStage" -ForegroundColor Red
    Write-Host "[failed] $($_.Exception.Message)" -ForegroundColor Red
    throw
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
