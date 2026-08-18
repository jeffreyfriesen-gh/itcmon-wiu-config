[CmdletBinding()]
param(
    [string]$InstallRoot = $PSScriptRoot,

    [string]$RepositoryUrl = 'https://github.com/jeffreyfriesen-gh/itcmon-wiu-config.git',

    [string]$Branch = 'main',

    [string]$CacheRoot = (Join-Path $env:LOCALAPPDATA 'ITCMon\ConfigRepository'),

    [string]$SourceRoot,

    [string]$ProfileName,

    [string]$ServerProfilePath,

    [string]$ExpectedServerProfileSHA256,

    [string]$ServerHostOverride,

    [switch]$UpdateApplications,

    [string]$ITCMonArchivePath,

    [string]$ITCWatchExecutablePath,

    [string]$ATCSMonArchivePath,

    [string]$ShortcutIconPath,

    [ValidateSet('ITCMon', 'ITCWatch', 'ATCSMon')]
    [string]$LaunchTarget = 'ITCMon',

    [switch]$NoDesktopShortcut,

    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$currentUpdateStage = 'initial validation'
$privateArtifactHost = 'svc-cache.lan'
$privateArtifactPort = 8080
$privateArtifactPathPrefix = '/r/8c2e6a/'

function Write-UpdateStage {
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Description
    )

    $script:currentUpdateStage = "stage $Number of 4: $Description"
    Write-Host "[update $Number/4] $Description"
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)

    $text = [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    return $text | ConvertFrom-Json
}

function Install-ITCWatchViewerConfiguration {
    param(
        [Parameter(Mandatory)][string]$BackupRoot
    )

    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        throw 'APPDATA is unavailable; ITCWatch viewer configuration cannot be installed.'
    }
    $viewerRoot = Join-Path $env:APPDATA 'itcmon-viewer'
    $viewerPath = Join-Path $viewerRoot 'viewer-config.json'
    $viewer = if (Test-Path -LiteralPath $viewerPath -PathType Leaf) {
        Copy-Item -LiteralPath $viewerPath -Destination (Join-Path $BackupRoot 'itcwatch-viewer-config.json') -Force
        Read-JsonFile -Path $viewerPath
    } else {
        [pscustomobject][ordered]@{}
    }

    $localServer = [pscustomobject][ordered]@{
        host = '127.0.0.1'
        port = 18001
        enabled = $true
    }
    if ($viewer.PSObject.Properties['servers']) {
        $viewer.servers = @($localServer)
    } else {
        $viewer | Add-Member -NotePropertyName servers -NotePropertyValue @($localServer)
    }
    foreach ($pathSetting in @(
        [pscustomobject]@{ Name = 'wiusRoot'; Value = (Join-Path $InstallRoot 'wius') },
        [pscustomobject]@{ Name = 'rrdataPath'; Value = (Join-Path $InstallRoot 'local\rrdata.json') }
    )) {
        if ($viewer.PSObject.Properties[$pathSetting.Name]) {
            $viewer.($pathSetting.Name) = $pathSetting.Value
        } else {
            $viewer | Add-Member -NotePropertyName $pathSetting.Name -NotePropertyValue $pathSetting.Value
        }
    }
    foreach ($default in @(
        [pscustomobject]@{ Name = 'maxRows'; Value = 500 },
        [pscustomobject]@{ Name = 'stopAspects'; Value = @('Stop', 'Stop!', 'Dark', 'Restrct') }
    )) {
        if (-not $viewer.PSObject.Properties[$default.Name]) {
            $viewer | Add-Member -NotePropertyName $default.Name -NotePropertyValue $default.Value
        }
    }

    New-Item -ItemType Directory -Path $viewerRoot -Force | Out-Null
    $temporary = Join-Path $viewerRoot ".viewer-config.json.$PID.tmp"
    if (Test-Path -LiteralPath $temporary) {
        throw "Refusing to replace unexpected ITCWatch staging file: $temporary"
    }
    try {
        [IO.File]::WriteAllText(
            $temporary,
            ($viewer | ConvertTo-Json -Depth 8) + "`r`n",
            (New-Object Text.UTF8Encoding($false))
        )
        Move-Item -LiteralPath $temporary -Destination $viewerPath -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }

    $installed = Read-JsonFile -Path $viewerPath
    $servers = @($installed.servers)
    if ($servers.Count -ne 1 -or [string]$servers[0].host -ne '127.0.0.1' -or
        [int]$servers[0].port -ne 18001 -or -not [bool]$servers[0].enabled -or
        [string]$installed.wiusRoot -ne (Join-Path $InstallRoot 'wius') -or
        [string]$installed.rrdataPath -ne (Join-Path $InstallRoot 'local\rrdata.json')) {
        throw 'Installed ITCWatch configuration failed local endpoint/data-path acceptance.'
    }
    return [pscustomobject]@{
        Path = $viewerPath
        SHA256 = (Get-FileHash -LiteralPath $viewerPath -Algorithm SHA256).Hash
    }
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

function ConvertFrom-ServerProfile {
    param(
        [Parameter(Mandatory)]$Profile,
        [string]$HostOverride
    )

    $sources = switch ([string]$Profile.schema) {
        'itcmon.server-profile.v1' { @($Profile) }
        'itcmon.server-profile.v2' { @($Profile.sources) }
        default { throw "Unsupported server-profile schema: $($Profile.schema)" }
    }
    if ($sources.Count -eq 0) {
        throw 'The selected server profile has no receiver sources.'
    }

    $overrideEligible = @($sources | Where-Object {
        $Profile.schema -eq 'itcmon.server-profile.v1' -or [bool]$_.allow_host_override
    })
    if (-not [string]::IsNullOrWhiteSpace($HostOverride) -and $overrideEligible.Count -ne 1) {
        throw "ServerHostOverride requires exactly one override-eligible source; found $($overrideEligible.Count)."
    }

    $servers = foreach ($source in $sources) {
        $hostName = [string]$source.host
        if (-not [string]::IsNullOrWhiteSpace($HostOverride) -and
            ($Profile.schema -eq 'itcmon.server-profile.v1' -or [bool]$source.allow_host_override)) {
            $hostName = $HostOverride.Trim()
        }
        $namePrefix = [string]$source.name_prefix
        if ([string]::IsNullOrWhiteSpace($hostName) -or [string]::IsNullOrWhiteSpace($namePrefix)) {
            throw 'A selected server-profile source has no host or name prefix.'
        }
        $channels = @(
            if ($source.PSObject.Properties['channels']) {
                @($source.channels | ForEach-Object { [int]$_ })
            }
            if ($source.PSObject.Properties['channel_ranges']) {
                foreach ($range in @($source.channel_ranges)) {
                    $first = [int]$range.first
                    $last = [int]$range.last
                    if ($first -le 0 -or $last -lt $first) {
                        throw "Server-profile source '$namePrefix' contains an invalid channel range $first-$last."
                    }
                    $first..$last
                }
            }
        )
        $rates = @($source.rates)
        if ($channels.Count -eq 0 -or @($channels | Sort-Object -Unique).Count -ne $channels.Count) {
            throw "Server-profile source '$namePrefix' has no channels or contains duplicate channels."
        }
        if ($rates.Count -eq 0) {
            throw "Server-profile source '$namePrefix' has no data-rate definitions."
        }

        foreach ($channel in $channels) {
            foreach ($rate in $rates) {
                $suffix = [string]$rate.suffix
                $portBase = [int]$rate.port_base
                if ([string]::IsNullOrWhiteSpace($suffix) -or $portBase -le 0) {
                    throw "Server-profile source '$namePrefix' contains an invalid rate definition."
                }
                [pscustomobject][ordered]@{
                    name = "$namePrefix Ch $channel $suffix"
                    ip = $hostName
                    port = $portBase + $channel
                    channel = $channel
                    enabled = $true
                }
            }
        }
    }
    $duplicateEndpoints = @($servers | Group-Object { "$($_.ip):$($_.port)" } | Where-Object Count -ne 1)
    if ($duplicateEndpoints.Count -ne 0) {
        throw 'The selected server profile generates duplicate host/port endpoints.'
    }
    $duplicateNames = @($servers | Group-Object name | Where-Object Count -ne 1)
    if ($duplicateNames.Count -ne 0) {
        throw 'The selected server profile generates duplicate display names.'
    }
    return [pscustomobject][ordered]@{ servers = @($servers) }
}

