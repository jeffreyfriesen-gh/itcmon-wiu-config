[CmdletBinding()]
param(
    [string]$Repository = 'jeffreyfriesen-gh/itcmon-wiu-config',
    [string]$Ref = 'main',
    [string]$InstallRoot,
    [string]$DesktopPath,
    [string]$TruckHost = 'telemetry-node.lan',
    [string]$RailfanHost = 'railfan-01',
    [string]$LogRoot,
    [switch]$NoDesktopShortcut,
    [switch]$NoLaunch,
    [switch]$SkipElevation,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$startedAt = (Get-Date).ToUniversalTime()
$runId = $startedAt.ToString('yyyyMMddTHHmmssZ') + "-pid$PID"
$stage = 'initialize diagnostics'
$failed = $false
$failureMessage = $null
$transcriptStarted = $false
$resolvedCommit = $null
$childExitCode = $null
$workRoot = Join-Path $env:TEMP "itc-truck-mon-$runId"

function Resolve-LogRoot {
    param([string]$Requested)

    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $candidates.Add($Requested)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'ITCMon\InstallerLogs'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        $candidates.Add((Join-Path $env:TEMP 'ITCMon-InstallerLogs'))
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        try {
            New-Item -ItemType Directory -Path $candidate -Force | Out-Null
            return [IO.Path]::GetFullPath($candidate)
        } catch {
            Write-Warning "Cannot use installer log directory $candidate : $($_.Exception.Message)"
        }
    }
    throw 'No writable installer log directory is available.'
}

$LogRoot = Resolve-LogRoot -Requested $LogRoot
$logPath = Join-Path $LogRoot "itc-truck-mon-$runId.log"
$statusPath = Join-Path $LogRoot 'last-itc-truck-mon-status.json'

function Write-LauncherStatus {
    param(
        [Parameter(Mandatory)][string]$Outcome,
        [string]$ErrorMessage
    )

    $status = [pscustomobject][ordered]@{
        schema = 'itcm.truck.net-new-launcher.status.v1'
        run_id = $runId
        started_at = $startedAt.ToString('o')
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
        outcome = $Outcome
        stage = $stage
        error = $ErrorMessage
        child_exit_code = $childExitCode
        repository = $Repository
        requested_ref = $Ref
        resolved_commit = $resolvedCommit
        log = $logPath
        work_root = $workRoot
    }
    $temporary = "$statusPath.$PID.tmp"
    [IO.File]::WriteAllText(
        $temporary,
        ($status | ConvertTo-Json -Depth 5) + "`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    Move-Item -LiteralPath $temporary -Destination $statusPath -Force
}

function Set-LauncherStage {
    param([Parameter(Mandatory)][string]$Name)
    $script:stage = $Name
    Write-Host "[itc-truck-mon] $Name"
    Write-LauncherStatus -Outcome 'running'
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF) | ConvertFrom-Json
}

