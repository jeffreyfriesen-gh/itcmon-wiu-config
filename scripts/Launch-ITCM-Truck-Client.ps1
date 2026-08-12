[CmdletBinding()]
param(
    [ValidateSet('ITCMon', 'ITCWatch')]
    [string]$LaunchTarget = 'ITCMon',

    [string]$InstallRoot = $PSScriptRoot,

    [string]$ProfileName = 'truck-client',

    [string]$TruckHost = 'telemetry-node.lan',

    [string]$RepositoryUrl = 'https://github.com/jeffreyfriesen-gh/itcmon-wiu-config.git',

    [string]$Branch = 'main',

    [string]$UpdateSourceRoot,

    [string]$StateRoot,

    [switch]$NoUpdate,

    [switch]$DiagnoseOnly,

    [switch]$NoUserInterface,

    [switch]$NoApplicationLaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$installFull = [IO.Path]::GetFullPath($InstallRoot).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)
$localStateRoot = if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
    [IO.Path]::GetFullPath($StateRoot)
} elseif ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    Join-Path $installFull 'client-state'
} else {
    Join-Path $env:LOCALAPPDATA 'ITCMon'
}
$logRoot = Join-Path $localStateRoot 'Logs'
$statusPath = Join-Path $localStateRoot 'last-launch-status.json'
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$logPath = Join-Path $logRoot "truck-client-$stamp-$PID.log"
$updateAttempted = $false
$updateSucceeded = $false
$usedLastKnownGood = $false
$updateError = $null
$startedProcesses = @()
$alreadyRunning = @()
$diagnostics = $null
$health = $null
$finalState = 'starting'
$finalError = $null

try {
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
} catch {
    $localStateRoot = Join-Path $installFull 'client-state'
    $logRoot = Join-Path $localStateRoot 'Logs'
    $statusPath = Join-Path $localStateRoot 'last-launch-status.json'
    $logPath = Join-Path $logRoot "truck-client-$stamp-$PID.log"
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
}

function Write-LaunchLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = '[{0}] [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff zzz'), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = Join-Path $parent ".$(Split-Path -Leaf $Path).$PID.tmp"
    [IO.File]::WriteAllText(
        $temporary,
        ($Value | ConvertTo-Json -Depth 8) + "`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)

    return [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF) | ConvertFrom-Json
}

function Test-TcpEndpoint {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMilliseconds = 1000
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

function Get-ClientProcesses {
    param(
        [Parameter(Mandatory)][ValidateSet('itcmon', 'itcwatch')]
        [string]$Name
    )

    $expectedPath = Join-Path $installFull "$Name.exe"
    return @(
        Get-Process -Name $Name -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    [string]::Equals($_.Path, $expectedPath, [StringComparison]::OrdinalIgnoreCase)
                } catch {
                    # A same-session process can occasionally deny its Path property.
                    # Keep it in the safety check rather than risking an in-use update.
                    $true
                }
            }
    )
}

