[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\ITCM\Applications\ITCMon-v1.0',
    [string]$RepositoryUrl = 'https://github.com/jeffreyfriesen-gh/itcmon-wiu-config.git',
    [string]$Branch = 'main',
    [string]$CacheRoot = 'C:\ProgramData\ITCMon\ConfigRepository',
    [string]$ProfileName = 'truck-vm201',
    [string]$ServerHostOverride,
    [string]$StateRoot = 'C:\ProgramData\ITCMon\GitHubUpdater'
)

$ErrorActionPreference = 'Stop'
$startedAt = (Get-Date).ToUniversalTime()
$stamp = $startedAt.ToString('yyyyMMddTHHmmssZ')
$mutex = $null
$lockAcquired = $false
$transcriptStarted = $false
$outcome = 'failed'
$detail = $null
$manifestVersion = $null
$logPath = $null
$manifestDownload = $null

function ConvertTo-ManifestVersionKey {
    param([Parameter(Mandatory)][string]$Version)

    if ($Version -notmatch '^(\d{4})-(\d{2})-(\d{2})\.(\d+)$') {
        throw "Unsupported configuration manifest version: $Version"
    }
    $date = [int64]("{0}{1}{2}" -f $Matches[1], $Matches[2], $Matches[3])
    $revision = [int64]$Matches[4]
    if ($revision -ge 1000000) {
        throw "Configuration manifest revision is too large: $Version"
    }
    return ($date * 1000000L) + $revision
}