function Invoke-GitChecked {
    param(
        [Parameter(Mandatory)][string]$GitPath,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    # Native-command output is part of PowerShell's success stream. If it is
    # allowed to escape this helper, Get-RepositoryRoot returns both Git's
    # status text and the repository path, which cannot bind to a scalar
    # RepositoryRoot parameter. Capture it here and expose it only as verbose
    # diagnostics.
    $previousErrorAction = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 promotes native stderr records according to
        # ErrorActionPreference. Git writes ordinary fetch/progress text there,
        # so temporarily keep it non-terminating and judge the native exit code.
        $ErrorActionPreference = 'Continue'
        $output = @(& $GitPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if ($exitCode -ne 0) {
        $detail = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "$Description failed with exit code $exitCode.$([Environment]::NewLine)$detail"
    }
    if ($output.Count -ne 0) {
        Write-Verbose (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
    }
}

function Get-RepositoryRoot {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Ref,
        [Parameter(Mandatory)][string]$Cache
    )

    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        if (Test-Path -LiteralPath (Join-Path $Cache '.git')) {
            Invoke-GitChecked -GitPath $git.Source -Description 'GitHub configuration pull' -Arguments @(
                '-C', $Cache, 'pull', '--ff-only', 'origin', $Ref
            )
        } else {
            if (Test-Path -LiteralPath $Cache) {
                $items = @(Get-ChildItem -LiteralPath $Cache -Force)
                if ($items.Count -ne 0) {
                    throw "Configuration cache exists but is not a Git checkout: $Cache"
                }
            } else {
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Cache) -Force
            }
            Invoke-GitChecked -GitPath $git.Source -Description 'GitHub configuration clone' -Arguments @(
                'clone', '--depth', '1', '--branch', $Ref, '--single-branch', $Url, $Cache
            )
        }
        return (Resolve-Path -LiteralPath $Cache).Path
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $httpsUrl = $Url -replace '\.git$', ''
    $archiveUrl = "$httpsUrl/archive/refs/heads/$Ref.zip"
    $temporaryRoot = Join-Path $env:TEMP "itcmon-config-$PID"
    $archivePath = "$temporaryRoot.zip"
    if (Test-Path -LiteralPath $temporaryRoot) {
        throw "Refusing to replace unexpected temporary directory: $temporaryRoot"
    }
    if (Test-Path -LiteralPath $archivePath) {
        throw "Refusing to replace unexpected temporary archive: $archivePath"
    }
    Save-RemoteFile -Uri $archiveUrl -Destination $archivePath -Description 'Truck configuration package'
    Expand-Archive -LiteralPath $archivePath -DestinationPath $temporaryRoot
    $roots = @(Get-ChildItem -LiteralPath $temporaryRoot -Directory)
    if ($roots.Count -ne 1) {
        throw "GitHub archive contained $($roots.Count) roots; expected one."
    }
    return $roots[0].FullName
}

function Test-RepositoryConfiguration {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$ManifestProfileName,
        [string]$ExternalProfilePath,
        [string]$ExpectedExternalProfileSHA256,
        [string]$HostOverride
    )

    $manifestPath = Join-Path $RepositoryRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Missing manifest: $manifestPath"
    }
    $manifest = Read-JsonFile -Path $manifestPath
    if ($manifest.schema -ne 'itcmon.config.manifest.v1') {
        throw "Unsupported manifest schema: $($manifest.schema)"
    }

    $repositoryFull = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $repositoryPrefix = $repositoryFull + [IO.Path]::DirectorySeparatorChar
    $manifestPaths = @{}
    foreach ($entry in @($manifest.files)) {
        $candidate = [IO.Path]::GetFullPath(
            (Join-Path $repositoryFull ([string]$entry.path))
        )
        if (-not $candidate.StartsWith(
            $repositoryPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Manifest path leaves the repository root: $($entry.path)"
        }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Manifest file is missing: $($entry.path)"
        }
        $actual = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
        if ($actual -ne ([string]$entry.sha256).ToUpperInvariant()) {
            throw "SHA-256 mismatch for $($entry.path)."
        }
        $manifestPaths[[string]$entry.path] = $candidate
    }

    $wiuRoot = Join-Path $repositoryFull 'wius'
    $wiuIDs = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($wiuFile in @(Get-ChildItem -LiteralPath $wiuRoot -Filter '*.json' -File -Recurse)) {
        $wiuJson = Read-JsonFile -Path $wiuFile.FullName
        foreach ($property in @($wiuJson.waysides.PSObject.Properties)) {
            if (-not $wiuIDs.Add([string]$property.Name)) {
                throw "Duplicate WIU ID $($property.Name) in $($wiuFile.FullName)."
            }
            $displayName = [string]$property.Value.name
            if ([string]$property.Value.sig -eq 'UP' -and
                -not [string]::IsNullOrWhiteSpace($displayName) -and
                -not $displayName.StartsWith('UP ', [StringComparison]::Ordinal)) {
                throw "WIU $($property.Name) is a named UP wayside; prefix its display name with 'UP '."
            }
            if ($displayName -match '(?i)\bMP\s*[0-9]') {
                throw "WIU $($property.Name) embeds a milepost in its name; store it in the MP property instead."
            }
            if ($displayName -match '(?i)(?:^|[\s-])M[12](?:$|[\s-])') {
                throw "WIU $($property.Name) abbreviates a track as M1/M2; use Main 1/Main 2."
            }
            if ($displayName -match '(?i)\bCP\s+B[0-9]+' -and -not $property.Value.atcs) {
                throw "WIU $($property.Name) uses a CP designation without a confirmed ATCSMon/MCP mapping."
            }
        }
    }
    if ($wiuIDs.Count -ne [int]$manifest.wiu_count) {
        throw "WIU count $($wiuIDs.Count) does not match manifest count $($manifest.wiu_count)."
    }

    $rrdataRelative = [string]$manifest.rrdata_path
    $rrdataPath = $null
    $rrdataSHA256 = $null
    if (-not [string]::IsNullOrWhiteSpace($rrdataRelative)) {
        if (-not $manifestPaths.ContainsKey($rrdataRelative)) {
            throw 'The manifest rrdata path is not a hash-validated file.'
        }
        $rrdataPath = [string]$manifestPaths[$rrdataRelative]
        $rrdata = Read-JsonFile -Path $rrdataPath
        if (@($rrdata.mappings).Count -eq 0 -or -not $rrdata.signal_tables) {
            throw 'The published rrdata file has no railroad mappings or signal tables.'
        }
        $rrdataSHA256 = (Get-FileHash -LiteralPath $rrdataPath -Algorithm SHA256).Hash
    }

    if (-not [string]::IsNullOrWhiteSpace($ManifestProfileName) -and
        -not [string]::IsNullOrWhiteSpace($ExternalProfilePath)) {
        throw 'ProfileName and ServerProfilePath cannot be used together.'
    }

    $profileName = $null
    $profileConfig = $null
    $profilePath = $null
    $profileSHA256 = $null
    if (-not [string]::IsNullOrWhiteSpace($ExternalProfilePath)) {
        if ([string]::IsNullOrWhiteSpace($ExpectedExternalProfileSHA256)) {
            throw 'ExpectedServerProfileSHA256 is required with ServerProfilePath.'
        }
        $profilePath = (Resolve-Path -LiteralPath $ExternalProfilePath).Path
        $profileSHA256 = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
        if ($profileSHA256 -ne $ExpectedExternalProfileSHA256.ToUpperInvariant()) {
            throw "External server profile failed SHA-256 validation: $profileSHA256"
        }
        $profileSpec = Read-JsonFile -Path $profilePath
        $profileName = [string]$profileSpec.name
        if ([string]::IsNullOrWhiteSpace($profileName)) {
            throw 'The external server profile has no name.'
        }
        $profileConfig = ConvertFrom-ServerProfile -Profile $profileSpec -HostOverride $HostOverride
        $expectedProfileCount = if ($profileSpec.PSObject.Properties['expected_server_count']) {
            [int]$profileSpec.expected_server_count
        } else {
            @($profileConfig.servers).Count
        }
        if (@($profileConfig.servers).Count -ne $expectedProfileCount) {
            throw "Server profile '$profileName' generated $(@($profileConfig.servers).Count) servers; expected $expectedProfileCount."
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($ManifestProfileName)) {
        $profileEntry = @($manifest.profiles | Where-Object name -eq $ManifestProfileName)
        if ($profileEntry.Count -ne 1) {
            throw "Configuration manifest has no unique '$ManifestProfileName' profile."
        }
        $profileRelative = [string]$profileEntry[0].path
        if (-not $manifestPaths.ContainsKey($profileRelative)) {
            throw "Manifest profile '$ManifestProfileName' is not a hash-validated file."
        }
        $profilePath = [string]$manifestPaths[$profileRelative]
        $profileSHA256 = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
        if ($profileSHA256 -ne ([string]$profileEntry[0].sha256).ToUpperInvariant()) {
            throw "Manifest profile '$ManifestProfileName' failed SHA-256 validation."
        }
        $profileSpec = Read-JsonFile -Path $profilePath
        $profileName = [string]$profileSpec.name
        if ($profileName -ne $ManifestProfileName) {
            throw "Manifest profile name '$ManifestProfileName' does not match its document name '$profileName'."
        }
        $profileConfig = ConvertFrom-ServerProfile -Profile $profileSpec -HostOverride $HostOverride
        if (@($profileConfig.servers).Count -ne [int]$profileEntry[0].server_count) {
            throw "Server profile '$profileName' generated the wrong server count."
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($HostOverride)) {
        throw 'ServerHostOverride requires ServerProfilePath.'
    } elseif (-not [string]::IsNullOrWhiteSpace($ExpectedExternalProfileSHA256)) {
        throw 'ExpectedServerProfileSHA256 requires ServerProfilePath.'
    }

    $managedFiles = @()
    if ($profileSpec -and $profileSpec.PSObject.Properties['managed_files']) {
        $destinations = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($managed in @($profileSpec.managed_files)) {
            $sourceRelative = [string]$managed.source
            $destinationRelative = [string]$managed.destination
            if ([string]::IsNullOrWhiteSpace($sourceRelative) -or
                [string]::IsNullOrWhiteSpace($destinationRelative) -or
                [IO.Path]::IsPathRooted($destinationRelative)) {
                throw "Profile '$profileName' contains an invalid managed-file path."
            }
            if (-not $manifestPaths.ContainsKey($sourceRelative)) {
                throw "Profile '$profileName' managed file is not hash-validated by the manifest: $sourceRelative"
            }
            if (-not $destinations.Add($destinationRelative)) {
                throw "Profile '$profileName' repeats managed-file destination: $destinationRelative"
            }
            $managedFiles += [pscustomobject][ordered]@{
                Source = [string]$manifestPaths[$sourceRelative]
                SourceRelative = $sourceRelative
                DestinationRelative = $destinationRelative
            }
        }
    }

    return [pscustomobject]@{
        Manifest = $manifest
        ManifestPath = $manifestPath
        WIURoot = $wiuRoot
        WIUCount = $wiuIDs.Count
        RRDataPath = $rrdataPath
        RRDataSHA256 = $rrdataSHA256
        ProfileName = $profileName
        ProfileConfig = $profileConfig
        ProfilePath = $profilePath
        ProfileSHA256 = $profileSHA256
        ProfileSpec = $profileSpec
        ManagedFiles = @($managedFiles)
        ManifestPaths = $manifestPaths
    }
}

function Get-ApplicationCatalog {
    param([Parameter(Mandatory)]$Manifest)

    $entries = @($Manifest.applications)
    $catalog = @{}
    foreach ($name in @('itcmon', 'itcwatch', 'atcsmon')) {
        $match = @($entries | Where-Object name -eq $name)
        if ($match.Count -ne 1) {
            throw "Configuration manifest has no unique '$name' application entry."
        }
        $entry = $match[0]
        foreach ($field in @('version', 'package_type', 'url', 'sha256', 'executable', 'executable_sha256')) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.$field)) {
                throw "Application '$name' has no $field value."
            }
        }
        if ([string]$entry.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            [string]$entry.executable_sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "Application '$name' has an invalid SHA-256 value."
        }
        $uri = [Uri]([string]$entry.url)
        $isOfficialGitHub = $uri.Scheme -eq 'https' -and
            $uri.Host -in @('github.com', 'raw.githubusercontent.com') -and
            $uri.AbsolutePath.StartsWith('/katsojuna/', [StringComparison]::OrdinalIgnoreCase)
        $isPrivateArtifactHost = $uri.Scheme -eq 'http' -and
            $uri.Host -eq $privateArtifactHost -and
            $uri.Port -eq $privateArtifactPort -and
            $uri.AbsolutePath.StartsWith($privateArtifactPathPrefix, [StringComparison]::Ordinal)
        if (-not $isOfficialGitHub -and -not $isPrivateArtifactHost) {
            throw "Application '$name' does not use an approved release origin."
        }
        $catalog[$name] = $entry
    }
    if ([string]$catalog.itcmon.package_type -ne 'zip' -or
        [string]$catalog.itcmon.executable -ne 'itcmon.exe') {
        throw 'The ITCMon application entry must describe a ZIP containing itcmon.exe.'
    }
    if ([string]$catalog.itcwatch.package_type -ne 'file' -or
        [string]$catalog.itcwatch.executable -ne 'itcwatch.exe') {
        throw 'The ITCWatch application entry must describe the portable itcwatch.exe file.'
    }
    if ([string]$catalog.atcsmon.package_type -ne 'zip' -or
        [string]$catalog.atcsmon.executable -ne 'ATCSMon/atcsmon.exe') {
        throw 'The ATCSMon application entry must describe a ZIP containing ATCSMon/atcsmon.exe.'
    }
    return $catalog
}