function Get-InstalledClientHealth {
    $issues = New-Object 'System.Collections.Generic.List[string]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $itcmonPath = Join-Path $installFull 'itcmon.exe'
    $itcwatchPath = Join-Path $installFull 'itcwatch.exe'
    $profilePath = Join-Path $installFull 'itcmon.json'
    $rrdataPath = Join-Path $installFull 'rrdata.json'
    $wiuRoot = Join-Path $installFull 'wius'
    $serverCount = 0
    $enabledServerCount = 0
    $wiuCount = 0
    $configuredHosts = @()

    foreach ($application in @($itcmonPath, $itcwatchPath)) {
        if (-not (Test-Path -LiteralPath $application -PathType Leaf)) {
            $issues.Add("Missing application: $application")
            continue
        }
        $item = Get-Item -LiteralPath $application
        if ($item.Length -lt 2) {
            $issues.Add("Application is empty: $application")
            continue
        }
        $stream = [IO.File]::OpenRead($application)
        try {
            if ($stream.ReadByte() -ne 0x4D -or $stream.ReadByte() -ne 0x5A) {
                $issues.Add("Application is not a Windows PE executable: $application")
            }
        } finally {
            $stream.Dispose()
        }
    }

    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        $issues.Add("Missing ITCMon server profile: $profilePath")
    } else {
        try {
            $profile = Read-JsonFile -Path $profilePath
            $servers = @($profile.servers)
            $serverCount = $servers.Count
            $enabledServerCount = @($servers | Where-Object enabled).Count
            $configuredHosts = @($servers.ip | Sort-Object -Unique)
            if ($serverCount -ne 52 -or $enabledServerCount -ne 52) {
                $issues.Add("Server profile has $serverCount servers and $enabledServerCount enabled; expected 52/52.")
            }
            if ($configuredHosts.Count -ne 1 -or $configuredHosts[0] -ne $TruckHost) {
                $issues.Add("Server profile does not point only to $TruckHost.")
            }
        } catch {
            $issues.Add("Server profile is unreadable: $($_.Exception.Message)")
        }
    }

    if (-not (Test-Path -LiteralPath $rrdataPath -PathType Leaf)) {
        $issues.Add("Missing railroad data: $rrdataPath")
    } else {
        try {
            $rrdata = Read-JsonFile -Path $rrdataPath
            if (@($rrdata.mappings).Count -eq 0) {
                $issues.Add('Railroad data contains no mappings.')
            }
        } catch {
            $issues.Add("Railroad data is unreadable: $($_.Exception.Message)")
        }
    }

    if (-not (Test-Path -LiteralPath $wiuRoot -PathType Container)) {
        $issues.Add("Missing WIU directory: $wiuRoot")
    } else {
        $wiuIDs = New-Object 'System.Collections.Generic.HashSet[string]'
        try {
            foreach ($file in @(Get-ChildItem -LiteralPath $wiuRoot -Filter '*.json' -File -Recurse)) {
                $wiu = Read-JsonFile -Path $file.FullName
                foreach ($property in @($wiu.waysides.PSObject.Properties)) {
                    if (-not $wiuIDs.Add([string]$property.Name)) {
                        $issues.Add("Duplicate WIU ID $($property.Name) in $($file.FullName)")
                    }
                }
            }
            $wiuCount = $wiuIDs.Count
            if ($wiuCount -ne 52) {
                $issues.Add("Installed WIU inventory has $wiuCount IDs; expected 52.")
            }
        } catch {
            $issues.Add("WIU inventory is unreadable: $($_.Exception.Message)")
        }
    }

    try {
        $addresses = @([Net.Dns]::GetHostAddresses($TruckHost) | ForEach-Object IPAddressToString)
        if ($addresses.Count -eq 0) {
            $warnings.Add("$TruckHost resolved to no addresses.")
        }
    } catch {
        $addresses = @()
        $warnings.Add("DNS lookup for $TruckHost failed: $($_.Exception.Message)")
    }

    return [pscustomobject][ordered]@{
        healthy = ($issues.Count -eq 0)
        issues = @($issues)
        warnings = @($warnings)
        install_root = $installFull
        servers = $serverCount
        enabled_servers = $enabledServerCount
        configured_hosts = @($configuredHosts)
        wius = $wiuCount
        resolved_addresses = @($addresses)
    }
}

function Get-ClientDiagnostics {
    $itcmon = @(Get-ClientProcesses -Name itcmon)
    $itcwatch = @(Get-ClientProcesses -Name itcwatch)
    return [pscustomobject][ordered]@{
        observed_at = (Get-Date).ToUniversalTime().ToString('o')
        computer = $env:COMPUTERNAME
        user = [Environment]::UserName
        powershell = $PSVersionTable.PSVersion.ToString()
        os = [Environment]::OSVersion.VersionString
        itcmon_processes = @($itcmon | ForEach-Object {
            [pscustomobject]@{ id = $_.Id; started = $_.StartTime; main_window = $_.MainWindowTitle }
        })
        itcwatch_processes = @($itcwatch | ForEach-Object {
            [pscustomobject]@{ id = $_.Id; started = $_.StartTime; main_window = $_.MainWindowTitle }
        })
        endpoints = [ordered]@{
            zjpub_18001 = Test-TcpEndpoint -HostName $TruckHost -Port 18001
            fr_18101 = Test-TcpEndpoint -HostName $TruckHost -Port 18101
            hr_20101 = Test-TcpEndpoint -HostName $TruckHost -Port 20101
        }
    }
}

