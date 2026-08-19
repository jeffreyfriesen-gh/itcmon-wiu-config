[CmdletBinding()]
param(
    [string]$Repository = 'jeffreyfriesen-gh/itcmon-wiu-config',

    [string]$Ref = 'main',

    [string]$InstallRoot,

    [string]$DesktopPath,

    [string]$TruckHost = 'telemetry-node.lan',

    [string]$RailfanHost = 'railfan-01',

    [string]$LogRoot,

    [string]$PowerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe",

    [switch]$NoDesktopShortcut,

    [switch]$NoLaunch,

    [switch]$SkipElevation,

    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$startedAt = (Get-Date).ToUniversalTime()
$runId = $startedAt.ToString('yyyyMMddTHHmmssZ') + "-pid$PID"
$exitCode = 1
$pauseRequired = $false
$transcriptStarted = $false
$currentStage = 'initialize diagnostics'
$manifestVersion = $null
$resolvedCommit = $null
$installerLogPath = $null
$runnerLogPath = $null
$failureMessage = $null
$workRoot = Join-Path $env:TEMP "itcm-client-bootstrap-$runId"

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

    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        try {
            New-Item -ItemType Directory -Path $candidate -Force | Out-Null
            return [IO.Path]::GetFullPath($candidate)
        } catch {
            $failures.Add("$candidate : $($_.Exception.Message)")
        }
    }
    throw "No writable bootstrap log directory was available. $($failures -join ' | ')"
}

try {
    $LogRoot = Resolve-LogRoot -Requested $LogRoot
} catch {
    Write-Host '[bootstrap failed] Diagnostics could not be initialized.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    if (-not $NoPause -and [Environment]::UserInteractive) {
        [void](Read-Host 'Press Enter to close')
    }
    exit 1
}

$bootstrapLogPath = Join-Path $LogRoot "bootstrap-$runId.log"
$runStatusPath = Join-Path $LogRoot "bootstrap-$runId.status.json"
$lastStatusPath = Join-Path $LogRoot 'last-bootstrap-status.json'

function Write-StatusFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)

    $temporary = "$Path.$PID.tmp"
    [IO.File]::WriteAllText(
        $temporary,
        ($Value | ConvertTo-Json -Depth 7) + "`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-BootstrapStatus {
    param(
        [Parameter(Mandatory)][string]$Outcome,
        [string]$ErrorMessage,
        [Nullable[int]]$ChildExitCode
    )

    $status = [pscustomobject][ordered]@{
        schema = 'itcm.client.bootstrap.status.v1'
        run_id = $runId
        started_at = $startedAt.ToString('o')
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
        outcome = $Outcome
        stage = $currentStage
        error = $ErrorMessage
        child_exit_code = $ChildExitCode
        repository = $Repository
        requested_ref = $Ref
        resolved_commit = $resolvedCommit
        manifest_version = $manifestVersion
        bootstrap_log = $bootstrapLogPath
        runner_log = $runnerLogPath
        installer_log = $installerLogPath
        work_root = $workRoot
        install_root = $InstallRoot
        powershell = $PowerShellPath
        powershell_version = $PSVersionTable.PSVersion.ToString()
        process_is_64_bit = [Environment]::Is64BitProcess
        user_interactive = [Environment]::UserInteractive
        elevation_requested = (-not $SkipElevation)
    }
    Write-StatusFile -Path $runStatusPath -Value $status
    Write-StatusFile -Path $lastStatusPath -Value $status
}

function Set-BootstrapStage {
    param([Parameter(Mandatory)][string]$Stage)
    $script:currentStage = $Stage
    Write-Host "[bootstrap] $Stage"
    Write-BootstrapStatus -Outcome 'running'
}