function Get-ClientAssetCatalog {
    param([Parameter(Mandatory)]$Manifest)

    $match = @($Manifest.client_assets | Where-Object name -eq 'itcmon-shortcut-icon')
    if ($match.Count -ne 1) {
        throw "Configuration manifest has no unique 'itcmon-shortcut-icon' client asset."
    }
    $entry = $match[0]
    foreach ($field in @('version', 'url', 'sha256', 'destination')) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.$field)) {
            throw "ITCMon shortcut icon has no $field value."
        }
    }
    if ([string]$entry.destination -ne 'assets/itcmon-truck.ico' -or
        [string]$entry.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'ITCMon shortcut icon has an unsupported destination or SHA-256 value.'
    }
    $uri = [Uri]([string]$entry.url)
    if ($uri.Scheme -ne 'http' -or $uri.Host -ne $privateArtifactHost -or
        $uri.Port -ne $privateArtifactPort -or
        -not $uri.AbsolutePath.StartsWith($privateArtifactPathPrefix, [StringComparison]::Ordinal)) {
        throw 'ITCMon shortcut icon does not use the approved private artifact origin.'
    }
    return $entry
}

function Install-ATCSMonRuntime {
    param(
        [Parameter(Mandatory)][string]$ATCSRoot,
        [switch]$SkipRegistration
    )

    $runtimeRoot = Join-Path $ATCSRoot 'runtime'
    $registerNames = @(
        'msstdfmt.dll', 'mscomctl.ocx', 'comdlg32.ocx', 'mswinsck.ocx',
        'mscomm32.ocx', 'spin32.ocx', 'richtx32.ocx', 'msscript.ocx',
        '..\subclass.ocx'
    )
    $regsvr32 = if ([Environment]::Is64BitOperatingSystem) {
        Join-Path $env:WINDIR 'SysWOW64\regsvr32.exe'
    } else {
        Join-Path $env:WINDIR 'System32\regsvr32.exe'
    }
    foreach ($relative in $registerNames) {
        $component = [IO.Path]::GetFullPath((Join-Path $runtimeRoot $relative))
        if (-not (Test-Path -LiteralPath $component -PathType Leaf)) {
            throw "ATCSMon runtime component is missing: $component"
        }
        if (-not $SkipRegistration) {
            $process = Start-Process -FilePath $regsvr32 -ArgumentList @('/s', $component) -Wait -PassThru
            if ($process.ExitCode -ne 0) {
                throw "ATCSMon runtime registration failed for $component with exit code $($process.ExitCode). Run the updater from an elevated PowerShell window."
            }
        }
    }

    $defaultIni = Join-Path $ATCSRoot 'atcsmon.default.ini'
    $activeIni = Join-Path $ATCSRoot 'atcsmon.ini'
    if (-not (Test-Path -LiteralPath $activeIni -PathType Leaf)) {
        $iniText = [IO.File]::ReadAllText($defaultIni).Replace('__ATCS_ROOT__', $ATCSRoot)
        [IO.File]::WriteAllText($activeIni, $iniText, (New-Object Text.UTF8Encoding($false)))
    }
    foreach ($directory in @('Downloads', 'Import', 'kmz', 'Layouts', 'Logs', 'MCPs', 'Notes')) {
        New-Item -ItemType Directory -Path (Join-Path $ATCSRoot $directory) -Force | Out-Null
    }
}