function Save-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination
    )

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source --fail --location --retry 4 --retry-delay 2 `
            --connect-timeout 20 --max-time 240 --output $Destination $Uri
        if ($LASTEXITCODE -ne 0) {
            throw "Download failed with curl exit $LASTEXITCODE from $Uri"
        }
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 240 -Uri $Uri -OutFile $Destination
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf) -or
        (Get-Item -LiteralPath $Destination).Length -le 0) {
        throw "Download produced no usable file: $Destination"
    }
}

function Add-OptionalArgument {
    param(
        [Parameter(Mandatory)]$List,
        [Parameter(Mandatory)][string]$Name,
        [string]$Value
    )
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $List.Add($Name)
        $List.Add($Value)
    }
}

try {
    Start-Transcript -LiteralPath $logPath -Force | Out-Null
    $transcriptStarted = $true
    Write-Host "[itc-truck-mon] Persistent log: $logPath"
    Write-LauncherStatus -Outcome 'running'

    Set-LauncherStage -Name 'resolve GitHub source to an immutable commit'
    $headers = @{
        'User-Agent' = 'ITCM-Truck-Net-New-Installer'
        'Accept' = 'application/vnd.github+json'
    }
    $commitResponse = Invoke-RestMethod -UseBasicParsing -TimeoutSec 60 `
        -Headers $headers -Uri "https://api.github.com/repos/$Repository/commits/$Ref"
    $resolvedCommit = [string]$commitResponse.sha
    if ($resolvedCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "GitHub returned an invalid commit identifier: $resolvedCommit"
    }
    Write-LauncherStatus -Outcome 'running'

    Set-LauncherStage -Name 'download the immutable installer bundle'
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    $archivePath = "$workRoot.zip"
    Save-RemoteFile -Uri "https://github.com/$Repository/archive/$resolvedCommit.zip" `
        -Destination $archivePath

    Set-LauncherStage -Name 'validate the installer before execution'
    Expand-Archive -LiteralPath $archivePath -DestinationPath $workRoot -Force
    $roots = @(Get-ChildItem -LiteralPath $workRoot -Directory)
    if ($roots.Count -ne 1) {
        throw "The GitHub archive contained $($roots.Count) roots; expected one."
    }
    $repositoryRoot = $roots[0].FullName
    $manifest = Read-JsonFile -Path (Join-Path $repositoryRoot 'manifest.json')
    if ($manifest.schema -ne 'itcmon.config.manifest.v1') {
        throw "Unsupported manifest schema: $($manifest.schema)"
    }
    $bootstrapEntry = @($manifest.files | Where-Object path -eq 'scripts/Bootstrap-ITCM-Truck-Client.ps1')
    if ($bootstrapEntry.Count -ne 1) {
        throw 'The manifest has no unique bootstrap entry.'
    }
    $bootstrapPath = Join-Path $repositoryRoot 'scripts\Bootstrap-ITCM-Truck-Client.ps1'
    $bootstrapHash = (Get-FileHash -LiteralPath $bootstrapPath -Algorithm SHA256).Hash
    if ($bootstrapHash -ne ([string]$bootstrapEntry[0].sha256).ToUpperInvariant()) {
        throw "Bootstrap SHA-256 mismatch: expected $($bootstrapEntry[0].sha256); received $bootstrapHash"
    }
    $parseTokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $bootstrapPath,
        [ref]$parseTokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -ne 0) {
        throw "Bootstrap PowerShell parse failed: $(($parseErrors.Message) -join ' | ')"
    }

    Set-LauncherStage -Name 'run the validated installer in this console'
    $arguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($argument in @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $bootstrapPath,
        '-Repository', $Repository,
        '-Ref', $resolvedCommit,
        '-TruckHost', $TruckHost,
        '-RailfanHost', $RailfanHost,
        '-LogRoot', $LogRoot,
        '-NoPause'
    )) {
        $arguments.Add($argument)
    }
    Add-OptionalArgument -List $arguments -Name '-InstallRoot' -Value $InstallRoot
    Add-OptionalArgument -List $arguments -Name '-DesktopPath' -Value $DesktopPath
    if ($NoDesktopShortcut) { $arguments.Add('-NoDesktopShortcut') }
    if ($NoLaunch) { $arguments.Add('-NoLaunch') }
    if ($SkipElevation) { $arguments.Add('-SkipElevation') }

    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @arguments
    $childExitCode = $LASTEXITCODE
    if ($childExitCode -ne 0) {
        throw "The validated installer failed with exit code $childExitCode."
    }

    $stage = 'complete'
    Write-LauncherStatus -Outcome 'success'
    Write-Host "[itc-truck-mon complete] Manifest $($manifest.version) installed successfully." -ForegroundColor Green
    Write-Host "[itc-truck-mon complete] Status: $statusPath"
} catch {
    $failed = $true
    $failureMessage = $_.Exception.Message
    try {
        Write-LauncherStatus -Outcome 'failed' -ErrorMessage $failureMessage
    } catch {
        Write-Warning "Status-file write failed: $($_.Exception.Message)"
    }
    Write-Host ''
    Write-Host '========== ITC TRUCK CLIENT INSTALLATION FAILED ==========' -ForegroundColor Red
    Write-Host "Stage: $stage" -ForegroundColor Red
    Write-Host "Error: $failureMessage" -ForegroundColor Red
    Write-Host "Log: $logPath" -ForegroundColor Yellow
    Write-Host "Status: $statusPath" -ForegroundColor Yellow
    $latestLogs = @(Get-ChildItem -LiteralPath $LogRoot -File -ErrorAction SilentlyContinue |
        Where-Object Name -Match '^(bootstrap|runner|install)-.*\.log$' |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 3)
    foreach ($latest in $latestLogs) {
        Write-Host "----- $($latest.FullName) -----" -ForegroundColor Yellow
        Get-Content -LiteralPath $latest.FullName -Tail 80
    }
    Write-Host '==========================================================' -ForegroundColor Red
} finally {
    if (-not $failed) {
        if (Test-Path -LiteralPath $workRoot) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force
        }
        if (Test-Path -LiteralPath "$workRoot.zip") {
            Remove-Item -LiteralPath "$workRoot.zip" -Force
        }
    }
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

if ($failed) {
    if (-not $NoPause -and [Environment]::UserInteractive) {
        [void](Read-Host 'Installation failed. Press Enter to return to PowerShell')
    }
    throw "ITC truck client installation failed during '$stage'. See $logPath"
}