function Save-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Description
    )

    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source --fail --location --retry 4 --retry-delay 2 `
            --connect-timeout 20 --max-time 180 --output $Destination $Uri
        if ($LASTEXITCODE -ne 0) {
            throw "$Description download failed with curl exit $LASTEXITCODE from $Uri"
        }
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 180 -Uri $Uri -OutFile $Destination
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf) -or
        (Get-Item -LiteralPath $Destination).Length -le 0) {
        throw "$Description download produced no usable file: $Destination"
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF) | ConvertFrom-Json
}

function Test-TcpEndpoint {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMilliseconds = 5000
    )

    $client = New-Object Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            throw "Timed out after $TimeoutMilliseconds ms"
        }
        $client.EndConnect($pending)
    } finally {
        $client.Dispose()
    }
}

function Quote-ProcessArgument {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value.Contains('"')) {
        throw 'A process argument contains an unsupported double-quote character.'
    }
    return '"' + $Value + '"'
}

function Get-LatestLog {
    param([Parameter(Mandatory)][string]$Filter)
    $logs = @(Get-ChildItem -LiteralPath $LogRoot -File -Filter $Filter `
        -ErrorAction SilentlyContinue | Where-Object {
            $_.LastWriteTimeUtc -ge $startedAt.AddMinutes(-1)
        } | Sort-Object LastWriteTimeUtc -Descending)
    if ($logs.Count -gt 0) {
        return $logs[0].FullName
    }
    return $null
}