function Get-TargetClientProcesses {
    param([Parameter(Mandatory)][string]$TargetRoot)

    $installFull = [IO.Path]::GetFullPath($TargetRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $expectedPaths = @{
        itcmon = Join-Path $installFull 'itcmon.exe'
        itcwatch = Join-Path $installFull 'itcwatch.exe'
        atcsmon = Join-Path $installFull 'ATCSMon\atcsmon.exe'
    }
    return @(
        Get-Process -Name itcmon, itcwatch, atcsmon -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    [string]::Equals(
                        $_.Path,
                        $expectedPaths[$_.ProcessName.ToLowerInvariant()],
                        [StringComparison]::OrdinalIgnoreCase
                    )
                } catch {
                    # If Windows denies the executable path, block the update rather than
                    # risk replacing a file that may belong to this installation.
                    $true
                }
            }
    )
}

function Update-ClientApplications {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)]$Manifest,
        [string]$LocalITCMonArchive,
        [string]$LocalITCWatchExecutable,
        [string]$LocalATCSMonArchive,
        [string]$LocalShortcutIcon
    )

    $installFull = [IO.Path]::GetFullPath($TargetRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $installPrefix = $installFull + [IO.Path]::DirectorySeparatorChar
    $catalog = Get-ApplicationCatalog -Manifest $Manifest
    $shortcutIcon = Get-ClientAssetCatalog -Manifest $Manifest
    $existingATCSRuntime = (Test-Path -LiteralPath (Join-Path $installFull 'ATCSMon\atcsmon.exe') -PathType Leaf) -or
        (Test-Path -LiteralPath 'C:\ATCS Monitor\atcsmon.exe' -PathType Leaf)
    $current = @{}
    $needsUpdate = $false
    foreach ($name in @('itcmon', 'itcwatch', 'atcsmon')) {
        $entry = $catalog[$name]
        $target = Join-Path $installFull ([string]$entry.executable)
        $hash = if (Test-Path -LiteralPath $target -PathType Leaf) {
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        } else {
            $null
        }
        $current[$name] = $hash
        if ($hash -ne ([string]$entry.executable_sha256).ToUpperInvariant()) {
            $needsUpdate = $true
        }
    }
    $shortcutIconTarget = Join-Path $installFull ([string]$shortcutIcon.destination)
    $current.shortcut_icon = if (Test-Path -LiteralPath $shortcutIconTarget -PathType Leaf) {
        (Get-FileHash -LiteralPath $shortcutIconTarget -Algorithm SHA256).Hash
    } else {
        $null
    }
    if ($current.shortcut_icon -ne ([string]$shortcutIcon.sha256).ToUpperInvariant()) {
        $needsUpdate = $true
    }
    $atcsMonNeedsUpdate = $current.atcsmon -ne
        ([string]$catalog.atcsmon.executable_sha256).ToUpperInvariant()

    if (-not $needsUpdate) {
        return @(
            foreach ($name in @('itcmon', 'itcwatch', 'atcsmon')) {
                [pscustomobject][ordered]@{
                    name = $name
                    version = [string]$catalog[$name].version
                    updated = $false
                    executable_sha256 = $current[$name]
                }
            }
        )
    }
    if (@(Get-TargetClientProcesses -TargetRoot $installFull).Count -ne 0) {
        throw 'ITCMon, ITCWatch, or ATCSMon is running. Close all three before applying software updates.'
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $workRoot = Join-Path $env:TEMP "itcmon-app-update-$PID-$timestamp"
    $operations = @()
    $backupRoot = Join-Path $installFull "application-backups\$timestamp"
    $backupCreated = $false
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    try {
        if ($current.itcmon -ne ([string]$catalog.itcmon.executable_sha256).ToUpperInvariant()) {
            $archive = Join-Path $workRoot 'itcmon.zip'
            if ([string]::IsNullOrWhiteSpace($LocalITCMonArchive)) {
                Save-RemoteFile -Uri ([string]$catalog.itcmon.url) -Destination $archive `
                    -Description "ITCMon $($catalog.itcmon.version) package"
            } else {
                Copy-Item -LiteralPath (Resolve-Path -LiteralPath $LocalITCMonArchive).Path -Destination $archive
            }
            $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
            if ($archiveHash -ne ([string]$catalog.itcmon.sha256).ToUpperInvariant()) {
                throw "ITCMon $($catalog.itcmon.version) package failed SHA-256 validation: $archiveHash"
            }
            $extractRoot = Join-Path $workRoot 'itcmon-package'
            Expand-Archive -LiteralPath $archive -DestinationPath $extractRoot
            $executables = @(Get-ChildItem -LiteralPath $extractRoot -Filter 'itcmon.exe' -File -Recurse)
            if ($executables.Count -ne 1) {
                throw "ITCMon package contained $($executables.Count) itcmon.exe files; expected one."
            }
            if ((Get-FileHash -LiteralPath $executables[0].FullName -Algorithm SHA256).Hash -ne
                ([string]$catalog.itcmon.executable_sha256).ToUpperInvariant()) {
                throw 'The ITCMon executable inside the package failed SHA-256 validation.'
            }
            $packageFull = [IO.Path]::GetFullPath($executables[0].DirectoryName).TrimEnd(
                [IO.Path]::DirectorySeparatorChar,
                [IO.Path]::AltDirectorySeparatorChar
            )
            $preserved = @('itcmon.json', 'mcr.json', 'igw.json', 'i2a.json', 'rrdata.json')
            foreach ($file in @(Get-ChildItem -LiteralPath $packageFull -File -Recurse)) {
                $relative = $file.FullName.Substring($packageFull.Length).TrimStart(
                    [IO.Path]::DirectorySeparatorChar,
                    [IO.Path]::AltDirectorySeparatorChar
                )
                if ($preserved -contains $relative) {
                    continue
                }
                $target = [IO.Path]::GetFullPath((Join-Path $installFull $relative))
                if (-not $target.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "ITCMon package path leaves the installation root: $relative"
                }
                $operations += [pscustomobject]@{
                    source = $file.FullName
                    target = $target
                    relative = $relative
                }
            }
        }

        if ($current.itcwatch -ne ([string]$catalog.itcwatch.executable_sha256).ToUpperInvariant()) {
            $watchDownload = Join-Path $workRoot 'itcwatch.exe'
            if ([string]::IsNullOrWhiteSpace($LocalITCWatchExecutable)) {
                Save-RemoteFile -Uri ([string]$catalog.itcwatch.url) -Destination $watchDownload `
                    -Description "ITCWatch $($catalog.itcwatch.version) package"
            } else {
                Copy-Item -LiteralPath (Resolve-Path -LiteralPath $LocalITCWatchExecutable).Path -Destination $watchDownload
            }
            $watchHash = (Get-FileHash -LiteralPath $watchDownload -Algorithm SHA256).Hash
            if ($watchHash -ne ([string]$catalog.itcwatch.sha256).ToUpperInvariant() -or
                $watchHash -ne ([string]$catalog.itcwatch.executable_sha256).ToUpperInvariant()) {
                throw "ITCWatch $($catalog.itcwatch.version) failed SHA-256 validation: $watchHash"
            }
            $operations += [pscustomobject]@{
                source = $watchDownload
                target = Join-Path $installFull 'itcwatch.exe'
                relative = 'itcwatch.exe'
            }
        }

        if ($atcsMonNeedsUpdate) {
            $atcsArchive = Join-Path $workRoot 'atcsmon.zip'
            if ([string]::IsNullOrWhiteSpace($LocalATCSMonArchive)) {
                Save-RemoteFile -Uri ([string]$catalog.atcsmon.url) -Destination $atcsArchive `
                    -Description "ATCSMon $($catalog.atcsmon.version) package"
            } else {
                Copy-Item -LiteralPath (Resolve-Path -LiteralPath $LocalATCSMonArchive).Path -Destination $atcsArchive
            }
            $atcsArchiveHash = (Get-FileHash -LiteralPath $atcsArchive -Algorithm SHA256).Hash
            if ($atcsArchiveHash -ne ([string]$catalog.atcsmon.sha256).ToUpperInvariant()) {
                throw "ATCSMon $($catalog.atcsmon.version) package failed SHA-256 validation: $atcsArchiveHash"
            }
            $atcsExtractRoot = Join-Path $workRoot 'atcsmon-package'
            Expand-Archive -LiteralPath $atcsArchive -DestinationPath $atcsExtractRoot
            $atcsPackageRoot = Join-Path $atcsExtractRoot 'ATCSMon'
            $atcsExecutable = Join-Path $atcsPackageRoot 'atcsmon.exe'
            if (-not (Test-Path -LiteralPath $atcsExecutable -PathType Leaf) -or
                (Get-FileHash -LiteralPath $atcsExecutable -Algorithm SHA256).Hash -ne
                    ([string]$catalog.atcsmon.executable_sha256).ToUpperInvariant()) {
                throw 'The ATCSMon executable inside the package failed SHA-256 validation.'
            }
            $preservedATCS = @(
                'atcsmon.ini', 'atcsdb.mdb', 'Downloads', 'Import', 'kmz',
                'Layouts', 'Logs', 'MCPs', 'Notes'
            )
            foreach ($file in @(Get-ChildItem -LiteralPath $atcsPackageRoot -File -Recurse)) {
                $relativeWithinATCS = $file.FullName.Substring($atcsPackageRoot.Length).TrimStart(
                    [IO.Path]::DirectorySeparatorChar,
                    [IO.Path]::AltDirectorySeparatorChar
                )
                $topLevel = ($relativeWithinATCS -split '[\\/]')[0]
                if ($preservedATCS -contains $topLevel) {
                    continue
                }
                $relative = Join-Path 'ATCSMon' $relativeWithinATCS
                $target = [IO.Path]::GetFullPath((Join-Path $installFull $relative))
                if (-not $target.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "ATCSMon package path leaves the installation root: $relative"
                }
                $operations += [pscustomobject]@{
                    source = $file.FullName
                    target = $target
                    relative = $relative
                }
            }
        }

        if ($current.shortcut_icon -ne ([string]$shortcutIcon.sha256).ToUpperInvariant()) {
            $iconDownload = Join-Path $workRoot 'itcmon-truck.ico'
            if ([string]::IsNullOrWhiteSpace($LocalShortcutIcon)) {
                Save-RemoteFile -Uri ([string]$shortcutIcon.url) -Destination $iconDownload `
                    -Description 'ITCMon shortcut icon'
            } else {
                Copy-Item -LiteralPath (Resolve-Path -LiteralPath $LocalShortcutIcon).Path -Destination $iconDownload
            }
            $iconHash = (Get-FileHash -LiteralPath $iconDownload -Algorithm SHA256).Hash
            if ($iconHash -ne ([string]$shortcutIcon.sha256).ToUpperInvariant()) {
                throw "ITCMon shortcut icon failed SHA-256 validation: $iconHash"
            }
            $operations += [pscustomobject]@{
                source = $iconDownload
                target = $shortcutIconTarget
                relative = [string]$shortcutIcon.destination
            }
        }

        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        $backupCreated = $true
        foreach ($operation in $operations) {
            if (Test-Path -LiteralPath $operation.target -PathType Leaf) {
                $backup = Join-Path $backupRoot $operation.relative
                New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
                Copy-Item -LiteralPath $operation.target -Destination $backup -Force
            }
        }
        try {
            foreach ($operation in $operations) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $operation.target) -Force | Out-Null
                Copy-Item -LiteralPath $operation.source -Destination $operation.target -Force
            }
            if ($atcsMonNeedsUpdate) {
                Install-ATCSMonRuntime -ATCSRoot (Join-Path $installFull 'ATCSMon') `
                    -SkipRegistration:$existingATCSRuntime
            }
            foreach ($name in @('itcmon', 'itcwatch', 'atcsmon')) {
                $entry = $catalog[$name]
                $target = Join-Path $installFull ([string]$entry.executable)
                $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
                if ($actual -ne ([string]$entry.executable_sha256).ToUpperInvariant()) {
                    throw "Installed $name executable failed post-update SHA-256 validation."
                }
            }
            if ((Get-FileHash -LiteralPath $shortcutIconTarget -Algorithm SHA256).Hash -ne
                ([string]$shortcutIcon.sha256).ToUpperInvariant()) {
                throw 'Installed ITCMon shortcut icon failed post-update SHA-256 validation.'
            }
        } catch {
            foreach ($operation in $operations) {
                $backup = Join-Path $backupRoot $operation.relative
                if (Test-Path -LiteralPath $backup -PathType Leaf) {
                    Copy-Item -LiteralPath $backup -Destination $operation.target -Force
                } elseif (Test-Path -LiteralPath $operation.target -PathType Leaf) {
                    Remove-Item -LiteralPath $operation.target -Force
                }
            }
            throw
        }

        return @(
            foreach ($name in @('itcmon', 'itcwatch', 'atcsmon')) {
                $entry = $catalog[$name]
                $actual = (Get-FileHash -LiteralPath (Join-Path $installFull ([string]$entry.executable)) -Algorithm SHA256).Hash
                [pscustomobject][ordered]@{
                    name = $name
                    version = [string]$entry.version
                    updated = ($current[$name] -ne $actual)
                    executable_sha256 = $actual
                }
            }
        )
    } finally {
        if (Test-Path -LiteralPath $workRoot) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force
        }
        if ($backupCreated -and @(Get-ChildItem -LiteralPath $backupRoot -File -Recurse).Count -eq 0) {
            Remove-Item -LiteralPath $backupRoot -Recurse -Force
        }
    }
}

function Sync-ClientScripts {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)]$Validated
    )

    foreach ($relative in @(
        'scripts/Start-ITCMon-With-Update.ps1',
        'scripts/Start-ITCMon-With-Update.cmd',
        'scripts/Launch-ITCM-Truck-Client.ps1',
        'scripts/Start ITCMon - Truck.cmd',
        'scripts/Start ITCWatch - Truck.cmd',
        'scripts/Start ATCSMon - Truck.cmd',
        'scripts/Diagnose ITCM Truck Client.cmd'
    )) {
        if (-not $Validated.ManifestPaths.ContainsKey($relative)) {
            throw "Configuration manifest does not publish required client script: $relative"
        }
        $source = [string]$Validated.ManifestPaths[$relative]
        $target = Join-Path $TargetRoot (Split-Path -Leaf $relative)
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $targetHash = if (Test-Path -LiteralPath $target -PathType Leaf) {
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        } else {
            $null
        }
        if ($sourceHash -ne $targetHash) {
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
    }
}

function Sync-ClientDesktopShortcuts {
    param([Parameter(Mandatory)][string]$TargetRoot)

    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) {
        return @()
    }
    New-Item -ItemType Directory -Path $desktop -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $definitions = @(
        [pscustomobject]@{
            Name = 'ITCMon - Truck.lnk'
            Command = 'Start ITCMon - Truck.cmd'
            Icon = 'assets\itcmon-truck.ico'
            Description = 'Check for managed client updates, then start ITCMon.'
        },
        [pscustomobject]@{
            Name = 'ITCWatch - Truck.lnk'
            Command = 'Start ITCWatch - Truck.cmd'
            Icon = 'itcwatch.exe'
            Description = 'Check for managed client updates, then start ITCMon and ITCWatch.'
        },
        [pscustomobject]@{
            Name = 'ATCSMon - Truck.lnk'
            Command = 'Start ATCSMon - Truck.cmd'
            Icon = 'ATCSMon\atcsmon.exe'
            Description = 'Check for managed client updates, then start ATCSMon.'
        },
        [pscustomobject]@{
            Name = 'Diagnose ITCM Truck Client.lnk'
            Command = 'Diagnose ITCM Truck Client.cmd'
            Icon = $null
            Description = 'Validate the managed truck client and show persistent diagnostics.'
        }
    )
    $installed = @()
    foreach ($definition in $definitions) {
        $command = Join-Path $TargetRoot $definition.Command
        if (-not (Test-Path -LiteralPath $command -PathType Leaf)) {
            throw "Cannot create desktop shortcut because its command is missing: $command"
        }
        $shortcutPath = Join-Path $desktop $definition.Name
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $env:ComSpec
        $shortcut.Arguments = '/d /c ""{0}""' -f $command
        $shortcut.WorkingDirectory = $TargetRoot
        $shortcut.IconLocation = if ($definition.Icon) {
            Join-Path $TargetRoot $definition.Icon
        } else {
            "$env:SystemRoot\System32\shell32.dll,23"
        }
        $shortcut.Description = $definition.Description
        $shortcut.Save()

        $saved = $shell.CreateShortcut($shortcutPath)
        if (-not [string]::Equals($saved.TargetPath, $env:ComSpec, [StringComparison]::OrdinalIgnoreCase) -or
            $saved.Arguments -ne ('/d /c ""{0}""' -f $command) -or
            -not [string]::Equals($saved.WorkingDirectory, $TargetRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Desktop shortcut failed acceptance: $shortcutPath"
        }
        $installed += $shortcutPath
    }
    return @($installed)
}

function Install-ManagedProfileFiles {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)]$Validated,
        [Parameter(Mandatory)][string]$BackupRoot
    )

    $targetFull = [IO.Path]::GetFullPath($TargetRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $targetPrefix = $targetFull + [IO.Path]::DirectorySeparatorChar
    $installed = @()
    foreach ($managed in @($Validated.ManagedFiles)) {
        $destination = [IO.Path]::GetFullPath((Join-Path $targetFull $managed.DestinationRelative))
        if (-not $destination.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Managed-file destination leaves the ITCMon installation: $($managed.DestinationRelative)"
        }
        $destinationDirectory = Split-Path -Parent $destination
        $backup = Join-Path $BackupRoot (Join-Path 'managed-files' $managed.DestinationRelative)
        $backupDirectory = Split-Path -Parent $backup
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
            Copy-Item -LiteralPath $destination -Destination $backup -Force
        }
        Copy-Item -LiteralPath $managed.Source -Destination $destination -Force
        $sourceHash = (Get-FileHash -LiteralPath $managed.Source -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        if ($sourceHash -ne $destinationHash) {
            if (Test-Path -LiteralPath $backup -PathType Leaf) {
                Copy-Item -LiteralPath $backup -Destination $destination -Force
            }
            throw "Managed file failed post-copy validation: $($managed.DestinationRelative)"
        }
        $installed += [pscustomobject][ordered]@{
            path = $managed.DestinationRelative
            sha256 = $destinationHash
        }
    }
    return @($installed)
}

function Install-Configuration {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)]$Validated
    )

    $installFull = [IO.Path]::GetFullPath($TargetRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $installPrefix = $installFull + [IO.Path]::DirectorySeparatorChar
    if (-not (Test-Path -LiteralPath $installFull -PathType Container)) {
        throw "ITCMon installation directory does not exist: $installFull"
    }
    $executable = Join-Path $installFull 'itcmon.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "ITCMon executable does not exist: $executable"
    }
    if (@(Get-TargetClientProcesses -TargetRoot $installFull).Count -ne 0) {
        throw 'ITCMon, ITCWatch, or ATCSMon is already running. Close all three before applying configuration.'
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $backupRoot = Join-Path $installFull "config-backups\$timestamp"
    $stageRoot = Join-Path $installFull ".config-stage-$PID"
    $newWIUs = Join-Path $stageRoot 'wius'
    $localConfigRoot = Join-Path $installFull 'local'
    New-Item -ItemType Directory -Path $localConfigRoot -Force | Out-Null
    $currentProfile = Join-Path $localConfigRoot 'itcmon.json'
    $currentRRData = Join-Path $localConfigRoot 'rrdata.json'
    $currentWIUs = Join-Path $installFull 'wius'
    if (-not (Test-Path -LiteralPath $currentProfile -PathType Leaf) -and -not $Validated.ProfileConfig) {
        throw "ITCMon server configuration does not exist: $currentProfile"
    }
    if (-not (Test-Path -LiteralPath $currentRRData -PathType Leaf) -and -not $Validated.RRDataPath) {
        throw "ITCMon railroad data does not exist: $currentRRData"
    }
    $profileJson = if ($Validated.ProfileConfig) {
        $Validated.ProfileConfig
    } else {
        Read-JsonFile -Path $currentProfile
    }
    $serverCount = @($profileJson.servers).Count
    if ($serverCount -eq 0) {
        throw 'The existing ITCMon server configuration contains no servers.'
    }

    foreach ($path in @($backupRoot, $stageRoot)) {
        $full = [IO.Path]::GetFullPath($path)
        if (-not $full.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing configuration operation outside the ITCMon installation: $full"
        }
    }
    if (Test-Path -LiteralPath $stageRoot) {
        throw "Staging directory already exists: $stageRoot"
    }

    $null = New-Item -ItemType Directory -Path $stageRoot
    Copy-Item -LiteralPath $Validated.WIURoot -Destination $newWIUs -Recurse
    if ($Validated.RRDataPath) {
        Copy-Item -LiteralPath $Validated.RRDataPath -Destination (Join-Path $stageRoot 'rrdata.json')
    }
    if ($Validated.ProfileConfig) {
        $profileText = $Validated.ProfileConfig | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText(
            (Join-Path $stageRoot 'itcmon.json'),
            $profileText + "`r`n",
            (New-Object Text.UTF8Encoding($false))
        )
    }

    $null = New-Item -ItemType Directory -Path $backupRoot -Force
    if (Test-Path -LiteralPath $currentProfile -PathType Leaf) {
        Copy-Item -LiteralPath $currentProfile -Destination (Join-Path $backupRoot 'itcmon.json')
    }
    if (Test-Path -LiteralPath $currentRRData -PathType Leaf) {
        Copy-Item -LiteralPath $currentRRData -Destination (Join-Path $backupRoot 'rrdata.json')
    }
    $wiusMoved = $false
    try {
        if (Test-Path -LiteralPath $currentWIUs) {
            Move-Item -LiteralPath $currentWIUs -Destination (Join-Path $backupRoot 'wius')
            $wiusMoved = $true
        }
        Move-Item -LiteralPath $newWIUs -Destination $currentWIUs
        if ($Validated.RRDataPath) {
            Copy-Item -LiteralPath (Join-Path $stageRoot 'rrdata.json') -Destination $currentRRData -Force
        }
        if ($Validated.ProfileConfig) {
            Copy-Item -LiteralPath (Join-Path $stageRoot 'itcmon.json') -Destination $currentProfile -Force
            if ($Validated.ProfilePath -and $Validated.ProfileName) {
                Copy-Item -LiteralPath $Validated.ProfilePath `
                    -Destination (Join-Path $installFull "$($Validated.ProfileName)-profile.json") -Force
            }
        }
    } catch {
        if (Test-Path -LiteralPath $currentWIUs) {
            Remove-Item -LiteralPath $currentWIUs -Recurse -Force
        }
        if ($wiusMoved) {
            Move-Item -LiteralPath (Join-Path $backupRoot 'wius') -Destination $currentWIUs
        }
        $profileBackup = Join-Path $backupRoot 'itcmon.json'
        if (Test-Path -LiteralPath $profileBackup -PathType Leaf) {
            Copy-Item -LiteralPath $profileBackup -Destination $currentProfile -Force
        } elseif (Test-Path -LiteralPath $currentProfile -PathType Leaf) {
            Remove-Item -LiteralPath $currentProfile -Force
        }
        $rrdataBackup = Join-Path $backupRoot 'rrdata.json'
        if (Test-Path -LiteralPath $rrdataBackup -PathType Leaf) {
            Copy-Item -LiteralPath $rrdataBackup -Destination $currentRRData -Force
        } elseif (Test-Path -LiteralPath $currentRRData -PathType Leaf) {
            Remove-Item -LiteralPath $currentRRData -Force
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $stageRoot) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force
        }
    }

    return [pscustomobject]@{
        Executable = $executable
        BackupRoot = $backupRoot
        ServerCount = $serverCount
        ProfileName = if ($Validated.ProfileName) { $Validated.ProfileName } else { 'preserved' }
        ProfileSHA256 = (Get-FileHash -LiteralPath $currentProfile -Algorithm SHA256).Hash
        RRDataSHA256 = (Get-FileHash -LiteralPath $currentRRData -Algorithm SHA256).Hash
    }
}

