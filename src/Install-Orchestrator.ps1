[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\schedule.example.json'),
    [switch]$Apply,
    [switch]$Repair
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath (Resolve-Path -LiteralPath $ConfigPath) -Raw | ConvertFrom-Json
if ($config.schemaVersion -ne 1) { throw 'Unsupported configuration schema.' }
$root = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$config.installationRoot))
$prefix = [string]$config.taskPrefix
$plan = [ordered]@{
    generatedAt = (Get-Date).ToString('o')
    root = $root
    apply = [bool]$Apply
    repair = [bool]$Repair
    tasks = @('Daily', 'Weekly', 'Startup', 'Logon', 'Post Update', 'Shutdown Marker', 'Self Heal') | ForEach-Object { "$prefix $_" }
}
$plan | ConvertTo-Json -Depth 5
if (-not $Apply) { Write-Host 'Audit only. No tasks were created.'; return }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principalCheck = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principalCheck.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Installation requires elevation.' }
if (-not $PSCmdlet.ShouldProcess($root, 'Install maintenance scripts and scheduled tasks')) { return }

New-Item -ItemType Directory -Path $root -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Invoke-Maintenance.ps1') -Destination (Join-Path $root 'Invoke-Maintenance.ps1') -Force
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $root 'Install-Orchestrator.ps1') -Force
Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ConfigPath).Path -Destination (Join-Path $root 'schedule.json') -Force

$script = Join-Path $root 'Invoke-Maintenance.ps1'
function New-Action([string]$Mode) {
    New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Mode {1} -Root "{2}"' -f $script, $Mode, $root)
}
$system = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$user = New-ScheduledTaskPrincipal -UserId $identity.User.Value -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2) -Hidden

$dailyTime = [datetime]::Today.Add([timespan]::Parse([string]$config.dailyAt))
$daily = New-ScheduledTaskTrigger -Daily -At $dailyTime
Register-ScheduledTask -TaskName "$prefix Daily" -Action (New-Action Daily) -Trigger $daily -Principal $system -Settings $settings -Force | Out-Null

$weeklyTime = [datetime]::Today.Add([timespan]::Parse([string]$config.weeklyAt))
$weekly = New-ScheduledTaskTrigger -Weekly -DaysOfWeek ([string]$config.weeklyDay) -At $weeklyTime
Register-ScheduledTask -TaskName "$prefix Weekly" -Action (New-Action Weekly) -Trigger $weekly -Principal $system -Settings $settings -Force | Out-Null

$startup = New-ScheduledTaskTrigger -AtStartup
$startup.Delay = 'PT{0}S' -f [int]$config.startupDelaySeconds
Register-ScheduledTask -TaskName "$prefix Startup" -Action (New-Action Startup) -Trigger $startup -Principal $system -Settings $settings -Force | Out-Null

$logon = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
$logon.Delay = 'PT{0}S' -f [int]$config.logonDelaySeconds
Register-ScheduledTask -TaskName "$prefix Logon" -Action (New-Action Logon) -Trigger $logon -Principal $user -Settings $settings -Force | Out-Null

$selfHeal = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(5)) -RepetitionInterval (New-TimeSpan -Hours ([int]$config.selfHealHours)) -RepetitionDuration (New-TimeSpan -Days 3650)
Register-ScheduledTask -TaskName "$prefix Self Heal" -Action (New-Action SelfHeal) -Trigger $selfHeal -Principal $system -Settings $settings -Force | Out-Null

function Register-EventTask {
    param([string]$Name, [string]$Mode, [string]$Subscription, [string]$Delay = 'PT1M')
    $escapedSubscription = [Security.SecurityElement]::Escape($Subscription)
    $escapedCommand = [Security.SecurityElement]::Escape('powershell.exe')
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Mode {1} -Root "{2}"' -f $script, $Mode, $root
    $escapedArguments = [Security.SecurityElement]::Escape($arguments)
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers><EventTrigger><Enabled>true</Enabled><Subscription>$escapedSubscription</Subscription><Delay>$Delay</Delay></EventTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><StartWhenAvailable>true</StartWhenAvailable><Enabled>true</Enabled><Hidden>true</Hidden><ExecutionTimeLimit>PT2H</ExecutionTimeLimit></Settings>
  <Actions Context="Author"><Exec><Command>$escapedCommand</Command><Arguments>$escapedArguments</Arguments></Exec></Actions>
</Task>
"@
    Register-ScheduledTask -TaskName $Name -Xml $xml -Force | Out-Null
}

$updateQuery = '<QueryList><Query Id="0" Path="Microsoft-Windows-WindowsUpdateClient/Operational"><Select Path="Microsoft-Windows-WindowsUpdateClient/Operational">*[System[(EventID=19 or EventID=20 or EventID=43)]]</Select></Query></QueryList>'
$shutdownQuery = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name="User32"] and EventID=1074]]</Select></Query></QueryList>'
Register-EventTask -Name "$prefix Post Update" -Mode PostUpdate -Subscription $updateQuery -Delay 'PT2M'
Register-EventTask -Name "$prefix Shutdown Marker" -Mode ShutdownMarker -Subscription $shutdownQuery -Delay 'PT0S'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Mode Verify -Root $root
exit $LASTEXITCODE