function Write-Status {
    param([Parameter(Mandatory)][string]$Result)

    $status = [pscustomobject][ordered]@{
        schema = 'itcm.github-background-update.v1'
        started_at = $startedAt.ToString('o')
        completed_at = (Get-Date).ToUniversalTime().ToString('o')
        outcome = $Result
        detail = $detail
        manifest_version = $manifestVersion
        repository = $RepositoryUrl
        branch = $Branch
        install_root = $InstallRoot
        cache_root = $CacheRoot
        profile = $ProfileName
        log = $logPath
    }
    $statusPath = Join-Path $StateRoot 'status.json'
    $temporary = "$statusPath.$PID.tmp"
    [IO.File]::WriteAllText(
        $temporary,
        ($status | ConvertTo-Json -Depth 5) + "`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    Move-Item -LiteralPath $temporary -Destination $statusPath -Force
}

try {
    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    $logRoot = Join-Path $StateRoot 'Logs'
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $logPath = Join-Path $logRoot "update-$stamp-pid$PID.log"
    Start-Transcript -LiteralPath $logPath -Force | Out-Null
    $transcriptStarted = $true

    $mutex = New-Object Threading.Mutex($false, 'Global\ITCMGitHubConfigurationUpdate')
    $lockAcquired = $mutex.WaitOne(0)
    if (-not $lockAcquired) {
        $outcome = 'deferred'
        $detail = 'Another GitHub configuration update is already running.'
        Write-Host $detail
        return
    }

    if ($RepositoryUrl -notmatch '^https://github\.com/([^/]+)/([^/]+?)(?:\.git)?$') {
        throw "Background manifest preflight supports only an HTTPS GitHub repository URL: $RepositoryUrl"
    }
    $owner = $Matches[1]
    $repositoryName = $Matches[2]
    if ($Branch -notmatch '^[A-Za-z0-9._/-]+$') {
        throw "Unsafe GitHub branch name: $Branch"
    }
    $manifestUri = "https://raw.githubusercontent.com/$owner/$repositoryName/$Branch/manifest.json"
    $manifestDownload = Join-Path $env:TEMP "itcm-github-manifest-$PID.json"
    if (Test-Path -LiteralPath $manifestDownload) {
        throw "Refusing to replace unexpected manifest staging file: $manifestDownload"
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $manifestUri -OutFile $manifestDownload -TimeoutSec 60
    $remoteManifest = [IO.File]::ReadAllText($manifestDownload).TrimStart([char]0xFEFF) | ConvertFrom-Json
    if ($remoteManifest.schema -ne 'itcmon.config.manifest.v1') {
        throw "Unsupported GitHub manifest schema: $($remoteManifest.schema)"
    }
    $manifestVersion = [string]$remoteManifest.version
    $remoteKey = ConvertTo-ManifestVersionKey -Version $manifestVersion
    $installedManifestPath = Join-Path $InstallRoot 'itcmon-config-manifest.json'
    if (Test-Path -LiteralPath $installedManifestPath -PathType Leaf) {
        $installedManifest = [IO.File]::ReadAllText($installedManifestPath).TrimStart([char]0xFEFF) | ConvertFrom-Json
        $installedVersion = [string]$installedManifest.version
        $installedKey = ConvertTo-ManifestVersionKey -Version $installedVersion
        if ($remoteKey -lt $installedKey) {
            throw "Refusing configuration downgrade from $installedVersion to $manifestVersion."
        }
        if ($remoteKey -eq $installedKey) {
            $remoteHash = (Get-FileHash -LiteralPath $manifestDownload -Algorithm SHA256).Hash
            $installedHash = (Get-FileHash -LiteralPath $installedManifestPath -Algorithm SHA256).Hash
            if ($remoteHash -ne $installedHash) {
                throw "Refusing changed content published under existing manifest version $manifestVersion."
            }
            $outcome = 'current'
            $detail = "Validated GitHub configuration $manifestVersion is already installed."
            Write-Host $detail
            return
        }
    }

    $installFull = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $expectedExecutables = @{
        itcmon = Join-Path $installFull 'itcmon.exe'
        itcwatch = Join-Path $installFull 'itcwatch.exe'
        atcsmon = Join-Path $installFull 'ATCSMon\atcsmon.exe'
    }
    $active = @(Get-Process -Name itcmon, itcwatch, atcsmon -ErrorAction SilentlyContinue |
        Where-Object {
            try {
                [string]::Equals(
                    $_.Path,
                    $expectedExecutables[$_.ProcessName.ToLowerInvariant()],
                    [StringComparison]::OrdinalIgnoreCase
                )
            } catch {
                $true
            }
        })
    if ($active.Count -ne 0) {
        $outcome = 'deferred'
        $detail = 'ITCMon, ITCWatch, or ATCSMon is active; the update was safely deferred.'
        Write-Host $detail
        return
    }

    $updater = Join-Path $installFull 'Start-ITCMon-With-Update.ps1'
    if (-not (Test-Path -LiteralPath $updater -PathType Leaf)) {
        throw "Installed updater is missing: $updater"
    }
    $arguments = @{
        InstallRoot = $installFull
        RepositoryUrl = $RepositoryUrl
        Branch = $Branch
        CacheRoot = $CacheRoot
        ProfileName = $ProfileName
        NoDesktopShortcut = $true
        NoLaunch = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($ServerHostOverride)) {
        $arguments.ServerHostOverride = $ServerHostOverride
    }
    & $updater @arguments

    $receiptPath = Join-Path $installFull 'truck-client-update.json'
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw "Updater returned without creating its receipt: $receiptPath"
    }
    $receipt = [IO.File]::ReadAllText($receiptPath).TrimStart([char]0xFEFF) | ConvertFrom-Json
    if ($receipt.schema -ne 'itcmon.truck-client.update.v1') {
        throw "Updater receipt has an unsupported schema: $($receipt.schema)"
    }
    $manifestVersion = [string]$receipt.manifest_version
    $outcome = 'updated'
    $detail = "Validated GitHub configuration $manifestVersion is installed."
    Write-Host $detail
} catch {
    $detail = $_.Exception.Message
    Write-Error $detail
    throw
} finally {
    if ($lockAcquired -and $mutex) {
        $mutex.ReleaseMutex()
    }
    if ($mutex) {
        $mutex.Dispose()
    }
    try {
        Write-Status -Result $outcome
    } catch {
        Write-Warning "Could not write background-update status: $($_.Exception.Message)"
    }
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
    if ($manifestDownload -and (Test-Path -LiteralPath $manifestDownload)) {
        Remove-Item -LiteralPath $manifestDownload -Force -ErrorAction SilentlyContinue
    }
    if ($logPath) {
        Get-ChildItem -LiteralPath (Split-Path -Parent $logPath) -Filter 'update-*.log' -File |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -Skip 30 |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}
