<#
.SYNOPSIS
    Windows health monitor - detects abnormal RAM / CPU / disk usage and alerts via Discord.

.DESCRIPTION
    Designed to run every minute from Task Scheduler (see Install-Task.ps1).

    The script keeps a small JSON state file so it can:
      * derive disk throughput from cumulative performance counters
      * derive per-process CPU usage and I/O between two runs
      * apply "sustained for N samples" rules
      * suppress duplicate alerts (per-key cooldown + daily message cap)
      * announce recovery (optional)

    Alerts are sent as a single Discord embed per run, so a burst of problems
    never floods the channel.

.PARAMETER ConfigPath
    Path to config.json. Defaults to config.json next to this script.

.PARAMETER TestAlert
    Send a test message to the configured Discord webhook and exit.

.PARAMETER NoAlert
    Evaluate rules and write state/log but never contact Discord.

.PARAMETER Quiet
    Do not write anything to the console (used by Task Scheduler).

.EXAMPLE
    .\Watch-Health.ps1

.EXAMPLE
    .\Watch-Health.ps1 -NoAlert

.EXAMPLE
    .\Watch-Health.ps1 -TestAlert

.NOTES
    Exit codes: 0 = ok, 1 = error, 2 = alert(s) sent
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$TestAlert,
    [switch]$NoAlert,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- paths -----
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptRoot 'config.json' }

# --------------------------------------------------------------- helpers ----
function ConvertTo-HashtableDeep {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-HashtableDeep $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        return @($InputObject | ForEach-Object { ConvertTo-HashtableDeep $_ })
    }
    $h = @{}
    foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }
    return $h
}

function Merge-Deep {
    param([hashtable]$Target, $Source)
    if ($null -eq $Source) { return $Target }
    $src = ConvertTo-HashtableDeep $Source
    if (-not ($src -is [hashtable])) { return $Target }
    foreach ($k in $src.Keys) {
        if ($Target.ContainsKey($k) -and $Target[$k] -is [hashtable] -and $src[$k] -is [hashtable]) {
            Merge-Deep -Target $Target[$k] -Source $src[$k] | Out-Null
        }
        else {
            $Target[$k] = $src[$k]
        }
    }
    return $Target
}

function Read-JsonSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

# ---------------------------------------------------------------- config ----
$defaultConfig = @{
    webhookUrl       = ''
    statePath        = 'state/state.json'
    logPath          = 'logs/health-monitor.log'
    logMaxKB         = 2048
    cooldownMinutes  = 60
    maxAlertsPerDay  = 24
    notifyRecovery   = $true
    trackProcessIo   = $true
    topProcessCount  = 5
    ignoreProcesses  = @('Idle', 'System', 'Registry', 'Memory Compression', 'Secure System')
    watchServices    = @('Audiosrv', 'AudioEndpointBuilder', 'Dnscache', 'WinDefend')
    thresholds       = @{
        processRamMB      = 1500
        processCpuPercent = 70
        processCpuSamples = 3
        totalRamPercent   = 90
        systemCpuPercent  = 90
        systemCpuSamples  = 5
        diskReadMBps      = 50
        diskWriteMBps     = 50
        diskSamples       = 3
    }
}

$cfg = Merge-Deep -Target ($defaultConfig.Clone()) -Source (Read-JsonSafe -Path $ConfigPath)

# optional local overrides (gitignored) - useful for the webhook
$localConfigPath = Join-Path (Split-Path -Parent $ConfigPath) 'config.local.json'
$cfg = Merge-Deep -Target $cfg -Source (Read-JsonSafe -Path $localConfigPath)

function Resolve-PathFromRoot {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $ScriptRoot $Path)
}

$script:StatePath = Resolve-PathFromRoot $cfg.statePath
$script:LogPath = Resolve-PathFromRoot $cfg.logPath
$script:Cfg = $cfg

