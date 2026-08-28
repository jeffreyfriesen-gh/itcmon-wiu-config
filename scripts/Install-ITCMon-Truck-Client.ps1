[CmdletBinding()]
param(
    [string]$InstallRoot,

    [string]$TruckHost = 'telemetry-node.lan',

    [string]$RailfanHost = 'railfan-01',

    [string]$ReleaseArchivePath,

    [string]$ITCWatchExecutablePath,

    [string]$ATCSMonArchivePath,

    [string]$ShortcutIconPath,

    [string]$ConfigurationSourceRoot,

    [string]$DesktopPath,

    [string]$InstallerLogRoot,

    [switch]$NoDesktopShortcut,

    [switch]$NoLaunch,

    [switch]$PauseOnFailure
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$configurationUrl = 'https://github.com/jeffreyfriesen-gh/itcmon-wiu-config/archive/refs/heads/main.zip'
$profileName = 'truck-client'
$privateArtifactHost = 'svc-cache.lan'
$privateArtifactPort = 8080
$privateArtifactPathPrefix = '/r/8c2e6a/'
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$workRoot = Join-Path $env:TEMP "itcmon-truck-client-$PID-$stamp"
$releaseArchive = "$workRoot-release.zip"
$itcWatchDownload = "$workRoot-itcwatch.exe"
$atcsMonArchive = "$workRoot-atcsmon.zip"
$atcsMonPackageRoot = Join-Path $workRoot 'atcsmon-package'
$shortcutIconDownload = "$workRoot-itcmon-truck.ico"
$configurationArchive = "$workRoot-config.zip"
$packageRoot = Join-Path $workRoot 'package'
$configurationExtract = Join-Path $workRoot 'configuration'
$installerLogRoot = if (-not [string]::IsNullOrWhiteSpace($InstallerLogRoot)) {
    $InstallerLogRoot
} elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    Join-Path $env:LOCALAPPDATA 'ITCMon\InstallerLogs'
} else {
    Join-Path $env:TEMP 'ITCMon-InstallerLogs'
}
$installerLogPath = Join-Path $installerLogRoot "install-$stamp-pid$PID.log"
$installerTranscriptStarted = $false
try {
    New-Item -ItemType Directory -Path $installerLogRoot -Force | Out-Null
    Start-Transcript -LiteralPath $installerLogPath -Force | Out-Null
    $installerTranscriptStarted = $true
    Write-Host "[log] Persistent installer transcript: $installerLogPath"
} catch {
    Write-Warning "Persistent installer transcript could not be started: $($_.Exception.Message)"
}

function ConvertTo-SafeInstallRoot {
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'The installation root is empty.'
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    if ([string]::IsNullOrWhiteSpace((Split-Path -Parent $full)) -or
        $full -eq [IO.Path]::GetPathRoot($full)) {
        throw "Unsafe installation root: $full"
    }
    foreach ($systemDirectory in @($env:windir, $env:SystemRoot) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique) {
        $systemRoot = [IO.Path]::GetFullPath($systemDirectory).TrimEnd('\')
        if ([string]::Equals($full, $systemRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($systemRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to install ITCMon under the Windows system directory: $full"
        }
    }
    return $full
}

$installRootSource = 'explicit parameter'
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $candidateRoots = New-Object 'System.Collections.Generic.List[object]'
    try {
        $desktop = if (-not [string]::IsNullOrWhiteSpace($DesktopPath)) {
            $DesktopPath
        } else {
            [Environment]::GetFolderPath('Desktop')
        }
        $existingShortcut = Join-Path $desktop 'ITCMon - Truck.lnk'
        if (Test-Path -LiteralPath $existingShortcut -PathType Leaf) {
            $shell = New-Object -ComObject WScript.Shell
            $savedShortcut = $shell.CreateShortcut($existingShortcut)
            if (-not [string]::IsNullOrWhiteSpace([string]$savedShortcut.WorkingDirectory)) {
                $candidateRoots.Add([pscustomobject]@{
                    Source = "desktop shortcut $existingShortcut"
                    Path = [string]$savedShortcut.WorkingDirectory
                }) | Out-Null
            }
        }
    } catch {
        Write-Warning "Existing shortcut could not be inspected for install-root discovery: $($_.Exception.Message)"
    }
    $localAppData = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'The current user has no LocalApplicationData path for the default installation root.'
    }
    foreach ($candidate in @(
        (Join-Path $localAppData 'Programs\ITCM-Client'),
        (Join-Path $localAppData 'Programs\ITCMon-v1.0'),
        (Join-Path $localAppData 'Programs\ITCMon-v0.9')
    )) {
        $candidateRoots.Add([pscustomobject]@{
            Source = 'current-user known install root'
            Path = $candidate
        }) | Out-Null
    }

    $selectedRoot = $null
    foreach ($candidate in $candidateRoots) {
        try {
            $candidateFull = ConvertTo-SafeInstallRoot -Path ([string]$candidate.Path)
        } catch {
            Write-Warning ("Ignoring install-root candidate from {0}: path='{1}'; reason='{2}'" -f
                $candidate.Source, $candidate.Path, $_.Exception.Message)
            continue
        }
        $hasITCMon = Test-Path -LiteralPath (Join-Path $candidateFull 'itcmon.exe') -PathType Leaf
        Write-Host ("[install-root] Candidate source='{0}' path='{1}' safe=True has_itcmon={2}" -f
            $candidate.Source, $candidateFull, $hasITCMon)
        if ($hasITCMon) {
            $selectedRoot = $candidateFull
            $installRootSource = [string]$candidate.Source
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($selectedRoot)) {
        $selectedRoot = ConvertTo-SafeInstallRoot -Path (Join-Path $localAppData 'Programs\ITCM-Client')
        $installRootSource = 'current-user default'
    }
    $InstallRoot = $selectedRoot
}
$installFull = ConvertTo-SafeInstallRoot -Path $InstallRoot
Write-Host "[install-root] Selected '$installFull' from $installRootSource."
$installParent = Split-Path -Parent $installFull
$backupRoot = $null
$previousMoved = $false
$newInstalled = $false
$success = $false
$currentStage = 'initial validation'

function Write-InstallStage {
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Description
    )

    $script:currentStage = "stage $Number of 8: $Description"
    Write-Host "[stage $Number/8] $Description"
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF) | ConvertFrom-Json
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

function Get-ApplicationEntry {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$PackageType,
        [Parameter(Mandatory)][string]$Executable
    )

    $match = @($Manifest.applications | Where-Object name -eq $Name)
    if ($match.Count -ne 1) {
        throw "Configuration manifest has no unique '$Name' application entry."
    }
    $entry = $match[0]
    if ([string]$entry.package_type -ne $PackageType -or [string]$entry.executable -ne $Executable) {
        throw "Application '$Name' has an unsupported package definition."
    }
    foreach ($field in @('version', 'url', 'sha256', 'executable_sha256')) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.$field)) {
            throw "Application '$Name' has no $field value."
        }
    }
    if ([string]$entry.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        [string]$entry.executable_sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "Application '$Name' has an invalid SHA-256 value."
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
        throw "Application '$Name' does not use an approved release origin."
    }
    return $entry
}

