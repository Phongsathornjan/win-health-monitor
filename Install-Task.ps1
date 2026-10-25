#Requires -Version 5.1
<#
.SYNOPSIS
    Register the WinHealthMonitor scheduled task (runs every N minutes, no admin required).

.DESCRIPTION
    Creates a per-user scheduled task that calls Watch-Health.ps1 -Quiet.
    Uses an XML definition with an indefinite repetition interval (no expiry).

.PARAMETER TaskName
    Name of the scheduled task. Default: WinHealthMonitor

.PARAMETER IntervalMinutes
    How often the monitor runs. Default: 1

.EXAMPLE
    .\Install-Task.ps1

.EXAMPLE
    .\Install-Task.ps1 -IntervalMinutes 5 -TaskName MyMonitor
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'WinHealthMonitor',
    [int]$IntervalMinutes = 1
)

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Watch-Health.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Watch-Health.ps1 not found next to this script: $scriptPath"
}
if ($IntervalMinutes -lt 1) { throw 'IntervalMinutes must be >= 1' }

function ConvertTo-XmlText([string]$Value) {
    return $Value.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Quiet' -f $scriptPath
$startBoundary = (Get-Date).AddMinutes(1).ToString('yyyy-MM-ddTHH:mm:ss')
$userId = "$env:USERDOMAIN\$env:USERNAME"

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Windows health monitor - RAM/CPU/disk anomaly alerts to Discord</Description>
  </RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <Repetition>
        <Interval>PT${IntervalMinutes}M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>$(ConvertTo-XmlText $startBoundary)</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$(ConvertTo-XmlText $userId)</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(ConvertTo-XmlText "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe")</Command>
      <Arguments>$(ConvertTo-XmlText $arguments)</Arguments>
      <WorkingDirectory>$(ConvertTo-XmlText $PSScriptRoot)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null

$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host "Registered task '$TaskName'" -ForegroundColor Green
Write-Host ("  state      : {0}" -f $task.State)
Write-Host ("  interval   : every {0} minute(s)" -f $IntervalMinutes)
Write-Host ("  next run   : {0}" -f $info.NextRunTime)
Write-Host ("  runs as    : {0} (limited, interactive)" -f $userId)
Write-Host ''
Write-Host 'Test it now with:  Start-ScheduledTask -TaskName ' -NoNewline
Write-Host $TaskName
