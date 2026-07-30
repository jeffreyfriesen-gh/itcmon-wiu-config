[CmdletBinding()]
param(
    [string]$InstallRoot = $PSScriptRoot,

    [string]$RepositoryUrl = 'https://github.com/jeffreyfriesen-gh/itcmon-wiu-config.git',

    [string]$Branch = 'main',

    [string]$CacheRoot = (Join-Path $env:LOCALAPPDATA 'ITCMon\ConfigRepository'),

    [string]$SourceRoot,

    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)

    $text = [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    return $text | ConvertFrom-Json
}

function Assert-CommandSucceeded {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][int]$ExitCode
    )

    if ($ExitCode -ne 0) {
        throw "$Description failed with exit code $ExitCode."
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
            & $git.Source -C $Cache pull --ff-only origin $Ref
            Assert-CommandSucceeded -Description 'GitHub configuration pull' -ExitCode $LASTEXITCODE
        } else {
            if (Test-Path -LiteralPath $Cache) {
                $items = @(Get-ChildItem -LiteralPath $Cache -Force)
                if ($items.Count -ne 0) {
                    throw "Configuration cache exists but is not a Git checkout: $Cache"
                }
            } else {
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Cache) -Force
            }
            & $git.Source clone --depth 1 --branch $Ref --single-branch $Url $Cache
            Assert-CommandSucceeded -Description 'GitHub configuration clone' -ExitCode $LASTEXITCODE
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
    param([Parameter(Mandatory)][string]$RepositoryRoot)

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

    return [pscustomobject]@{
        Manifest = $manifest
        WIURoot = $wiuRoot
        WIUCount = $wiuIDs.Count
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
    $currentWIUs = Join-Path $installFull 'wius'
    if (-not (Test-Path -LiteralPath $currentProfile -PathType Leaf)) {
        throw "ITCMon server configuration does not exist: $currentProfile"
    }
    $profileJson = Read-JsonFile -Path $currentProfile
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

    $null = New-Item -ItemType Directory -Path $backupRoot -Force
    Copy-Item -LiteralPath $currentProfile -Destination (Join-Path $backupRoot 'itcmon.json')
    $wiusMoved = $false
    try {
        if (Test-Path -LiteralPath $currentWIUs) {
            Move-Item -LiteralPath $currentWIUs -Destination (Join-Path $backupRoot 'wius')
            $wiusMoved = $true
        }
        Move-Item -LiteralPath $newWIUs -Destination $currentWIUs
    } catch {
        if (Test-Path -LiteralPath $currentWIUs) {
            Remove-Item -LiteralPath $currentWIUs -Recurse -Force
        }
        if ($wiusMoved) {
            Move-Item -LiteralPath (Join-Path $backupRoot 'wius') -Destination $currentWIUs
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
    $validated = Test-RepositoryConfiguration -RepositoryRoot $repositoryRoot
    $installed = Install-Configuration -TargetRoot $InstallRoot -Validated $validated

    [pscustomobject]@{
        Version = $validated.Manifest.version
        Servers = $installed.ServerCount
        WIUs = $validated.WIUCount
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
