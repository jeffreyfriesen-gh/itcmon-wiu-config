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

    [ValidateSet('ITCMon', 'ITCWatch')]
    [string]$LaunchTarget = 'ITCMon',

    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)

    $text = [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    return $text | ConvertFrom-Json
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
    if ($length -lt 1MB) {
        Write-Host ("{0}: downloaded {1:N1} KiB." -f $Description, ($length / 1KB))
    } else {
        Write-Host ("{0}: downloaded {1:N1} MiB." -f $Description, ($length / 1MB))
    }
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
        if (@($profileConfig.servers).Count -ne 52) {
            throw "Server profile '$profileName' generated $(@($profileConfig.servers).Count) servers; expected 52."
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

    return [pscustomobject]@{
        Manifest = $manifest
        WIURoot = $wiuRoot
        WIUCount = $wiuIDs.Count
        RRDataPath = $rrdataPath
        RRDataSHA256 = $rrdataSHA256
        ProfileName = $profileName
        ProfileConfig = $profileConfig
        ProfilePath = $profilePath
        ProfileSHA256 = $profileSHA256
        ManifestPaths = $manifestPaths
    }
}

function Get-ApplicationCatalog {
    param([Parameter(Mandatory)]$Manifest)

    $entries = @($Manifest.applications)
    $catalog = @{}
    foreach ($name in @('itcmon', 'itcwatch')) {
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
        if ($uri.Scheme -ne 'https' -or
            $uri.Host -notin @('github.com', 'raw.githubusercontent.com') -or
            -not $uri.AbsolutePath.StartsWith('/katsojuna/', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Application '$name' does not use an allowed official katsojuna GitHub URL."
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
    return $catalog
}

function Update-ClientApplications {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)]$Manifest,
        [string]$LocalITCMonArchive,
        [string]$LocalITCWatchExecutable
    )

    $installFull = [IO.Path]::GetFullPath($TargetRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $installPrefix = $installFull + [IO.Path]::DirectorySeparatorChar
    $catalog = Get-ApplicationCatalog -Manifest $Manifest
    $current = @{}
    $needsUpdate = $false
    foreach ($name in @('itcmon', 'itcwatch')) {
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

    if (-not $needsUpdate) {
        return @(
            foreach ($name in @('itcmon', 'itcwatch')) {
                [pscustomobject][ordered]@{
                    name = $name
                    version = [string]$catalog[$name].version
                    updated = $false
                    executable_sha256 = $current[$name]
                }
            }
        )
    }
    if (@(Get-Process -Name itcmon, itcwatch -ErrorAction SilentlyContinue).Count -ne 0) {
        throw 'ITCMon or ITCWatch is running. Close both before applying software updates.'
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
            foreach ($name in @('itcmon', 'itcwatch')) {
                $entry = $catalog[$name]
                $target = Join-Path $installFull ([string]$entry.executable)
                $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
                if ($actual -ne ([string]$entry.executable_sha256).ToUpperInvariant()) {
                    throw "Installed $name executable failed post-update SHA-256 validation."
                }
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
            foreach ($name in @('itcmon', 'itcwatch')) {
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
        'scripts/Start-ITCMon-With-Update.cmd'
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
    if (@(Get-Process -Name itcmon, itcwatch -ErrorAction SilentlyContinue).Count -ne 0) {
        throw 'ITCMon or ITCWatch is already running. Close both before applying configuration.'
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $backupRoot = Join-Path $installFull "config-backups\$timestamp"
    $stageRoot = Join-Path $installFull ".config-stage-$PID"
    $newWIUs = Join-Path $stageRoot 'wius'
    $currentProfile = Join-Path $installFull 'itcmon.json'
    $currentRRData = Join-Path $installFull 'rrdata.json'
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
        -ManifestProfileName $ProfileName `
        -ExternalProfilePath $ServerProfilePath `
        -ExpectedExternalProfileSHA256 $ExpectedServerProfileSHA256 `
        -HostOverride $ServerHostOverride
    $applicationStatus = if ($UpdateApplications) {
        @(Update-ClientApplications -TargetRoot $InstallRoot -Manifest $validated.Manifest `
            -LocalITCMonArchive $ITCMonArchivePath `
            -LocalITCWatchExecutable $ITCWatchExecutablePath)
    } else {
        @()
    }
    $installed = Install-Configuration -TargetRoot $InstallRoot -Validated $validated
    Sync-ClientScripts -TargetRoot $InstallRoot -Validated $validated

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
        applications = @($applicationStatus)
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

    if (-not $NoLaunch) {
        Start-Process -FilePath $installed.Executable -WorkingDirectory $InstallRoot
        if ($LaunchTarget -eq 'ITCWatch') {
            Start-Sleep -Seconds 2
            Start-Process -FilePath (Join-Path $InstallRoot 'itcwatch.exe') -WorkingDirectory $InstallRoot
        }
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
