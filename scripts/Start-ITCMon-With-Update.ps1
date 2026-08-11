[CmdletBinding()]
param(
    [string]$InstallRoot = $PSScriptRoot,

    [string]$RepositoryUrl = 'https://github.com/jeffreyfriesen-gh/itcmon-wiu-config.git',

    [string]$Branch = 'main',

    [string]$CacheRoot = (Join-Path $env:LOCALAPPDATA 'ITCMon\ConfigRepository'),

    [string]$SourceRoot,

    [string]$ServerProfilePath,

    [string]$ExpectedServerProfileSHA256,

    [string]$ServerHostOverride,

    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)

    $text = [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    return $text | ConvertFrom-Json
}

function ConvertFrom-ServerProfile {
    param(
        [Parameter(Mandatory)]$Profile,
        [string]$HostOverride
    )

    if ($Profile.schema -ne 'itcmon.server-profile.v1') {
        throw "Unsupported server-profile schema: $($Profile.schema)"
    }
    $hostName = if ([string]::IsNullOrWhiteSpace($HostOverride)) {
        [string]$Profile.host
    } else {
        $HostOverride.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        throw 'The selected server profile has no host.'
    }
    $channels = @($Profile.channels | ForEach-Object { [int]$_ })
    $rates = @($Profile.rates)
    if ($channels.Count -eq 0 -or @($channels | Sort-Object -Unique).Count -ne $channels.Count) {
        throw 'The selected server profile has no channels or contains duplicate channels.'
    }
    if ($rates.Count -eq 0) {
        throw 'The selected server profile has no data-rate definitions.'
    }

    $servers = foreach ($channel in $channels) {
        foreach ($rate in $rates) {
            $suffix = [string]$rate.suffix
            $portBase = [int]$rate.port_base
            if ([string]::IsNullOrWhiteSpace($suffix) -or $portBase -le 0) {
                throw 'The selected server profile contains an invalid rate definition.'
            }
            [pscustomobject][ordered]@{
                name = "$($Profile.name_prefix) Ch $channel $suffix"
                ip = $hostName
                port = $portBase + $channel
                channel = $channel
                enabled = $true
            }
        }
    }
    $duplicatePorts = @($servers | Group-Object port | Where-Object Count -ne 1)
    if ($duplicatePorts.Count -ne 0) {
        throw 'The selected server profile generates duplicate TCP ports.'
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
    Invoke-WebRequest -UseBasicParsing -Uri $archiveUrl -OutFile $archivePath
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

    $profileName = $null
    $profileConfig = $null
    if (-not [string]::IsNullOrWhiteSpace($ExternalProfilePath)) {
        if ([string]::IsNullOrWhiteSpace($ExpectedExternalProfileSHA256)) {
            throw 'ExpectedServerProfileSHA256 is required with ServerProfilePath.'
        }
        $profilePath = (Resolve-Path -LiteralPath $ExternalProfilePath).Path
        $profileHash = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
        if ($profileHash -ne $ExpectedExternalProfileSHA256.ToUpperInvariant()) {
            throw "External server profile failed SHA-256 validation: $profileHash"
        }
        $profileSpec = Read-JsonFile -Path $profilePath
        $profileName = [string]$profileSpec.name
        if ([string]::IsNullOrWhiteSpace($profileName)) {
            throw 'The external server profile has no name.'
        }
        $profileConfig = ConvertFrom-ServerProfile -Profile $profileSpec -HostOverride $HostOverride
        if (@($profileConfig.servers).Count -ne 52) {
            throw "Server profile '$profileName' generated $(@($profileConfig.servers).Count) servers; expected 52."
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($HostOverride)) {
        throw 'ServerHostOverride requires ServerProfilePath.'
    } elseif (-not [string]::IsNullOrWhiteSpace($ExpectedExternalProfileSHA256)) {
        throw 'ExpectedServerProfileSHA256 requires ServerProfilePath.'
    }

    return [pscustomobject]@{
        Manifest = $manifest
        WIURoot = $wiuRoot
        WIUCount = $wiuIDs.Count
        RRDataPath = $rrdataPath
        RRDataSHA256 = $rrdataSHA256
        ProfileName = $profileName
        ProfileConfig = $profileConfig
    }
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
    if (@(Get-Process -Name itcmon -ErrorAction SilentlyContinue).Count -ne 0) {
        throw 'ITCMon is already running. Close it before applying configuration.'
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $backupRoot = Join-Path $installFull "config-backups\$timestamp"
    $stageRoot = Join-Path $installFull ".config-stage-$PID"
    $newWIUs = Join-Path $stageRoot 'wius'
    $currentProfile = Join-Path $installFull 'itcmon.json'
    $currentRRData = Join-Path $installFull 'rrdata.json'
    $currentWIUs = Join-Path $installFull 'wius'
    if (-not (Test-Path -LiteralPath $currentProfile -PathType Leaf)) {
        throw "ITCMon server configuration does not exist: $currentProfile"
    }
    if (-not (Test-Path -LiteralPath $currentRRData -PathType Leaf)) {
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
    Copy-Item -LiteralPath $currentProfile -Destination (Join-Path $backupRoot 'itcmon.json')
    Copy-Item -LiteralPath $currentRRData -Destination (Join-Path $backupRoot 'rrdata.json')
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
        }
    } catch {
        if (Test-Path -LiteralPath $currentWIUs) {
            Remove-Item -LiteralPath $currentWIUs -Recurse -Force
        }
        if ($wiusMoved) {
            Move-Item -LiteralPath (Join-Path $backupRoot 'wius') -Destination $currentWIUs
        }
        Copy-Item -LiteralPath (Join-Path $backupRoot 'itcmon.json') -Destination $currentProfile -Force
        Copy-Item -LiteralPath (Join-Path $backupRoot 'rrdata.json') -Destination $currentRRData -Force
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
try {
    $temporaryPrefix = [IO.Path]::GetFullPath($env:TEMP).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
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
        -ExternalProfilePath $ServerProfilePath `
        -ExpectedExternalProfileSHA256 $ExpectedServerProfileSHA256 `
        -HostOverride $ServerHostOverride
    $installed = Install-Configuration -TargetRoot $InstallRoot -Validated $validated

    [pscustomobject]@{
        Version = $validated.Manifest.version
        Servers = $installed.ServerCount
        WIUs = $validated.WIUCount
        Profile = $installed.ProfileName
        ProfileSHA256 = $installed.ProfileSHA256
        RRDataSHA256 = $installed.RRDataSHA256
        Backup = $installed.BackupRoot
        Launching = -not $NoLaunch
    } | Format-List

    if (-not $NoLaunch) {
        Start-Process -FilePath $installed.Executable -WorkingDirectory $InstallRoot
    }
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