function Get-ClientAssetEntry {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Destination
    )

    $match = @($Manifest.client_assets | Where-Object name -eq $Name)
    if ($match.Count -ne 1) {
        throw "Configuration manifest has no unique '$Name' client asset."
    }
    $entry = $match[0]
    foreach ($field in @('version', 'url', 'sha256', 'destination')) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.$field)) {
            throw "Client asset '$Name' has no $field value."
        }
    }
    if ([string]$entry.destination -ne $Destination -or
        [string]$entry.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "Client asset '$Name' has an unsupported destination or SHA-256 value."
    }
    $uri = [Uri]([string]$entry.url)
    if ($uri.Scheme -ne 'http' -or $uri.Host -ne $privateArtifactHost -or
        $uri.Port -ne $privateArtifactPort -or
        -not $uri.AbsolutePath.StartsWith($privateArtifactPathPrefix, [StringComparison]::Ordinal)) {
        throw "Client asset '$Name' does not use the approved private artifact origin."
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
        'mscomm32.ocx', 'spin32.ocx', 'richtx32.ocx', 'msscript.ocx'
    )
    $registerNames += '..\subclass.ocx'
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
                throw "ATCSMon runtime registration failed for $component with exit code $($process.ExitCode). Run the installer from an elevated PowerShell window."
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