function Start-ClientProcess {
    param(
        [Parameter(Mandatory)][ValidateSet('itcmon', 'itcwatch')]
        [string]$Name
    )

    $existing = @(Get-ClientProcesses -Name $Name)
    if ($existing.Count -gt 0) {
        $script:alreadyRunning += $Name
        Write-LaunchLog "$Name is already running with process ID(s) $($existing.Id -join ', ')."
        return $existing
    }

    $executable = Join-Path $installFull "$Name.exe"
    Write-LaunchLog "Starting $executable."
    Start-Process -FilePath $executable -WorkingDirectory $installFull
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 500
        $running = @(Get-ClientProcesses -Name $Name)
        if ($running.Count -gt 0) {
            $script:startedProcesses += $Name
            Write-LaunchLog "$Name started with process ID(s) $($running.Id -join ', ')."
            return $running
        }
    } while ((Get-Date) -lt $deadline)
    throw "$Name did not remain running within 15 seconds of launch."
}

function Show-Notice {
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Title = 'ITCM Truck Client',
        [switch]$ErrorNotice
    )

    if ($NoUserInterface) {
        return
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $icon = if ($ErrorNotice) {
            [Windows.Forms.MessageBoxIcon]::Error
        } else {
            [Windows.Forms.MessageBoxIcon]::Information
        }
        [void][Windows.Forms.MessageBox]::Show(
            $Text,
            $Title,
            [Windows.Forms.MessageBoxButtons]::OK,
            $icon
        )
    } catch {
        # Console and persistent log remain the fallback notification path.
    }
}

function Write-FinalStatus {
    $value = [pscustomobject][ordered]@{
        schema = 'itcmon.truck-client.launch-status.v1'
        observed_at = (Get-Date).ToUniversalTime().ToString('o')
        state = $script:finalState
        target = $LaunchTarget
        install_root = $installFull
        log = $logPath
        update_attempted = $script:updateAttempted
        update_succeeded = $script:updateSucceeded
        used_last_known_good = $script:usedLastKnownGood
        update_error = $script:updateError
        started = @($script:startedProcesses)
        already_running = @($script:alreadyRunning)
        health = $script:health
        diagnostics = $script:diagnostics
        error = $script:finalError
    }
    Write-JsonFile -Path $statusPath -Value $value
}

