[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\ITCM\Applications\ITCMon-v1.0',
    [string]$RepositoryUrl = 'https://github.com/jeffreyfriesen-gh/itcmon-wiu-config.git',
    [string]$Branch = 'main',
    [string]$CacheRoot = 'C:\ProgramData\ITCMon\ConfigRepository',
    [string]$ProfileName = 'truck-vm201',
    [string]$ServerHostOverride,
    [ValidateRange(5, 1440)][int]$IntervalMinutes = 15,
    [string]$TaskName = 'ITCM GitHub Configuration Update',
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Register-ITCM-GitHub-UpdateTask.ps1 must run from an elevated PowerShell session.'
}

$installFull = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$worker = Join-Path $installFull 'Invoke-ITCM-BackgroundUpdate.ps1'
if (-not (Test-Path -LiteralPath $worker -PathType Leaf)) {
    throw "Background updater is missing: $worker"
}

function Quote-Argument {
    param([Parameter(Mandatory)][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

$argumentParts = @(
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Quote-Argument $worker),
    '-InstallRoot', (Quote-Argument $installFull),
    '-RepositoryUrl', (Quote-Argument $RepositoryUrl),
    '-Branch', (Quote-Argument $Branch),
    '-CacheRoot', (Quote-Argument $CacheRoot),
    '-ProfileName', (Quote-Argument $ProfileName)
)
if (-not [string]::IsNullOrWhiteSpace($ServerHostOverride)) {
    $argumentParts += @('-ServerHostOverride', (Quote-Argument $ServerHostOverride))
}
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument ($argumentParts -join ' ') -WorkingDirectory $installFull
$startupTrigger = New-ScheduledTaskTrigger -AtStartup
$periodicTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -RestartCount 2 `
    -RestartInterval (New-TimeSpan -Minutes 2)
$task = Register-ScheduledTask -TaskName $TaskName -Action $action `
    -Trigger @($startupTrigger, $periodicTrigger) -Settings $settings `
    -User 'SYSTEM' -RunLevel Highest -Force

$registeredAction = @($task.Actions)
if ($registeredAction.Count -ne 1 -or
    -not ([string]$registeredAction[0].Arguments).Contains('-Branch "main"') -or
    -not ([string]$registeredAction[0].Arguments).Contains('Invoke-ITCM-BackgroundUpdate.ps1')) {
    throw "Scheduled-task acceptance failed for $TaskName"
}
if ($RunNow) {
    Start-ScheduledTask -TaskName $TaskName
}

[pscustomobject][ordered]@{
    task = $TaskName
    user = 'SYSTEM'
    branch = $Branch
    repository = $RepositoryUrl
    interval_minutes = $IntervalMinutes
    worker = $worker
    cache = $CacheRoot
    run_requested = [bool]$RunNow
} | Format-List