$temporaryArchiveRoot = $null
Write-Host ("[update] Truck client refresh started at {0}." -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
try {
    $temporaryPrefix = [IO.Path]::GetFullPath($env:TEMP).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    Write-UpdateStage -Number 1 -Description 'Refresh and validate the configuration catalog.'
    if ($SourceRoot) {
        $repositoryRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
    } else {
        $gitAvailable = [bool](Get-Command git.exe -ErrorAction SilentlyContinue)
        $repositoryRoot = Get-RepositoryRoot -Url $RepositoryUrl -Ref $Branch -Cache $CacheRoot
        if (-not $gitAvailable -and
            $repositoryRoot.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $temporaryArchiveRoot = Split-Path -Parent $repositoryRoot
        }
    }
    $validated = Test-RepositoryConfiguration -RepositoryRoot $repositoryRoot `
        -ManifestProfileName $ProfileName `
        -ExternalProfilePath $ServerProfilePath `
        -ExpectedExternalProfileSHA256 $ExpectedServerProfileSHA256 `
        -HostOverride $ServerHostOverride
    Write-UpdateStage -Number 2 -Description 'Check the installed ITCMon, ITCWatch, and ATCSMon application versions.'
    $applicationStatus = if ($UpdateApplications) {
        @(Update-ClientApplications -TargetRoot $InstallRoot -Manifest $validated.Manifest `
            -LocalITCMonArchive $ITCMonArchivePath `
            -LocalITCWatchExecutable $ITCWatchExecutablePath `
            -LocalATCSMonArchive $ATCSMonArchivePath `
            -LocalShortcutIcon $ShortcutIconPath)
    } else {
        @()
    }
    Write-UpdateStage -Number 3 -Description 'Apply the truck endpoint, WIUs, railroad data, and updater files.'
    $installed = Install-Configuration -TargetRoot $InstallRoot -Validated $validated
    $managedFileStatus = @(Install-ManagedProfileFiles -TargetRoot $InstallRoot -Validated $validated `
        -BackupRoot $installed.BackupRoot)
    $itcWatchConfiguration = $null
    if ($validated.ProfileSpec -and $validated.ProfileSpec.PSObject.Properties['itcwatch']) {
        $itcWatchConfiguration = Install-ITCWatchViewerConfiguration -BackupRoot $installed.BackupRoot
    }
    Sync-ClientScripts -TargetRoot $InstallRoot -Validated $validated
    $shortcutStatus = if ($NoDesktopShortcut) {
        @()
    } else {
        @(Sync-ClientDesktopShortcuts -TargetRoot $InstallRoot)
    }
    Copy-Item -LiteralPath $validated.ManifestPath `
        -Destination (Join-Path $InstallRoot 'itcmon-config-manifest.json') -Force

    $launching = if ($NoLaunch) { 'None' } else { $LaunchTarget }
    $updateReceipt = [pscustomobject][ordered]@{
        schema = 'itcmon.truck-client.update.v1'
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
        manifest_version = [string]$validated.Manifest.version
        server_host = $ServerHostOverride
        server_profile = $installed.ProfileName
        servers = $installed.ServerCount
        wius = $validated.WIUCount
        profile_sha256 = $installed.ProfileSHA256
        rrdata_sha256 = $installed.RRDataSHA256
        itcwatch_endpoint = if ($itcWatchConfiguration) { 'tcp://127.0.0.1:18001' } else { $null }
        itcwatch_config = if ($itcWatchConfiguration) { $itcWatchConfiguration.Path } else { $null }
        itcwatch_config_sha256 = if ($itcWatchConfiguration) { $itcWatchConfiguration.SHA256 } else { $null }
        managed_files = @($managedFileStatus)
        applications = @($applicationStatus)
        desktop_shortcuts = @($shortcutStatus)
        launching = $launching
    }
    [IO.File]::WriteAllText(
        (Join-Path $InstallRoot 'truck-client-update.json'),
        ($updateReceipt | ConvertTo-Json -Depth 6) + "`r`n",
        (New-Object Text.UTF8Encoding($false))
    )

    [pscustomobject]@{
        Version = $validated.Manifest.version
        Servers = $installed.ServerCount
        WIUs = $validated.WIUCount
        Profile = $installed.ProfileName
        ProfileSHA256 = $installed.ProfileSHA256
        RRDataSHA256 = $installed.RRDataSHA256
        Applications = @($applicationStatus | ForEach-Object { "$($_.name) $($_.version) updated=$($_.updated)" }) -join '; '
        Backup = $installed.BackupRoot
        Launching = $launching
    } | Format-List

    Write-UpdateStage -Number 4 -Description 'Complete acceptance checks and launch the selected application.'
    if (-not $NoLaunch) {
        if ($LaunchTarget -eq 'ATCSMon') {
            Start-Process -FilePath (Join-Path $InstallRoot 'ATCSMon\atcsmon.exe') `
                -WorkingDirectory (Join-Path $InstallRoot 'ATCSMon')
        } else {
            Start-Process -FilePath $installed.Executable -WorkingDirectory $InstallRoot
        }
        if ($LaunchTarget -eq 'ITCWatch') {
            Start-Sleep -Seconds 2
            Start-Process -FilePath (Join-Path $InstallRoot 'itcwatch.exe') -WorkingDirectory $InstallRoot
        }
    }
    Write-Host ("[update complete] Truck client refresh finished at {0}." -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
} catch {
    Write-Host "[update failed] Refresh stopped during $currentUpdateStage" -ForegroundColor Red
    Write-Host "[update failed] $($_.Exception.Message)" -ForegroundColor Red
    throw
} finally {
    if ($temporaryArchiveRoot -and
        (Test-Path -LiteralPath $temporaryArchiveRoot) -and
        $temporaryArchiveRoot.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temporaryArchiveRoot -Recurse -Force
        $archive = "$temporaryArchiveRoot.zip"
        if (Test-Path -LiteralPath $archive) {
            Remove-Item -LiteralPath $archive -Force
        }
    }
}
