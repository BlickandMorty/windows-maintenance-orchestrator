[CmdletBinding()]
param(
    [ValidateSet('Daily', 'Weekly', 'Startup', 'Logon', 'PostUpdate', 'ShutdownMarker', 'SelfHeal', 'Verify')]
    [string]$Mode = 'Verify',
    [string]$Root = 'C:\ProgramData\WindowsMaintenanceOrchestrator'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Root))
$configPath = Join-Path $Root 'schedule.json'
if (-not (Test-Path -LiteralPath $configPath)) {
    $fallback = Join-Path $PSScriptRoot '..\config\schedule.example.json'
    $configPath = (Resolve-Path -LiteralPath $fallback).Path
}
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$reportRoot = Join-Path $Root 'Reports'
if (-not (Test-Path -LiteralPath $Root)) { $reportRoot = Join-Path $env:TEMP 'WindowsMaintenanceOrchestrator-Reports' }
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
$runRoot = Join-Path $reportRoot ("{0}-{1}" -f $Mode, (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$events = [Collections.Generic.List[object]]::new()

function Add-Event {
    param([string]$Action, [string]$Status, [string]$Detail)
    $events.Add([pscustomobject]@{ at = (Get-Date).ToString('o'); action = $Action; status = $Status; detail = $Detail })
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Remove-OldSafeChildren {
    param([string]$Path, [int]$Days)
    if (-not (Test-Path -LiteralPath $Path)) { Add-Event 'Cleanup' 'Skipped' "Missing: $Path"; return }
    $resolved = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $allowed = @($env:TEMP, (Join-Path $env:LOCALAPPDATA 'Temp'), $reportRoot) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
    if ($resolved -notin $allowed) { throw "Unsafe cleanup root refused: $resolved" }
    $cutoff = (Get-Date).AddDays(-[Math]::Max(1, $Days))
    $removed = 0; $failed = 0
    Get-ChildItem -LiteralPath $resolved -Force -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt $cutoff | ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop; $removed++ } catch { $failed++ }
    }
    Add-Event 'Cleanup' ($(if ($failed) { 'Warning' } else { 'OK' })) "${resolved}: removed=$removed failed=$failed"
}

function Invoke-TextCommand {
    param([string]$Name, [string]$FilePath, [string[]]$Arguments)
    $text = & $FilePath @Arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    [IO.File]::WriteAllText((Join-Path $runRoot "$Name.txt"), $text, [Text.UTF8Encoding]::new($false))
    Add-Event $Name ($(if ($code -eq 0) { 'OK' } else { 'Warning' })) "Exit code $code"
}

function Get-ExpectedTasks {
    $prefix = [string]$config.taskPrefix
    @('Daily', 'Weekly', 'Startup', 'Logon', 'Post Update', 'Shutdown Marker', 'Self Heal') | ForEach-Object { "$prefix $_" }
}

function Invoke-Daily {
    Remove-OldSafeChildren -Path $env:TEMP -Days ([int]$config.tempRetentionDays)
    Remove-OldSafeChildren -Path $reportRoot -Days ([int]$config.reportRetentionDays)
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    Add-Event 'DNS cache' 'OK' 'Refresh requested.'
}

function Invoke-Weekly {
    Invoke-Daily
    if (-not (Test-IsAdministrator)) { throw 'Weekly maintenance requires elevation.' }
    Invoke-TextCommand 'dism-component-cleanup' 'dism.exe' @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    Invoke-TextCommand 'dism-checkhealth' 'dism.exe' @('/Online', '/Cleanup-Image', '/CheckHealth')
    try {
        Optimize-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') -ReTrim -ErrorAction Stop | Out-String | Set-Content -LiteralPath (Join-Path $runRoot 'retrim.txt')
        Add-Event 'SSD retrim' 'OK' 'System drive retrim requested.'
    } catch { Add-Event 'SSD retrim' 'Warning' $_.Exception.Message }
}

function Invoke-Verify {
    foreach ($taskName in Get-ExpectedTasks) {
        try {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
            $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
            Add-Event $taskName ($(if ($task.State -eq 'Disabled') { 'Failed' } else { 'OK' })) "State=$($task.State); LastResult=$($info.LastTaskResult)"
        } catch { Add-Event $taskName 'Failed' 'Missing or not visible.' }
    }
}

switch ($Mode) {
    'Daily' { Invoke-Daily }
    'Weekly' { Invoke-Weekly }
    'Startup' {
        Invoke-Daily
        if (Test-IsAdministrator) { Invoke-TextCommand 'startup-checkhealth' 'dism.exe' @('/Online', '/Cleanup-Image', '/CheckHealth') }
        $marker = Join-Path $Root 'State\shutdown-restart-marker.json'
        if (Test-Path -LiteralPath $marker) { Add-Event 'Previous shutdown/restart marker' 'OK' (Get-Content -LiteralPath $marker -Raw) }
    }
    'Logon' {
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        Add-Event 'Logon refresh' 'OK' "User=$([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    }
    'PostUpdate' {
        if (-not (Test-IsAdministrator)) { throw 'PostUpdate requires elevation.' }
        Invoke-TextCommand 'post-update-checkhealth' 'dism.exe' @('/Online', '/Cleanup-Image', '/CheckHealth')
        Invoke-TextCommand 'post-update-component-cleanup' 'dism.exe' @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    }
    'ShutdownMarker' {
        $stateRoot = Join-Path $Root 'State'
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
        $marker = [ordered]@{ recordedAt = (Get-Date).ToString('o'); bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime; source = 'User32 event 1074' }
        [IO.File]::WriteAllText((Join-Path $stateRoot 'shutdown-restart-marker.json'), ($marker | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        Add-Event 'Shutdown/restart marker' 'OK' 'Marker recorded for startup follow-up.'
    }
    'SelfHeal' {
        if (-not (Test-IsAdministrator)) { throw 'SelfHeal requires elevation.' }
        $installer = Join-Path $Root 'Install-Orchestrator.ps1'
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer -Apply -Repair
        Add-Event 'Self heal' ($(if ($LASTEXITCODE -eq 0) { 'OK' } else { 'Failed' })) "Installer exit code $LASTEXITCODE"
    }
    'Verify' { Invoke-Verify }
}

$report = [ordered]@{
    schemaVersion = 1
    mode = $Mode
    generatedAt = (Get-Date).ToString('o')
    computer = $env:COMPUTERNAME
    events = @($events)
}
[IO.File]::WriteAllText((Join-Path $runRoot 'result.json'), ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 8
if (@($events | Where-Object Status -eq 'Failed').Count) { exit 2 }
