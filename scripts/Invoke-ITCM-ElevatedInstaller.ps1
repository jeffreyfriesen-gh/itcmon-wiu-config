[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallerPath,

    [Parameter(Mandatory)][string]$ConfigurationSourceRoot,

    [Parameter(Mandatory)][string]$InstallerLogRoot,

    [string]$InstallRoot,

    [string]$DesktopPath,

    [string]$TruckHost = 'telemetry-node.lan',

    [string]$RailfanHost = 'railfan-01',

    [switch]$NoDesktopShortcut,

    [switch]$NoLaunch,

    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$startedAt = (Get-Date).ToUniversalTime()
$runId = $startedAt.ToString('yyyyMMddTHHmmssZ') + "-pid$PID"
$runnerLogPath = Join-Path $InstallerLogRoot "runner-$runId.log"
$runnerStatusPath = Join-Path $InstallerLogRoot "runner-$runId.status.json"
$lastRunnerStatusPath = Join-Path $InstallerLogRoot 'last-runner-status.json'
$stage = 'initialize elevated runner diagnostics'
$transcriptStarted = $false
$pauseRequired = $false
$exitCode = 1

function Write-RunnerStatus {
    param(
        [Parameter(Mandatory)][string]$Outcome,
        [string]$ErrorMessage
    )

    $status = [pscustomobject][ordered]@{
        schema = 'itcm.client.elevated-runner.status.v1'
        run_id = $runId
        started_at = $startedAt.ToString('o')
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
        outcome = $Outcome
        stage = $stage
        error = $ErrorMessage
        runner_log = $runnerLogPath
        installer_path = $InstallerPath
        configuration_source = $ConfigurationSourceRoot
        install_root = $InstallRoot
        powershell_version = $PSVersionTable.PSVersion.ToString()
        process_is_64_bit = [Environment]::Is64BitProcess
    }
    foreach ($path in @($runnerStatusPath, $lastRunnerStatusPath)) {
        $temporary = "$path.$PID.tmp"
        [IO.File]::WriteAllText(
            $temporary,
            ($status | ConvertTo-Json -Depth 5) + "`r`n",
            (New-Object Text.UTF8Encoding($false))
        )
        Move-Item -LiteralPath $temporary -Destination $path -Force
    }
}

try {
    New-Item -ItemType Directory -Path $InstallerLogRoot -Force | Out-Null
    Start-Transcript -LiteralPath $runnerLogPath -Force | Out-Null
    $transcriptStarted = $true
    Write-Host "[runner] Persistent elevated-runner log: $runnerLogPath"
    Write-RunnerStatus -Outcome 'running'

    $stage = 'validate installer inputs'
    Write-RunnerStatus -Outcome 'running'
    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
        throw "Validated installer does not exist: $InstallerPath"
    }
    if (-not (Test-Path -LiteralPath $ConfigurationSourceRoot -PathType Container)) {
        throw "Validated configuration source does not exist: $ConfigurationSourceRoot"
    }

    $stage = 'invoke validated installer'
    Write-RunnerStatus -Outcome 'running'
    $installerParameters = @{
        ConfigurationSourceRoot = $ConfigurationSourceRoot
        TruckHost = $TruckHost
        RailfanHost = $RailfanHost
        InstallerLogRoot = $InstallerLogRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        $installerParameters.InstallRoot = $InstallRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($DesktopPath)) {
        $installerParameters.DesktopPath = $DesktopPath
    }
    if ($NoDesktopShortcut) {
        $installerParameters.NoDesktopShortcut = $true
    }
    if ($NoLaunch) {
        $installerParameters.NoLaunch = $true
    }

    & $InstallerPath @installerParameters

    $stage = 'complete'
    Write-RunnerStatus -Outcome 'success'
    Write-Host '[runner complete] Validated installer returned successfully.'
    $exitCode = 0
} catch {
    $message = $_.Exception.Message
    try {
        Write-RunnerStatus -Outcome 'failed' -ErrorMessage $message
    } catch {
        Write-Host "[runner failed] Status-file write also failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ''
    Write-Host '========== ELEVATED INSTALLER FAILED ==========' -ForegroundColor Red
    Write-Host "Stage: $stage" -ForegroundColor Red
    Write-Host "Error: $message" -ForegroundColor Red
    Write-Host "Runner log: $runnerLogPath" -ForegroundColor Yellow
    Write-Host "Runner status: $lastRunnerStatusPath" -ForegroundColor Yellow
    Write-Host '===============================================' -ForegroundColor Red
    $pauseRequired = (-not $NoPause -and [Environment]::UserInteractive)
    $exitCode = 1
} finally {
    if ($transcriptStarted) {
        try {
            Stop-Transcript | Out-Null
        } catch {
            # Preserve the primary runner result.
        }
    }
}

if ($pauseRequired) {
    Write-Host ''
    [void](Read-Host 'The elevated installer failed. Press Enter to close this window')
}
exit $exitCode