function Test-TcpEndpoint {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMilliseconds = 800
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

if (-not ([System.Management.Automation.PSTypeName]'ITCMRestartManager').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ITCMRestartManager
{
    private const int ERROR_SUCCESS = 0;
    private const int ERROR_MORE_DATA = 234;
    private const int CCH_RM_SESSION_KEY = 32;

    [StructLayout(LayoutKind.Sequential)]
    public struct RM_UNIQUE_PROCESS
    {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    public enum RM_APP_TYPE
    {
        RmUnknownApp = 0,
        RmMainWindow = 1,
        RmOtherWindow = 2,
        RmService = 3,
        RmExplorer = 4,
        RmConsole = 5,
        RmCritical = 1000
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string strServiceShortName;
        public RM_APP_TYPE ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmStartSession(out uint sessionHandle, int sessionFlags, StringBuilder sessionKey);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmRegisterResources(
        uint sessionHandle,
        uint fileCount,
        string[] fileNames,
        uint applicationCount,
        RM_UNIQUE_PROCESS[] applications,
        uint serviceCount,
        string[] serviceNames);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmGetList(
        uint sessionHandle,
        out uint processInfoNeeded,
        ref uint processInfoCount,
        [In, Out] RM_PROCESS_INFO[] affectedApps,
        ref uint rebootReasons);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmEndSession(uint sessionHandle);

    public static RM_PROCESS_INFO[] GetLockingProcesses(string[] fileNames)
    {
        if (fileNames == null || fileNames.Length == 0)
            return new RM_PROCESS_INFO[0];

        uint handle;
        var key = new StringBuilder(CCH_RM_SESSION_KEY + 1);
        int result = RmStartSession(out handle, 0, key);
        if (result != ERROR_SUCCESS)
            throw new InvalidOperationException("RmStartSession failed with Win32 error " + result + ".");

        try
        {
            result = RmRegisterResources(handle, (uint)fileNames.Length, fileNames, 0, null, 0, null);
            if (result != ERROR_SUCCESS)
                throw new InvalidOperationException("RmRegisterResources failed with Win32 error " + result + ".");

            uint needed = 0;
            uint count = 0;
            uint rebootReasons = 0;
            result = RmGetList(handle, out needed, ref count, null, ref rebootReasons);
            if (result == ERROR_SUCCESS)
                return new RM_PROCESS_INFO[0];
            if (result != ERROR_MORE_DATA)
                throw new InvalidOperationException("RmGetList(size) failed with Win32 error " + result + ".");

            var processes = new RM_PROCESS_INFO[needed];
            count = needed;
            result = RmGetList(handle, out needed, ref count, processes, ref rebootReasons);
            if (result != ERROR_SUCCESS)
                throw new InvalidOperationException("RmGetList(data) failed with Win32 error " + result + ".");
            if (count == processes.Length)
                return processes;
            var trimmed = new RM_PROCESS_INFO[count];
            Array.Copy(processes, trimmed, count);
            return trimmed;
        }
        finally
        {
            RmEndSession(handle);
        }
    }
}
'@
}

function Test-PathInsideRoot {
    param(
        [string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
        return $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Get-InstallTargetProcesses {
    param([Parameter(Mandatory)][string]$TargetRoot)

    $legacyATCSMon = 'C:\ATCS Monitor\atcsmon.exe'
    return @(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object {
                $processPath = $null
                try { $processPath = $_.Path } catch { }
                (Test-PathInsideRoot -Path $processPath -Root $TargetRoot) -or
                    ([string]::Equals($processPath, $legacyATCSMon, [StringComparison]::OrdinalIgnoreCase))
            }
    )
}

function Get-InstallResourceLockers {
    param([Parameter(Mandatory)][string]$TargetRoot)

    if (-not (Test-Path -LiteralPath $TargetRoot -PathType Container)) {
        return @()
    }
    $files = @(Get-ChildItem -LiteralPath $TargetRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName)
    if ($files.Count -eq 0) {
        return @()
    }

    try {
        $lockInfo = @([ITCMRestartManager]::GetLockingProcesses([string[]]$files))
    } catch {
        Write-Warning "Windows Restart Manager could not enumerate install-directory locks: $($_.Exception.Message)"
        return @()
    }

    return @($lockInfo | ForEach-Object {
        $lockerPID = [int]$_.Process.dwProcessId
        $process = Get-Process -Id $lockerPID -ErrorAction SilentlyContinue
        $processPath = $null
        if ($process) {
            try { $processPath = $process.Path } catch { }
        }
        $commandLine = $null
        try {
            $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $lockerPID" -ErrorAction Stop
            $commandLine = [string]$cim.CommandLine
        } catch { }
        [pscustomobject]@{
            Id = $lockerPID
            ProcessName = if ($process) { [string]$process.ProcessName } else { [string]$_.strAppName }
            Path = $processPath
            CommandLine = $commandLine
            ApplicationType = [string]$_.ApplicationType
            ServiceName = [string]$_.strServiceShortName
        }
    } | Sort-Object Id -Unique)
}

function Test-ApprovedInstallLocker {
    param(
        [Parameter(Mandatory)]$Locker,
        [Parameter(Mandatory)][string]$TargetRoot
    )

    if ([int]$Locker.Id -le 4 -or [int]$Locker.Id -eq $PID) {
        return $false
    }
    if ((Test-PathInsideRoot -Path ([string]$Locker.Path) -Root $TargetRoot) -or
        [string]::Equals([string]$Locker.Path, 'C:\ATCS Monitor\atcsmon.exe', [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $scriptHosts = @('cmd', 'powershell', 'pwsh', 'python', 'pythonw')
    $rootPrefix = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\') + '\'
    return ([string]$Locker.ProcessName).ToLowerInvariant() -in $scriptHosts -and
        -not [string]::IsNullOrWhiteSpace([string]$Locker.CommandLine) -and
        ([string]$Locker.CommandLine).IndexOf($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Format-InstallLockerList {
    param([object[]]$Lockers)

    if (@($Lockers).Count -eq 0) {
        return '<none reported>'
    }
    return (@($Lockers | ForEach-Object {
        $path = if ([string]::IsNullOrWhiteSpace([string]$_.Path)) { '<path unavailable>' } else { [string]$_.Path }
        "PID $($_.Id) $($_.ProcessName) [$($_.ApplicationType)] $path"
    }) -join '; ')
}

function Stop-ClientProcessesForInstall {
    param([Parameter(Mandatory)][string]$TargetRoot)

    $running = @(Get-InstallTargetProcesses -TargetRoot $TargetRoot)
    if ($running.Count -eq 0) {
        Write-Host '[pre-install] No executable processes launched from the ITCM installation tree were found.'
    }

    foreach ($process in $running | Sort-Object Id) {
        $path = '<unavailable>'
        try { $path = $process.Path } catch { }
        Write-Host "[pre-install] Stopping $($process.ProcessName).exe PID $($process.Id) ($path)."
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        } catch {
            throw "Could not stop $($process.ProcessName).exe PID $($process.Id): $($_.Exception.Message)"
        }
    }

    $lockers = @(Get-InstallResourceLockers -TargetRoot $TargetRoot)
    foreach ($locker in $lockers) {
        if (-not (Test-ApprovedInstallLocker -Locker $locker -TargetRoot $TargetRoot)) {
            Write-Warning ("Install resource is held by an unrecognized process; it will not be force-stopped: {0}" -f `
                (Format-InstallLockerList -Lockers @($locker)))
            continue
        }
        Write-Host ("[pre-install] Stopping approved install-resource locker: {0}" -f `
            (Format-InstallLockerList -Lockers @($locker)))
        try {
            Stop-Process -Id ([int]$locker.Id) -Force -ErrorAction Stop
        } catch {
            throw "Could not stop install-resource locker PID $($locker.Id): $($_.Exception.Message)"
        }
    }

    $deadline = (Get-Date).AddSeconds(15)
    do {
        $remaining = @(Get-InstallTargetProcesses -TargetRoot $TargetRoot)
        if ($remaining.Count -eq 0) {
            Write-Host '[pre-install] All approved ITCM application processes are stopped.'
            return
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    $detail = ($remaining | ForEach-Object { "$($_.ProcessName).exe PID $($_.Id)" }) -join ', '
    throw "ITCM client processes remain after the 15-second stop deadline: $detail"
}

function Move-InstallDirectoryWithRetry {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$TargetRoot,
        [int]$MaximumAttempts = 20
    )

    $lastError = $null
    $lastLockers = @()
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        Stop-ClientProcessesForInstall -TargetRoot $TargetRoot
        try {
            Move-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
            if ($attempt -gt 1) {
                Write-Host "[install] Directory replacement lock cleared on attempt $attempt of $MaximumAttempts."
            }
            return
        } catch {
            $lastError = $_
            $lastLockers = @(Get-InstallResourceLockers -TargetRoot $TargetRoot)
            $lockerText = Format-InstallLockerList -Lockers $lastLockers
            Write-Warning ("Directory move attempt {0}/{1} failed. Source='{2}' Destination='{3}' Lockers={4} Error={5}" -f `
                $attempt, $MaximumAttempts, $Source, $Destination, $lockerText, $_.Exception.Message)
            if ($attempt -lt $MaximumAttempts) {
                Start-Sleep -Seconds 1
            }
        }
    }

    $finalLockerText = Format-InstallLockerList -Lockers $lastLockers
    throw ("Could not move the existing installation after {0} attempts. Source='{1}' Destination='{2}' Lockers={3} LastError={4}" -f `
        $MaximumAttempts, $Source, $Destination, $finalLockerText, $lastError.Exception.Message)
}

if ($TruckHost -notmatch '^[A-Za-z0-9.-]+$') {
    throw 'TruckHost must be an IPv4 address or DNS hostname containing only letters, digits, dots, and hyphens.'
}
if ([string]::IsNullOrWhiteSpace($installParent) -or $installFull -eq [IO.Path]::GetPathRoot($installFull)) {
    throw "Unsafe installation root: $installFull"
}
$windowsRoot = [IO.Path]::GetFullPath($env:windir).TrimEnd('\')
if ([string]::Equals($installFull, $windowsRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $installFull.StartsWith($windowsRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to install ITCMon under the Windows system directory.'
}
Stop-ClientProcessesForInstall -TargetRoot $installFull
$existingATCSRuntime = (Test-Path -LiteralPath (Join-Path $installFull 'ATCSMon\atcsmon.exe') -PathType Leaf) -or
    (Test-Path -LiteralPath 'C:\ATCS Monitor\atcsmon.exe' -PathType Leaf)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
Write-Host ("[install] ITCMon truck client provisioning started at {0}." -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
try {
    Write-InstallStage -Number 1 -Description 'Acquire and validate the truck configuration catalog.'
    if ([string]::IsNullOrWhiteSpace($ConfigurationSourceRoot)) {
        Save-RemoteFile -Uri $configurationUrl -Destination $configurationArchive `
            -Description 'Truck configuration package'
        Expand-Archive -LiteralPath $configurationArchive -DestinationPath $configurationExtract
        $configurationRoots = @(Get-ChildItem -LiteralPath $configurationExtract -Directory)
        if ($configurationRoots.Count -ne 1) {
            throw "The configuration archive contained $($configurationRoots.Count) roots; expected one."
        }
        $configurationRoot = $configurationRoots[0].FullName
    } else {
        $configurationRoot = (Resolve-Path -LiteralPath $ConfigurationSourceRoot).Path
    }
    $manifest = Read-JsonFile -Path (Join-Path $configurationRoot 'manifest.json')
    $itcmonApplication = Get-ApplicationEntry -Manifest $manifest -Name 'itcmon' `
        -PackageType 'zip' -Executable 'itcmon.exe'
    $itcWatchApplication = Get-ApplicationEntry -Manifest $manifest -Name 'itcwatch' `
        -PackageType 'file' -Executable 'itcwatch.exe'
    $atcsMonApplication = Get-ApplicationEntry -Manifest $manifest -Name 'atcsmon' `
        -PackageType 'zip' -Executable 'ATCSMon/atcsmon.exe'
    $shortcutIcon = Get-ClientAssetEntry -Manifest $manifest -Name 'itcmon-shortcut-icon' `
        -Destination 'assets/itcmon-truck.ico'
    $releaseVersion = [string]$itcmonApplication.version
    $releaseArchiveUrl = [string]$itcmonApplication.url
    $releaseArchiveSHA256 = ([string]$itcmonApplication.sha256).ToUpperInvariant()
    $releaseITCMonSHA256 = ([string]$itcmonApplication.executable_sha256).ToUpperInvariant()
    $itcWatchVersion = [string]$itcWatchApplication.version
    $itcWatchUrl = [string]$itcWatchApplication.url
    $itcWatchSHA256 = ([string]$itcWatchApplication.executable_sha256).ToUpperInvariant()
    $atcsMonVersion = [string]$atcsMonApplication.version
    $atcsMonUrl = [string]$atcsMonApplication.url
    $atcsMonArchiveSHA256 = ([string]$atcsMonApplication.sha256).ToUpperInvariant()
    $atcsMonExecutableSHA256 = ([string]$atcsMonApplication.executable_sha256).ToUpperInvariant()
    $shortcutIconSHA256 = ([string]$shortcutIcon.sha256).ToUpperInvariant()

    Write-InstallStage -Number 2 -Description "Acquire and validate ITCMon $releaseVersion."
    if ([string]::IsNullOrWhiteSpace($ReleaseArchivePath)) {
        Save-RemoteFile -Uri $releaseArchiveUrl -Destination $releaseArchive `
            -Description "ITCMon $releaseVersion package"
    } else {
        Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ReleaseArchivePath).Path -Destination $releaseArchive
    }
    $releaseHash = (Get-FileHash -LiteralPath $releaseArchive -Algorithm SHA256).Hash
    if ($releaseHash -ne $releaseArchiveSHA256) {
        throw "Official ITCMon $releaseVersion archive failed SHA-256 validation: $releaseHash"
    }
    Expand-Archive -LiteralPath $releaseArchive -DestinationPath $packageRoot
    $releasedExecutable = Join-Path $packageRoot 'itcmon.exe'
    if ((Get-FileHash -LiteralPath $releasedExecutable -Algorithm SHA256).Hash -ne $releaseITCMonSHA256) {
        throw "Official ITCMon $releaseVersion executable failed SHA-256 validation."
    }

    Write-InstallStage -Number 3 -Description "Acquire and validate ITCWatch $itcWatchVersion."
    if ([string]::IsNullOrWhiteSpace($ITCWatchExecutablePath)) {
        Save-RemoteFile -Uri $itcWatchUrl -Destination $itcWatchDownload `
            -Description "ITCWatch $itcWatchVersion package"
    } else {
        Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ITCWatchExecutablePath).Path -Destination $itcWatchDownload
    }
    $itcWatchDownloadHash = (Get-FileHash -LiteralPath $itcWatchDownload -Algorithm SHA256).Hash
    if ($itcWatchDownloadHash -ne $itcWatchSHA256) {
        throw "Official ITCWatch $itcWatchVersion executable failed SHA-256 validation: $itcWatchDownloadHash"
    }

    Write-InstallStage -Number 4 -Description "Acquire and validate ATCSMon $atcsMonVersion and the managed shortcut icon."
    if ([string]::IsNullOrWhiteSpace($ATCSMonArchivePath)) {
        Save-RemoteFile -Uri $atcsMonUrl -Destination $atcsMonArchive `
            -Description "ATCSMon $atcsMonVersion package"
    } else {
        Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ATCSMonArchivePath).Path -Destination $atcsMonArchive
    }
    $atcsMonArchiveHash = (Get-FileHash -LiteralPath $atcsMonArchive -Algorithm SHA256).Hash
    if ($atcsMonArchiveHash -ne $atcsMonArchiveSHA256) {
        throw "ATCSMon $atcsMonVersion package failed SHA-256 validation: $atcsMonArchiveHash"
    }
    Expand-Archive -LiteralPath $atcsMonArchive -DestinationPath $atcsMonPackageRoot
    $atcsMonReleasedExecutable = Join-Path $atcsMonPackageRoot 'ATCSMon\atcsmon.exe'
    if (-not (Test-Path -LiteralPath $atcsMonReleasedExecutable -PathType Leaf) -or
        (Get-FileHash -LiteralPath $atcsMonReleasedExecutable -Algorithm SHA256).Hash -ne $atcsMonExecutableSHA256) {
        throw "ATCSMon $atcsMonVersion executable failed SHA-256 validation."
    }
    if ([string]::IsNullOrWhiteSpace($ShortcutIconPath)) {
        Save-RemoteFile -Uri ([string]$shortcutIcon.url) -Destination $shortcutIconDownload `
            -Description 'ITCMon shortcut icon'
    } else {
        Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ShortcutIconPath).Path -Destination $shortcutIconDownload
    }
    if ((Get-FileHash -LiteralPath $shortcutIconDownload -Algorithm SHA256).Hash -ne $shortcutIconSHA256) {
        throw 'ITCMon shortcut icon failed SHA-256 validation.'
    }

    $clientScriptNames = @(
        'Start-ITCMon-With-Update.ps1',
        'Start-ITCMon-With-Update.cmd',
        'Invoke-ITCM-BackgroundUpdate.ps1',
        'Register-ITCM-GitHub-UpdateTask.ps1',
        'Launch-ITCM-Truck-Client.ps1',
        'Start ITCMon - Truck.cmd',
        'Start ITCWatch - Truck.cmd',
        'Start ATCSMon - Truck.cmd',
        'Diagnose ITCM Truck Client.cmd'
    )
    $clientScriptSources = @($clientScriptNames | ForEach-Object {
        Join-Path $configurationRoot "scripts\$_"
    })
    foreach ($required in @($clientScriptSources + (Join-Path $configurationRoot 'manifest.json'))) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "The configuration package is incomplete: $required"
        }
    }

    Write-InstallStage -Number 5 -Description 'Install application files and preserve prior local data.'
    Stop-ClientProcessesForInstall -TargetRoot $installFull
    New-Item -ItemType Directory -Path $installParent -Force | Out-Null
    if (Test-Path -LiteralPath $installFull) {
        $backupParent = Join-Path $installParent 'ITCMon-backups'
        New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
        $backupRoot = Join-Path $backupParent "ITCMon-before-$releaseVersion-$stamp"
        if (Test-Path -LiteralPath $backupRoot) {
            throw "Refusing to replace an existing backup: $backupRoot"
        }
        Move-InstallDirectoryWithRetry -Source $installFull -Destination $backupRoot -TargetRoot $installFull
        $previousMoved = $true
    }
    Move-Item -LiteralPath $packageRoot -Destination $installFull
    $newInstalled = $true

    $itcWatchInstalled = Join-Path $installFull 'itcwatch.exe'
    Copy-Item -LiteralPath $itcWatchDownload -Destination $itcWatchInstalled -Force
    $itcWatchInstalledHash = (Get-FileHash -LiteralPath $itcWatchInstalled -Algorithm SHA256).Hash
    if ($itcWatchInstalledHash -ne $itcWatchSHA256) {
        throw 'Installed ITCWatch executable failed SHA-256 acceptance.'
    }

    $atcsMonInstalledRoot = Join-Path $installFull 'ATCSMon'
    Copy-Item -LiteralPath (Join-Path $atcsMonPackageRoot 'ATCSMon') -Destination $atcsMonInstalledRoot -Recurse -Force
    $atcsMonInstalled = Join-Path $atcsMonInstalledRoot 'atcsmon.exe'
    $atcsMonInstalledHash = (Get-FileHash -LiteralPath $atcsMonInstalled -Algorithm SHA256).Hash
    if ($atcsMonInstalledHash -ne $atcsMonExecutableSHA256) {
        throw 'Installed ATCSMon executable failed SHA-256 acceptance.'
    }
    Install-ATCSMonRuntime -ATCSRoot $atcsMonInstalledRoot -SkipRegistration:$existingATCSRuntime

    $shortcutIconInstalled = Join-Path $installFull 'assets\itcmon-truck.ico'
    New-Item -ItemType Directory -Path (Split-Path -Parent $shortcutIconInstalled) -Force | Out-Null
    Copy-Item -LiteralPath $shortcutIconDownload -Destination $shortcutIconInstalled -Force
    if ((Get-FileHash -LiteralPath $shortcutIconInstalled -Algorithm SHA256).Hash -ne $shortcutIconSHA256) {
        throw 'Installed ITCMon shortcut icon failed SHA-256 acceptance.'
    }

    if ($backupRoot) {
        foreach ($name in @('packets.hex', 'config-backups', 'application-backups')) {
            $preserved = Join-Path $backupRoot $name
            if (Test-Path -LiteralPath $preserved) {
                Copy-Item -LiteralPath $preserved -Destination (Join-Path $installFull $name) -Recurse -Force
            }
        }
    }
    $previousATCSRoot = if ($backupRoot -and
        (Test-Path -LiteralPath (Join-Path $backupRoot 'ATCSMon') -PathType Container)) {
        Join-Path $backupRoot 'ATCSMon'
    } elseif (Test-Path -LiteralPath 'C:\ATCS Monitor\atcsmon.exe' -PathType Leaf) {
        'C:\ATCS Monitor'
    } else {
        $null
    }
    if ($previousATCSRoot -and
        -not [string]::Equals($previousATCSRoot, $atcsMonInstalledRoot, [StringComparison]::OrdinalIgnoreCase)) {
            foreach ($relative in @('atcsmon.ini', 'atcsdb.mdb', 'Downloads', 'Import', 'kmz', 'Layouts', 'Logs', 'MCPs', 'Notes')) {
                $preserved = Join-Path $previousATCSRoot $relative
                if (Test-Path -LiteralPath $preserved) {
                    $destination = Join-Path $atcsMonInstalledRoot $relative
                    if ((Get-Item -LiteralPath $preserved).PSIsContainer) {
                        New-Item -ItemType Directory -Path $destination -Force | Out-Null
                        Get-ChildItem -LiteralPath $preserved -Force |
                            Copy-Item -Destination $destination -Recurse -Force
                    } else {
                        Copy-Item -LiteralPath $preserved -Destination $destination -Force
                    }
                }
            }
    }

    foreach ($name in $clientScriptNames) {
        Copy-Item -LiteralPath (Join-Path $configurationRoot "scripts\$name") `
            -Destination (Join-Path $installFull $name) -Force
    }
    $updaterInstalled = Join-Path $installFull 'Start-ITCMon-With-Update.ps1'
    $launcherInstalled = Join-Path $installFull 'Launch-ITCM-Truck-Client.ps1'

    $profileEntry = @($manifest.profiles | Where-Object name -eq $profileName)
    if ($profileEntry.Count -ne 1) {
        throw "Configuration manifest has no unique '$profileName' profile."
    }
    $profileSource = Join-Path $configurationRoot ([string]$profileEntry[0].path)
    $profileSpec = Read-JsonFile -Path $profileSource
    $expectedServerCount = [int]$profileSpec.expected_server_count
    if ($expectedServerCount -le 0 -or $expectedServerCount -ne [int]$profileEntry[0].server_count) {
        throw 'Truck-client profile and manifest disagree on expected server count.'
    }
    $profilePath = Join-Path $installFull 'truck-client-profile.json'
    Copy-Item -LiteralPath $profileSource -Destination $profilePath -Force
    $profileHash = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    if ($profileHash -ne ([string]$profileEntry[0].sha256).ToUpperInvariant()) {
        throw "Truck-client profile failed manifest acceptance: $profileHash"
    }
    Write-InstallStage -Number 6 -Description 'Apply both truck receiver endpoints, local ITCWatch endpoint, WIUs, railroad data, and automatic updater.'
    & $updaterInstalled -InstallRoot $installFull -SourceRoot $configurationRoot `
        -ProfileName $profileName -ServerHostOverride $TruckHost `
        -UpdateApplications -ITCMonArchivePath $releaseArchive `
        -ITCWatchExecutablePath $itcWatchDownload `
        -ATCSMonArchivePath $atcsMonArchive -ShortcutIconPath $shortcutIconDownload `
        -NoDesktopShortcut:$NoDesktopShortcut -NoLaunch

    Write-InstallStage -Number 7 -Description 'Create the ITCMon, ITCWatch, and ATCSMon launchers and desktop shortcuts.'
    $truckCommand = Join-Path $installFull 'Start ITCMon - Truck.cmd'
    $itcWatchCommand = Join-Path $installFull 'Start ITCWatch - Truck.cmd'
    $atcsMonCommand = Join-Path $installFull 'Start ATCSMon - Truck.cmd'
    $diagnosticCommand = Join-Path $installFull 'Diagnose ITCM Truck Client.cmd'
    foreach ($requiredLauncher in @($launcherInstalled, $truckCommand, $itcWatchCommand, $atcsMonCommand, $diagnosticCommand)) {
        if (-not (Test-Path -LiteralPath $requiredLauncher -PathType Leaf)) {
            throw "Installed launcher is missing: $requiredLauncher"
        }
    }

    $installedProfile = Read-JsonFile -Path (Join-Path $installFull 'local\itcmon.json')
    $installedServers = @($installedProfile.servers)
    $installedHosts = @($installedServers.ip | Sort-Object -Unique)
    $telemetryServers = @($installedServers | Where-Object {
        [string]::Equals([string]$_.ip, $TruckHost, [StringComparison]::OrdinalIgnoreCase)
    })
    $railfanServers = @($installedServers | Where-Object {
        [string]::Equals([string]$_.ip, $RailfanHost, [StringComparison]::OrdinalIgnoreCase)
    })
    $actualHosts = @($installedHosts | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object)
    $expectedHosts = @($TruckHost.ToLowerInvariant(), $RailfanHost.ToLowerInvariant()) | Sort-Object
    $duplicateEndpoints = @($installedServers | Group-Object { "$($_.ip):$($_.port)" } | Where-Object Count -ne 1)
    if ($installedServers.Count -ne $expectedServerCount -or
        @($installedServers | Where-Object enabled).Count -ne $expectedServerCount -or
        ($actualHosts -join '|') -ne ($expectedHosts -join '|') -or
        $telemetryServers.Count -eq 0 -or
        $railfanServers.Count -eq 0 -or
        $duplicateEndpoints.Count -ne 0) {
        throw 'Installed truck-client server profile failed acceptance.'
    }

    $itcWatchConfigPath = Join-Path $env:APPDATA 'itcmon-viewer\viewer-config.json'
    if (-not (Test-Path -LiteralPath $itcWatchConfigPath -PathType Leaf)) {
        throw "ITCWatch viewer configuration was not created: $itcWatchConfigPath"
    }
    $itcWatchViewer = Read-JsonFile -Path $itcWatchConfigPath
    $itcWatchServers = @($itcWatchViewer.servers)
    if ($itcWatchServers.Count -ne 1 -or
        -not [string]::Equals([string]$itcWatchServers[0].host, $TruckHost, [StringComparison]::OrdinalIgnoreCase) -or
        [int]$itcWatchServers[0].port -ne 18001 -or
        -not [bool]$itcWatchServers[0].enabled -or
        [string]$itcWatchViewer.wiusRoot -ne (Join-Path $installFull 'wius') -or
        [string]$itcWatchViewer.rrdataPath -ne (Join-Path $installFull 'local\rrdata.json')) {
        throw 'ITCWatch viewer configuration failed aggregator endpoint/data-path acceptance.'
    }

    $rrdataEntry = @($manifest.files | Where-Object path -eq ([string]$manifest.rrdata_path))
    if ($rrdataEntry.Count -ne 1) {
        throw 'Configuration manifest has no unique rrdata entry.'
    }
    $installedRRDataHash = (Get-FileHash -LiteralPath (Join-Path $installFull 'local\rrdata.json') -Algorithm SHA256).Hash
    if ($installedRRDataHash -ne ([string]$rrdataEntry[0].sha256).ToUpperInvariant()) {
        throw 'Installed rrdata.json failed manifest acceptance.'
    }

    $wiuIDs = New-Object 'System.Collections.Generic.HashSet[string]'
    Get-ChildItem -LiteralPath (Join-Path $installFull 'wius') -Filter '*.json' -File -Recurse |
        ForEach-Object {
            $wiu = Read-JsonFile -Path $_.FullName
            foreach ($property in @($wiu.waysides.PSObject.Properties)) {
                if (-not $wiuIDs.Add([string]$property.Name)) {
                    throw "Duplicate installed WIU ID: $($property.Name)"
                }
            }
        }
    if ($wiuIDs.Count -ne [int]$manifest.wiu_count) {
        throw "Installed WIU count $($wiuIDs.Count) does not match manifest count $($manifest.wiu_count)."
    }

    $desktopShortcut = $null
    $itcWatchDesktopShortcut = $null
    $atcsMonDesktopShortcut = $null
    $diagnosticDesktopShortcut = $null
    if (-not $NoDesktopShortcut) {
        $desktop = if ([string]::IsNullOrWhiteSpace($DesktopPath)) {
            [Environment]::GetFolderPath('Desktop')
        } else {
            [IO.Path]::GetFullPath($DesktopPath)
        }
        if (-not [string]::IsNullOrWhiteSpace($desktop)) {
            New-Item -ItemType Directory -Path $desktop -Force | Out-Null
            $desktopShortcut = Join-Path $desktop 'ITCMon - Truck.lnk'
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($desktopShortcut)
            $shortcut.TargetPath = $env:ComSpec
            $shortcut.Arguments = '/d /c ""{0}""' -f $truckCommand
            $shortcut.WorkingDirectory = $installFull
            $shortcut.IconLocation = $shortcutIconInstalled
            $shortcut.Description = 'Start ITCMon with truck configuration, automatic updates, and persistent diagnostics.'
            $shortcut.Save()

            $itcWatchDesktopShortcut = Join-Path $desktop 'ITCWatch - Truck.lnk'
            $itcWatchShortcut = $shell.CreateShortcut($itcWatchDesktopShortcut)
            $itcWatchShortcut.TargetPath = $env:ComSpec
            $itcWatchShortcut.Arguments = '/d /c ""{0}""' -f $itcWatchCommand
            $itcWatchShortcut.WorkingDirectory = $installFull
            $itcWatchShortcut.IconLocation = $itcWatchInstalled
            $itcWatchShortcut.Description = 'Start ITCWatch with the truck ITCMon stack and persistent diagnostics.'
            $itcWatchShortcut.Save()

            $atcsMonDesktopShortcut = Join-Path $desktop 'ATCSMon - Truck.lnk'
            $atcsMonShortcut = $shell.CreateShortcut($atcsMonDesktopShortcut)
            $atcsMonShortcut.TargetPath = $env:ComSpec
            $atcsMonShortcut.Arguments = '/d /c ""{0}""' -f $atcsMonCommand
            $atcsMonShortcut.WorkingDirectory = $installFull
            $atcsMonShortcut.IconLocation = $atcsMonInstalled
            $atcsMonShortcut.Description = 'Check for managed client updates, then start ATCSMon.'
            $atcsMonShortcut.Save()

            $diagnosticDesktopShortcut = Join-Path $desktop 'Diagnose ITCM Truck Client.lnk'
            $diagnosticShortcut = $shell.CreateShortcut($diagnosticDesktopShortcut)
            $diagnosticShortcut.TargetPath = $env:ComSpec
            $diagnosticShortcut.Arguments = '/d /c ""{0}""' -f $diagnosticCommand
            $diagnosticShortcut.WorkingDirectory = $installFull
            $diagnosticShortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,23"
            $diagnosticShortcut.Description = 'Validate the truck client and show the persistent log and status paths.'
            $diagnosticShortcut.Save()

            foreach ($shortcutCheck in @(
                [pscustomobject]@{ Path = $desktopShortcut; Command = $truckCommand },
                [pscustomobject]@{ Path = $itcWatchDesktopShortcut; Command = $itcWatchCommand },
                [pscustomobject]@{ Path = $atcsMonDesktopShortcut; Command = $atcsMonCommand },
                [pscustomobject]@{ Path = $diagnosticDesktopShortcut; Command = $diagnosticCommand }
            )) {
                $savedShortcut = $shell.CreateShortcut($shortcutCheck.Path)
                $expectedArguments = '/d /c ""{0}""' -f $shortcutCheck.Command
                if (-not [string]::Equals($savedShortcut.TargetPath, $env:ComSpec, [StringComparison]::OrdinalIgnoreCase) -or
                    $savedShortcut.Arguments -ne $expectedArguments -or
                    -not [string]::Equals($savedShortcut.WorkingDirectory, $installFull, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Desktop shortcut failed acceptance: $($shortcutCheck.Path)"
                }
            }
        }
    }

    Write-InstallStage -Number 8 -Description 'Run final acceptance checks and record installation status.'
    $connectivity = [ordered]@{
        aggregator_zjpub_18001 = Test-TcpEndpoint -HostName $TruckHost -Port 18001
        telemetry_host = $TruckHost
        telemetry_fr_18101 = Test-TcpEndpoint -HostName $TruckHost -Port 18101
        telemetry_hr_20101 = Test-TcpEndpoint -HostName $TruckHost -Port 20101
        railfan_host = $RailfanHost
        railfan_fr_18077 = Test-TcpEndpoint -HostName $RailfanHost -Port 18077
        railfan_hr_20077 = Test-TcpEndpoint -HostName $RailfanHost -Port 20077
    }
    $result = [pscustomobject][ordered]@{
        schema = 'itcmon.truck-client.install.v1'
        installed_at = (Get-Date).ToUniversalTime().ToString('o')
        itcmon_release = $releaseVersion
        itcwatch_release = $itcWatchVersion
        itcwatch_sha256 = $itcWatchInstalledHash
        itcwatch_executable = $itcWatchInstalled
        atcsmon_release = $atcsMonVersion
        atcsmon_sha256 = $atcsMonInstalledHash
        atcsmon_executable = $atcsMonInstalled
        itcmon_shortcut_icon = $shortcutIconInstalled
        itcmon_shortcut_icon_sha256 = $shortcutIconSHA256
        install_root = $installFull
        rollback_root = $backupRoot
        server_profile = $profileName
        server_profile_sha256 = $profileHash
        server_hosts = @($TruckHost, $RailfanHost)
        servers = $installedServers.Count
        telemetry_servers = $telemetryServers.Count
        railfan_servers = $railfanServers.Count
        itcwatch_endpoint = "$TruckHost`:18001"
        itcwatch_config = $itcWatchConfigPath
        wius = $wiuIDs.Count
        rrdata_sha256 = $installedRRDataHash
        desktop_shortcut = $desktopShortcut
        itcwatch_desktop_shortcut = $itcWatchDesktopShortcut
        atcsmon_desktop_shortcut = $atcsMonDesktopShortcut
        diagnostic_desktop_shortcut = $diagnosticDesktopShortcut
        launch_log_root = (Join-Path $env:LOCALAPPDATA 'ITCMon\Logs')
        launch_status = (Join-Path $env:LOCALAPPDATA 'ITCMon\last-launch-status.json')
        connectivity = $connectivity
    }
    [IO.File]::WriteAllText(
        (Join-Path $installFull 'truck-client-install.json'),
        ($result | ConvertTo-Json -Depth 5) + "`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $success = $true
    $result | Format-List
    Write-Host ("[complete] Provisioning finished successfully at {0}." -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))

    if (-not $NoLaunch) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcherInstalled `
            -InstallRoot $installFull -ProfileName $profileName `
            -TruckHost $TruckHost -RailfanHost $RailfanHost -LaunchTarget ITCMon -NoUpdate
        if ($LASTEXITCODE -ne 0) {
            throw "Initial ITCMon launch failed with exit code $LASTEXITCODE."
        }
    }
} catch {
    Write-Host "[failed] Installer stopped during $currentStage" -ForegroundColor Red
    Write-Host "[failed] $($_.Exception.Message)" -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace([string]$_.InvocationInfo.PositionMessage)) {
        Write-Host "[failed] Source: $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$_.ScriptStackTrace)) {
        Write-Host "[failed] Stack: $($_.ScriptStackTrace)" -ForegroundColor Red
    }
    if ($installerTranscriptStarted) {
        Write-Host "[failed] Persistent transcript: $installerLogPath" -ForegroundColor Red
    }
    if ($PauseOnFailure -and [Environment]::UserInteractive) {
        Write-Host ''
        [void](Read-Host 'The installer failed. Press Enter to close this window')
    }
    throw
} finally {
    if (-not $success -and $newInstalled) {
        if (Test-Path -LiteralPath $installFull) {
            Remove-Item -LiteralPath $installFull -Recurse -Force
        }
        if ($previousMoved -and $backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
            Move-Item -LiteralPath $backupRoot -Destination $installFull
        }
    }
    foreach ($temporary in @(
        $releaseArchive, $itcWatchDownload, $atcsMonArchive,
        $shortcutIconDownload, $configurationArchive, $workRoot
    )) {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Recurse -Force
        }
    }
    if ($installerTranscriptStarted) {
        Write-Host "[log] Installer transcript retained at $installerLogPath"
        try {
            Stop-Transcript | Out-Null
        } catch {
            # Do not mask the installer result if transcript shutdown fails.
        }
    }
}