try {
    Write-LaunchLog "Truck client launcher started. Target=$LaunchTarget InstallRoot=$installFull"
    Write-LaunchLog "Persistent log: $logPath"

    if (-not (Test-Path -LiteralPath $installFull -PathType Container)) {
        throw "ITCM installation directory does not exist: $installFull"
    }

    $health = Get-InstalledClientHealth
    foreach ($warning in @($health.warnings)) {
        Write-LaunchLog $warning 'WARN'
    }
    foreach ($issue in @($health.issues)) {
        Write-LaunchLog $issue 'ERROR'
    }
    $diagnostics = Get-ClientDiagnostics
    Write-LaunchLog ("Processes before launch: ITCMon={0}, ITCWatch={1}. Endpoints 18001/18101/20101={2}/{3}/{4}." -f `
        @($diagnostics.itcmon_processes).Count,
        @($diagnostics.itcwatch_processes).Count,
        $diagnostics.endpoints.zjpub_18001,
        $diagnostics.endpoints.fr_18101,
        $diagnostics.endpoints.hr_20101)

    if ($DiagnoseOnly) {
        $finalState = if ($health.healthy) { 'diagnostics-complete' } else { 'invalid-installation' }
        if (-not $health.healthy) {
            throw 'Installed client health validation failed. Review the reported issues.'
        }
        Write-LaunchLog 'Diagnostics completed. The installed files are valid; endpoint failures only mean the truck service is not currently reachable.'
        Write-FinalStatus
        exit 0
    }

    $stackRunning = @($diagnostics.itcmon_processes).Count -gt 0 -or
        @($diagnostics.itcwatch_processes).Count -gt 0
    if ($stackRunning) {
        Write-LaunchLog 'An ITCMon/ITCWatch process is already active; skipping updates so running files are not replaced.' 'WARN'
    } elseif ($NoUpdate) {
        Write-LaunchLog 'Automatic update was disabled for this launch.' 'WARN'
    } else {
        $updateAttempted = $true
        $updater = Join-Path $installFull 'Start-ITCMon-With-Update.ps1'
        if (-not (Test-Path -LiteralPath $updater -PathType Leaf)) {
            $updateError = "Missing updater: $updater"
            Write-LaunchLog $updateError 'ERROR'
            if ($health.healthy) {
                $usedLastKnownGood = $true
                Write-LaunchLog 'The installed client passed local validation. Launching the last-known-good copy without the updater.' 'WARN'
            }
        } else {
            Write-LaunchLog 'Checking for validated application, configuration, railroad-data, WIU, and launcher updates.'
            try {
                $arguments = @{
                    InstallRoot = $installFull
                    ProfileName = $ProfileName
                    ServerHostOverride = $TruckHost
                    RepositoryUrl = $RepositoryUrl
                    Branch = $Branch
                    UpdateApplications = $true
                    NoLaunch = $true
                }
                if (-not [string]::IsNullOrWhiteSpace($UpdateSourceRoot)) {
                    $arguments.SourceRoot = $UpdateSourceRoot
                }
                & $updater @arguments *>&1 | ForEach-Object {
                    Write-LaunchLog ([string]$_)
                }
                $updateSucceeded = $true
                Write-LaunchLog 'Validated update check completed successfully.'
                $health = Get-InstalledClientHealth
            } catch {
                $updateError = $_.Exception.Message
                Write-LaunchLog "Update check failed: $updateError" 'ERROR'
                $health = Get-InstalledClientHealth
                if ($health.healthy) {
                    $usedLastKnownGood = $true
                    Write-LaunchLog 'The installed client passed local validation. Launching the last-known-good copy despite the update failure.' 'WARN'
                }
            }
        }
    }

    if (-not $health.healthy) {
        foreach ($issue in @($health.issues)) {
            Write-LaunchLog $issue 'ERROR'
        }
        throw 'The installed client is incomplete or invalid, so last-known-good launch is unsafe.'
    }

    if ($NoApplicationLaunch) {
        $finalState = if ($usedLastKnownGood) {
            'last-known-good-validated'
        } elseif ($updateSucceeded) {
            'update-validated'
        } else {
            'local-installation-validated'
        }
        Write-LaunchLog "Application launch was suppressed; validation completed with state '$finalState'."
        Write-FinalStatus
        exit 0
    }

    if ($LaunchTarget -eq 'ITCWatch') {
        $null = Start-ClientProcess -Name itcmon
        $null = Start-ClientProcess -Name itcwatch
    } else {
        $null = Start-ClientProcess -Name itcmon
    }

    $diagnostics = Get-ClientDiagnostics
    $finalState = if ($alreadyRunning -contains $LaunchTarget.ToLowerInvariant()) {
        'already-running'
    } else {
        'started'
    }
    Write-LaunchLog "Launch completed with state '$finalState'."
    Write-FinalStatus

    if ($finalState -eq 'already-running') {
        Show-Notice -Text "$LaunchTarget is already running. If its window is not visible, check the Windows notification area (including hidden icons).`r`n`r`nLatest diagnostic log:`r`n$logPath"
    }
    exit 0
} catch {
    $finalState = 'failed'
    $finalError = $_.Exception.Message
    Write-LaunchLog $finalError 'ERROR'
    Write-LaunchLog (($_ | Out-String).Trim()) 'ERROR'
    try { Write-FinalStatus } catch { }
    Show-Notice -ErrorNotice -Text "The $LaunchTarget client could not be started.`r`n`r`n$finalError`r`n`r`nDiagnostic log:`r`n$logPath"
    exit 1
} finally {
    try {
        $logs = @(Get-ChildItem -LiteralPath $logRoot -Filter 'truck-client-*.log' -File |
            Sort-Object LastWriteTimeUtc -Descending)
        foreach ($old in @($logs | Select-Object -Skip 30)) {
            Remove-Item -LiteralPath $old.FullName -Force
        }
    } catch { }
}
