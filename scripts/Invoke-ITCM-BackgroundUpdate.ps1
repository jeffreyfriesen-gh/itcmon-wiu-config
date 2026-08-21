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
    if ($logPath) {
        Get-ChildItem -LiteralPath (Split-Path -Parent $logPath) -Filter 'update-*.log' -File |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -Skip 30 |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}
