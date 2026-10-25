#Requires -Version 5.1
<#
.SYNOPSIS
    Remove the WinHealthMonitor scheduled task.

.PARAMETER TaskName
    Name of the scheduled task. Default: WinHealthMonitor

.EXAMPLE
    .\Uninstall-Task.ps1
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'WinHealthMonitor'
)

$ErrorActionPreference = 'Stop'

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Host "Task '$TaskName' not found - nothing to do." -ForegroundColor Yellow
    return
}

if ($task.State -eq 'Running') {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "Removed task '$TaskName'." -ForegroundColor Green