try {
    Start-Transcript -LiteralPath $bootstrapLogPath -Force | Out-Null
    $transcriptStarted = $true
    Write-Host "[bootstrap] Persistent log: $bootstrapLogPath"
    Write-BootstrapStatus -Outcome 'running'

    if (Test-Path -LiteralPath $workRoot) {
        throw "Refusing to replace unexpected bootstrap work directory: $workRoot"
    }
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

    Set-BootstrapStage -Stage 'resolve the requested GitHub ref to an immutable commit'
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw "Unsupported GitHub repository identifier: $Repository"
    }
    $escapedRef = [Uri]::EscapeDataString($Ref)
    $commitApi = "https://api.github.com/repos/$Repository/commits/$escapedRef"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $commit = Invoke-RestMethod -UseBasicParsing -TimeoutSec 60 -Headers @{
        'User-Agent' = 'ITCM-Client-Bootstrap'
        'Accept' = 'application/vnd.github+json'
    } -Uri $commitApi
    $resolvedCommit = [string]$commit.sha
    if ($resolvedCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "GitHub returned an invalid commit for $Repository ref $Ref"
    }
    Write-Host "[bootstrap] Resolved $Ref to $resolvedCommit"
    Write-BootstrapStatus -Outcome 'running'

    Set-BootstrapStage -Stage 'download the immutable GitHub configuration archive'
    $archivePath = Join-Path $workRoot 'configuration.zip'
    $archiveUrl = "https://github.com/$Repository/archive/$resolvedCommit.zip"
    Save-RemoteFile -Uri $archiveUrl -Destination $archivePath `
        -Description 'Immutable configuration archive'

    Set-BootstrapStage -Stage 'extract and validate every manifest-managed file'
    $extractRoot = Join-Path $workRoot 'configuration'
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
    $roots = @(Get-ChildItem -LiteralPath $extractRoot -Directory)
    if ($roots.Count -ne 1) {
        throw "GitHub archive contained $($roots.Count) roots; expected one."
    }
    $repositoryRoot = $roots[0].FullName
    $manifestPath = Join-Path $repositoryRoot 'manifest.json'
    $manifest = Read-JsonFile -Path $manifestPath
    if ($manifest.schema -ne 'itcmon.config.manifest.v1') {
        throw "Unsupported manifest schema: $($manifest.schema)"
    }
    $manifestVersion = [string]$manifest.version
    $repositoryPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
    $managedFiles = @($manifest.files)
    if ($managedFiles.Count -lt 1) {
        throw 'Configuration manifest contains no managed files.'
    }
    foreach ($entry in $managedFiles) {
        $relative = [string]$entry.path
        $expected = ([string]$entry.sha256).ToUpperInvariant()
        $full = [IO.Path]::GetFullPath((Join-Path $repositoryRoot ($relative -replace '/', '\')))
        if (-not $full.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Managed path leaves the configuration root: $relative"
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Managed file is missing from the GitHub archive: $relative"
        }
        $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
        if ($actual -ne $expected) {
            throw "Managed file SHA-256 mismatch for $relative. Expected $expected; received $actual."
        }
    }
    Write-Host "[bootstrap] Manifest $manifestVersion validated $($managedFiles.Count) files."
    Write-BootstrapStatus -Outcome 'running'

    $installerEntries = @($managedFiles | Where-Object path -eq 'scripts/Install-ITCMon-Truck-Client.ps1')
    if ($installerEntries.Count -ne 1) {
        throw 'Manifest has no unique installer entry.'
    }
    $installerPath = Join-Path $repositoryRoot 'scripts\Install-ITCMon-Truck-Client.ps1'
    $parseTokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $installerPath,
        [ref]$parseTokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -ne 0) {
        $detail = ($parseErrors | ForEach-Object { $_.Message }) -join ' | '
        throw "Installer PowerShell parse failed: $detail"
    }
    $runnerEntries = @($managedFiles | Where-Object path -eq 'scripts/Invoke-ITCM-ElevatedInstaller.ps1')
    if ($runnerEntries.Count -ne 1) {
        throw 'Manifest has no unique elevated-runner entry.'
    }
    $runnerPath = Join-Path $repositoryRoot 'scripts\Invoke-ITCM-ElevatedInstaller.ps1'
    $parseTokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $runnerPath,
        [ref]$parseTokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -ne 0) {
        $detail = ($parseErrors | ForEach-Object { $_.Message }) -join ' | '
        throw "Elevated-runner PowerShell parse failed: $detail"
    }

    Set-BootstrapStage -Stage 'preflight the internal application artifact host'
    $applicationHosts = @($manifest.applications | ForEach-Object {
        ([Uri][string]$_.url).DnsSafeHost
    } | Select-Object -Unique)
    if ($applicationHosts.Count -ne 1) {
        throw "Manifest applications use $($applicationHosts.Count) distinct hosts; expected one."
    }
    $artifactHost = $applicationHosts[0]
    $addresses = @([Net.Dns]::GetHostAddresses($artifactHost) | ForEach-Object IPAddressToString)
    if ($addresses.Count -lt 1) {
        throw "No address resolved for application artifact host $artifactHost"
    }
    Test-TcpEndpoint -HostName $artifactHost -Port 8080
    Write-Host "[bootstrap] $artifactHost resolves to $($addresses -join ', ') and accepts TCP 8080."

    Set-BootstrapStage -Stage 'launch the validated installer with persistent failure diagnostics'
    if (-not (Test-Path -LiteralPath $PowerShellPath -PathType Leaf)) {
        throw "PowerShell executable does not exist: $PowerShellPath"
    }
    $installerArguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($value in @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Quote-ProcessArgument -Value $runnerPath),
        '-InstallerPath', (Quote-ProcessArgument -Value $installerPath),
        '-ConfigurationSourceRoot', (Quote-ProcessArgument -Value $repositoryRoot),
        '-TruckHost', (Quote-ProcessArgument -Value $TruckHost),
        '-RailfanHost', (Quote-ProcessArgument -Value $RailfanHost),
        '-InstallerLogRoot', (Quote-ProcessArgument -Value $LogRoot)
    )) {
        $installerArguments.Add($value)
    }
    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        $installerArguments.Add('-InstallRoot')
        $installerArguments.Add((Quote-ProcessArgument -Value $InstallRoot))
    }
    if (-not [string]::IsNullOrWhiteSpace($DesktopPath)) {
        $installerArguments.Add('-DesktopPath')
        $installerArguments.Add((Quote-ProcessArgument -Value $DesktopPath))
    }
    if ($NoDesktopShortcut) {
        $installerArguments.Add('-NoDesktopShortcut')
    }
    if ($NoLaunch) {
        $installerArguments.Add('-NoLaunch')
    }
    if ($NoPause) {
        $installerArguments.Add('-NoPause')
    }

    $startParameters = @{
        FilePath = $PowerShellPath
        ArgumentList = ($installerArguments -join ' ')
        Wait = $true
        PassThru = $true
        ErrorAction = 'Stop'
    }
    if (-not $SkipElevation) {
        $startParameters.Verb = 'RunAs'
    }
    $child = Start-Process @startParameters
    $childExitCode = [int]$child.ExitCode
    $runnerLogPath = Get-LatestLog -Filter 'runner-*.log'
    $installerLogPath = Get-LatestLog -Filter 'install-*.log'
    if ($childExitCode -ne 0) {
        $runnerFailure = $null
        $lastRunnerStatus = Join-Path $LogRoot 'last-runner-status.json'
        if (Test-Path -LiteralPath $lastRunnerStatus -PathType Leaf) {
            try {
                $runnerFailure = Read-JsonFile -Path $lastRunnerStatus
            } catch {
                Write-Host "[bootstrap warning] Runner status could not be read: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        if ($runnerLogPath) {
            Write-Host "[bootstrap failed] Elevated-runner log: $runnerLogPath" -ForegroundColor Red
            Write-Host '----- elevated-runner log tail -----' -ForegroundColor Yellow
            Get-Content -LiteralPath $runnerLogPath -Tail 160
            Write-Host '----- end elevated-runner log tail -----' -ForegroundColor Yellow
        }
        if ($installerLogPath) {
            Write-Host "[bootstrap failed] Installer log: $installerLogPath" -ForegroundColor Red
            Write-Host '----- installer log tail -----' -ForegroundColor Yellow
            Get-Content -LiteralPath $installerLogPath -Tail 120
            Write-Host '----- end installer log tail -----' -ForegroundColor Yellow
        }
        if ($runnerFailure -and -not [string]::IsNullOrWhiteSpace([string]$runnerFailure.error)) {
            throw "Elevated runner failed during '$($runnerFailure.stage)': $($runnerFailure.error) (exit $childExitCode)."
        }
        throw "Validated elevated runner exited with code $childExitCode without a readable root-error status."
    }

    $currentStage = 'complete'
    Write-BootstrapStatus -Outcome 'success' -ChildExitCode $childExitCode
    Write-Host "[bootstrap complete] Manifest $manifestVersion installed successfully."
    Write-Host "[bootstrap complete] Status: $lastStatusPath"
    Write-Host "[bootstrap complete] Bootstrap log: $bootstrapLogPath"
    if ($installerLogPath) {
        Write-Host "[bootstrap complete] Installer log: $installerLogPath"
    }
    $exitCode = 0
} catch {
    $failureMessage = $_.Exception.Message
    $runnerLogPath = Get-LatestLog -Filter 'runner-*.log'
    $installerLogPath = Get-LatestLog -Filter 'install-*.log'
    try {
        Write-BootstrapStatus -Outcome 'failed' -ErrorMessage $failureMessage
    } catch {
        Write-Host "[bootstrap failed] Status-file write also failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ''
    Write-Host '========== ITCM CLIENT INSTALLATION FAILED ==========' -ForegroundColor Red
    Write-Host "Stage: $currentStage" -ForegroundColor Red
    Write-Host "Error: $failureMessage" -ForegroundColor Red
    Write-Host "Bootstrap log: $bootstrapLogPath" -ForegroundColor Yellow
    Write-Host "Status file: $lastStatusPath" -ForegroundColor Yellow
    if ($runnerLogPath) {
        Write-Host "Elevated-runner log: $runnerLogPath" -ForegroundColor Yellow
    }
    if ($installerLogPath) {
        Write-Host "Installer log: $installerLogPath" -ForegroundColor Yellow
    }
    Write-Host "Retained diagnostic work directory: $workRoot" -ForegroundColor Yellow
    Write-Host '=====================================================' -ForegroundColor Red
    $pauseRequired = (-not $NoPause -and [Environment]::UserInteractive)
    $exitCode = 1
} finally {
    if ($exitCode -eq 0 -and (Test-Path -LiteralPath $workRoot)) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
    if ($transcriptStarted) {
        try {
            Stop-Transcript | Out-Null
        } catch {
            # Preserve the primary bootstrap result.
        }
    }
}

if ($pauseRequired) {
    Write-Host ''
    [void](Read-Host 'The installer failed. Press Enter to close this window')
}
exit $exitCode