# --------------------------------------------------------------- logging ----
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not $Quiet) { Write-Host $line }
    $dir = Split-Path -Parent $script:LogPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $script:LogPath) {
        $size = (Get-Item -LiteralPath $script:LogPath).Length
        if ($size -gt ($script:Cfg.logMaxKB * 1KB)) {
            $bak = "$($script:LogPath).1"
            Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $script:LogPath -Destination $bak -Force -ErrorAction SilentlyContinue
        }
    }
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

# ----------------------------------------------------------------- state ----
function New-DefaultState {
    return @{
        timestamp = $null
        disk      = @{ read = $null; write = $null; perf = $null; freq = $null }
        processes = @{}
        streaks   = @{}
        alerts    = @{}
        daily     = @{ date = (Get-Date).ToString('yyyy-MM-dd'); count = 0 }
    }
}

function Get-State {
    $st = New-DefaultState
    if (Test-Path -LiteralPath $script:StatePath) {
        $loaded = Read-JsonSafe -Path $script:StatePath
        if ($loaded) { Merge-Deep -Target $st -Source $loaded | Out-Null }
    }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($st.daily.date -ne $today) { $st.daily = @{ date = $today; count = 0 } }
    return $st
}

function Save-State {
    param([hashtable]$State)
    $dir = Split-Path -Parent $script:StatePath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$($script:StatePath).tmp"
    try {
        ($State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $script:StatePath -Force
    }
    catch { Write-Log "cannot save state: $($_.Exception.Message)" 'ERROR' }
}

# --------------------------------------------------------------- discord ----
function Get-Webhook {
    $u = $env:DISCORD_WEBHOOK_URL
    if ([string]::IsNullOrWhiteSpace($u)) { $u = $script:Cfg.webhookUrl }
    if ([string]::IsNullOrWhiteSpace($u)) { return $null }
    return $u.Trim()
}

function Send-DiscordMessage {
    param(
        [string]$Webhook,
        [string]$Title,
        [string]$Description,
        [int]$Color = 3447003,
        [array]$Fields = @()
    )
    $embed = [ordered]@{
        title       = $Title
        description = $Description
        color       = $Color
        timestamp   = (Get-Date).ToString('o')
        footer      = @{ text = "WinHealthMonitor - $env:COMPUTERNAME" }
    }
    if ($Fields.Count -gt 0) { $embed.fields = @($Fields | Select-Object -First 10) }

    $payload = @{
        username = 'Win Health Monitor'
        embeds   = @($embed)
    } | ConvertTo-Json -Depth 6

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Invoke-RestMethod -Uri $Webhook -Method Post -ContentType 'application/json; charset=utf-8' `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 15 | Out-Null
            return $true
        }
        catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            if ($status -eq 429 -and $attempt -eq 1) {
                Start-Sleep -Seconds 3
                continue
            }
            Write-Log "discord send failed (HTTP $status): $($_.Exception.Message)" 'ERROR'
            return $false
        }
    }
    return $false
}

# -------------------------------------------------------------- metrics -----
function Get-Snapshot {
    param([hashtable]$State)

    $now = Get-Date
    $snap = @{
        timestamp = $now
        ram       = $null
        cpu       = $null
        diskRead  = $null
        diskWrite = $null
        processes = @()
    }

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $totalMB = [double]$os.TotalVisibleMemorySize / 1KB
    $freeMB = [double]$os.FreePhysicalMemory / 1KB
    $snap.ram = @{ totalMB = [math]::Round($totalMB); freeMB = [math]::Round($freeMB); usedPct = [math]::Round((1 - ($freeMB / $totalMB)) * 100, 1) }

    $cpuSample = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq '_Total' }
    if ($cpuSample) { $snap.cpu = [int]$cpuSample.PercentProcessorTime }

    # ---- disk throughput from cumulative raw counters
    $disk = Get-CimInstance Win32_PerfRawData_PerfDisk_PhysicalDisk -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq '_Total' }
    $diskNow = $null
    if ($disk) {
        $diskNow = @{
            read  = [int64]$disk.DiskReadBytesPerSec
            write = [int64]$disk.DiskWriteBytesPerSec
            perf  = [int64]$disk.Timestamp_PerfTime
            freq  = [int64]$disk.Frequency_PerfTime
        }
        if ($State.disk.perf -and $State.disk.freq -and $State.timestamp) {
            $dPerf = $diskNow.perf - [int64]$State.disk.perf
            $gapMin = ($now - [datetime]$State.timestamp).TotalMinutes
            if ($dPerf -gt 0 -and $gapMin -lt 15 -and $diskNow.read -ge [int64]$State.disk.read) {
                $secs = $dPerf / [double]$diskNow.freq
                $snap.diskRead = [math]::Round((($diskNow.read - [int64]$State.disk.read) / 1MB) / $secs, 1)
                $snap.diskWrite = [math]::Round((($diskNow.write - [int64]$State.disk.write) / 1MB) / $secs, 1)
            }
        }
    }

    # ---- per process
    $ignore = @($script:Cfg.ignoreProcesses)
    $cores = [int]$env:NUMBER_OF_PROCESSORS
    if ($cores -le 0) { $cores = 1 }
    $elapsedSec = $null
    if ($State.timestamp) { $elapsedSec = ($now - [datetime]$State.timestamp).TotalSeconds }
    if ($elapsedSec -and ($elapsedSec -lt 5 -or $elapsedSec -gt 900)) { $elapsedSec = $null }

    $ioMap = @{}
    if ($script:Cfg.trackProcessIo) {
        try {
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
                $ioMap["$($_.Name)#$($_.ProcessId)"] = @{
                    read  = [int64]$_.ReadTransferCount
                    write = [int64]$_.WriteTransferCount
                }
            }
        }
        catch { }
    }

    $procs = @()
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue | Where-Object { $ignore -notcontains $_.Name })) {
        $key = "$($p.Name)#$($p.Id)"
        $cpuSec = 0.0
        try { if ($p.CPU) { $cpuSec = [double]$p.CPU } } catch { }

        $row = @{
            name   = $p.Name
            id     = $p.Id
            ramMB  = [math]::Round($p.WorkingSet64 / 1MB)
            cpuSec = $cpuSec
            cpuPct = $null
            ioRead = $null
            ioWrite = $null
        }

        if ($elapsedSec -and $State.processes.ContainsKey($key)) {
            $prev = $State.processes[$key]
            $dCpu = $cpuSec - [double]$prev.cpuSec
            if ($dCpu -ge 0) { $row.cpuPct = [math]::Round(($dCpu / $elapsedSec / $cores) * 100, 1) }
        }

        if ($ioMap.ContainsKey($key) -and $State.processes.ContainsKey($key) -and $elapsedSec) {
            $prev = $State.processes[$key]
            if ($null -ne $prev.ioRead -and $ioMap[$key].read -ge [int64]$prev.ioRead) {
                $row.ioRead = [math]::Round(((($ioMap[$key].read - [int64]$prev.ioRead) / 1MB) / $elapsedSec), 1)
                $row.ioWrite = [math]::Round(((($ioMap[$key].write - [int64]$prev.ioWrite) / 1MB) / $elapsedSec), 1)
            }
        }

        $procs += $row
    }
    $snap.processes = $procs
    $snap.diskRaw = $diskNow
    $snap.ioMap = $ioMap
    return $snap
}

function Update-Streak {
    param([hashtable]$State, [string]$Key, [bool]$Condition)
    $cur = 0
    if ($State.streaks.ContainsKey($Key)) { $cur = [int]$State.streaks[$Key] }
    if ($Condition) { $cur++ } else { $cur = 0 }
    $State.streaks[$Key] = $cur
    return $cur
}

# ------------------------------------------------------------------ main ----
$exitCode = 0

try {
    $state = Get-State
    $snapshot = Get-Snapshot -State $state
    $t = $script:Cfg.thresholds

    # ---------- test alert
    if ($TestAlert) {
        $webhook = Get-Webhook
        if (-not $webhook) {
            Write-Log 'no webhook configured (set DISCORD_WEBHOOK_URL or config.local.json)' 'ERROR'
            exit 1
        }
        $ok = Send-DiscordMessage -Webhook $webhook -Title '✅ Test alert' `
            -Description "Webhook ทำงานปกติ - $env:COMPUTERNAME" -Color 3066993 `
            -Fields @(@{ name = 'เวลา'; value = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); inline = $true })
        if ($ok) { Write-Log 'test alert sent OK' } else { Write-Log 'test alert failed' 'ERROR'; exit 1 }
        exit 0
    }

    $alerts = New-Object System.Collections.ArrayList

    # ---------- RAM per process
    foreach ($p in ($snapshot.processes | Sort-Object ramMB -Descending | Select-Object -First $script:Cfg.topProcessCount)) {
        if ($p.ramMB -ge $t.processRamMB) {
            [void]$alerts.Add(@{
                    key      = "ram:$($p.name)"
                    severity = 'warning'
                    title    = "RAM สูง: $($p.name)"
                    detail   = "ใช้ RAM $($p.ramMB) MB (เกินเกณฑ์ $($t.processRamMB) MB)"
                    fields   = @(
                        @{ name = 'Process'; value = "$($p.name) (PID $($p.id))"; inline = $true },
                        @{ name = 'RAM'; value = "$($p.ramMB) MB"; inline = $true }
                    )
                })
        }
    }

    # ---------- CPU per process (sustained)
    foreach ($p in $snapshot.processes) {
        if ($null -eq $p.cpuPct) { continue }
        $streak = Update-Streak -State $state -Key "cpu:$($p.name)" -Condition ($p.cpuPct -ge $t.processCpuPercent)
        if ($streak -ge $t.processCpuSamples) {
            [void]$alerts.Add(@{
                    key      = "cpu:$($p.name)"
                    severity = 'warning'
                    title    = "CPU สูงต่อเนื่อง: $($p.name)"
                    detail   = "ใช้ CPU $($p.cpuPct)% ติดต่อ $streak รอบ (เกณฑ์ $($t.processCpuPercent)%)"
                    fields   = @(@{ name = 'Process'; value = "$($p.name) (PID $($p.id))"; inline = $true })
                })
        }
    }

    # ---------- disk throughput (sustained)
    if ($null -ne $snapshot.diskRead) {
        $diskHit = ($snapshot.diskRead -ge $t.diskReadMBps) -or ($snapshot.diskWrite -ge $t.diskWriteMBps)
        $streak = Update-Streak -State $state -Key 'disk' -Condition $diskHit
        if ($streak -ge $t.diskSamples) {
            $topIo = $snapshot.processes |
                Where-Object { $null -ne $_.ioWrite } |
                Sort-Object { [double]$_.ioRead + [double]$_.ioWrite } -Descending |
                Select-Object -First 3
            $fields = @(
                @{ name = 'อ่าน'; value = "$($snapshot.diskRead) MB/s"; inline = $true },
                @{ name = 'เขียน'; value = "$($snapshot.diskWrite) MB/s"; inline = $true },
                @{ name = 'ต่อเนื่อง'; value = "$streak รอบ"; inline = $true }
            )
            foreach ($p in $topIo) {
                $fields += @{ name = "I/O: $($p.name)"; value = "R $($p.ioRead) / W $($p.ioWrite) MB/s"; inline = $false }
            }
            [void]$alerts.Add(@{
                    key      = 'disk'
                    severity = 'critical'
                    title    = 'ดิสก์ทำงานหนักผิดปกติ'
                    detail   = "เกินเกณฑ์ $($t.diskReadMBps)/$($t.diskWriteMBps) MB/s ติดต่อ $streak รอบ (อ่าน $($snapshot.diskRead) / เขียน $($snapshot.diskWrite) MB/s)"
                    fields   = $fields
                })
        }
    }

    # ---------- total RAM
    if ($snapshot.ram.usedPct -ge $t.totalRamPercent) {
        $topRam = $snapshot.processes | Sort-Object ramMB -Descending | Select-Object -First 3
        $detail = ($topRam | ForEach-Object { "$($_.name) $($_.ramMB) MB" }) -join ', '
        [void]$alerts.Add(@{
                key      = 'ramtotal'
                severity = 'critical'
                title    = 'RAM รวมสูง'
                detail   = "ใช้ $($snapshot.ram.usedPct)% (เหลือ $($snapshot.ram.freeMB) MB) - top: $detail"
                fields   = @()
            })
    }

    # ---------- system CPU (sustained)
    if ($null -ne $snapshot.cpu) {
        $streak = Update-Streak -State $state -Key 'syscpu' -Condition ($snapshot.cpu -ge $t.systemCpuPercent)
        if ($streak -ge $t.systemCpuSamples) {
            [void]$alerts.Add(@{
                    key      = 'syscpu'
                    severity = 'warning'
                    title    = 'CPU รวมสูงต่อเนื่อง'
                    detail   = "ใช้ CPU $($snapshot.cpu)% ติดต่อ $streak รอบ"
                    fields   = @()
                })
        }
    }

    # ---------- watched services
    foreach ($svcName in @($script:Cfg.watchServices)) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            [void]$alerts.Add(@{
                    key      = "svc:$svcName"
                    severity = 'critical'
                    title    = "Service หยุดทำงาน: $svcName"
                    detail   = "สถานะปัจจุบัน: $($svc.Status)"
                    fields   = @()
                })
        }
    }

    # ---------- decide what to send (cooldown + daily cap + recovery)
    $nowIso = (Get-Date).ToString('o')
    $webhook = Get-Webhook
    $toSend = @()
    $recovered = @()
    $activeKeys = @($alerts | ForEach-Object { $_.key })

    foreach ($a in $alerts) {
        $prev = $null
        if ($state.alerts.ContainsKey($a.key)) { $prev = $state.alerts[$a.key] }
        $isNew = (-not $prev) -or (-not [bool]$prev.active)
        $cooledDown = $true
        if ($prev -and $prev.lastSent) {
            $cooledDown = ((Get-Date) - [datetime]$prev.lastSent).TotalMinutes -ge $script:Cfg.cooldownMinutes
        }
        if ($isNew -or $cooledDown) { $toSend += $a }
    }

    if ($script:Cfg.notifyRecovery) {
        foreach ($k in @($state.alerts.Keys)) {
            if ([bool]$state.alerts[$k].active -and ($activeKeys -notcontains $k)) { $recovered += $k }
        }
    }

    $messages = 0
    $sentAny = $false

    if (($toSend.Count -gt 0 -or $recovered.Count -gt 0) -and -not $NoAlert -and $webhook) {
        $remaining = [int]$script:Cfg.maxAlertsPerDay - [int]$state.daily.count
        if ($remaining -le 0) {
            Write-Log "daily alert cap reached ($($script:Cfg.maxAlertsPerDay)), suppressing $($toSend.Count) alert(s)" 'WARN'
        }
        else {
            if ($toSend.Count -gt 0) {
                $fields = @()
                foreach ($a in ($toSend | Select-Object -First 8)) {
                    $value = $a.detail
                    if ($a.fields.Count -gt 0) {
                        $value += "`n" + (($a.fields | ForEach-Object { "$($_.name): $($_.value)" }) -join ' | ')
                    }
                    $fields += @{ name = $a.title; value = $value; inline = $false }
                }
                $title = if ($toSend.Count -eq 1) { "⚠️ $($toSend[0].title)" } else { "⚠️ ตรวจพบ $($toSend.Count) ความผิดปกติ" }
                $sev = if (($toSend | Where-Object { $_.severity -eq 'critical' }).Count -gt 0) { 'critical' } else { 'warning' }
                $color = if ($sev -eq 'critical') { 15158332 } else { 15105570 }

                if (Send-DiscordMessage -Webhook $webhook -Title $title -Description "พบปัญหาเมื่อ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Color $color -Fields $fields) {
                    $sentAny = $true
                    $messages++
                    $state.daily.count = [int]$state.daily.count + 1
                    foreach ($a in $toSend) {
                        $state.alerts[$a.key] = @{ active = $true; lastSent = $nowIso; severity = $a.severity }
                    }
                    Write-Log ("alert sent: " + (($toSend | ForEach-Object { $_.key }) -join ', ')) 'WARN'
                }
            }

            if ($recovered.Count -gt 0) {
                $remaining = [int]$script:Cfg.maxAlertsPerDay - [int]$state.daily.count
                if ($remaining -gt 0) {
                    $rFields = @($recovered | ForEach-Object { @{ name = $_; value = 'กลับมาปกติแล้ว'; inline = $true } })
                    if (Send-DiscordMessage -Webhook $webhook -Title '✅ กลับมาปกติ' -Description 'ค่าที่เคยผิดปกติกลับเข้าสู่เกณฑ์แล้ว' -Color 3066993 -Fields $rFields) {
                        $sentAny = $true
                        $messages++
                        $state.daily.count = [int]$state.daily.count + 1
                        foreach ($k in $recovered) {
                            $state.alerts[$k] = @{ active = $false; lastSent = $nowIso; severity = 'info' }
                        }
                        Write-Log ("recovery sent: " + ($recovered -join ', '))
                    }
                }
            }
        }
    }

    if ($NoAlert -or -not $webhook) {
        foreach ($a in $alerts) {
            $state.alerts[$a.key] = @{ active = $true; lastSent = $null; severity = $a.severity }
        }
        if (-not $webhook -and $alerts.Count -gt 0) { Write-Log "no webhook configured - $($alerts.Count) alert(s) not sent" 'WARN' }
    }

    # ---------- persist snapshot for next run
    $state.timestamp = $nowIso
    if ($snapshot.diskRaw) { $state.disk = $snapshot.diskRaw }
    $newProcs = @{}
    foreach ($p in $snapshot.processes) {
        $k = "$($p.name)#$($p.id)"
        $entry = @{ cpuSec = $p.cpuSec; ioRead = $null; ioWrite = $null }
        if ($snapshot.ioMap -and $snapshot.ioMap.ContainsKey($k)) {
            $entry.ioRead = $snapshot.ioMap[$k].read
            $entry.ioWrite = $snapshot.ioMap[$k].write
        }
        $newProcs[$k] = $entry
    }
    $state.processes = $newProcs

    # drop idle streaks / resolved alerts
    foreach ($k in @($state.streaks.Keys)) {
        if ([int]$state.streaks[$k] -eq 0 -and -not ($state.alerts.ContainsKey($k) -and [bool]$state.alerts[$k].active)) {
            $state.streaks.Remove($k)
            if ($state.alerts.ContainsKey($k)) { $state.alerts.Remove($k) }
        }
    }

    Save-State -State $state

    # ---------- summary
    $diskTxt = if ($null -ne $snapshot.diskRead) { "r$($snapshot.diskRead)/w$($snapshot.diskWrite) MB/s" } else { 'n/a' }
    Write-Log ("ram=$($snapshot.ram.usedPct)% cpu=$($snapshot.cpu)% disk=$diskTxt alerts=$($alerts.Count) sent=$messages")

    if ($sentAny) { $exitCode = 2 }
}
catch {
    Write-Log "fatal: $($_.Exception.Message)" 'ERROR'
    $exitCode = 1
}

exit $exitCode
