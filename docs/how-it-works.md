# หลักการทำงาน (How it works)

เอกสารนี้อธิบายสิ่งที่สคริปต์ทำจริง ๆ ทีละขั้น ทำไมถึงเลือกวิธีนี้ และข้อจำกัดที่ต้องรู้

---

## 1. ภาพรวม pipeline

```
┌─────────────────────┐
│  Task Scheduler     │  ทุก 1 นาที (repetition ไม่มีวันหมดอายุ)
│  WinHealthMonitor   │
└──────────┬──────────┘
           │ powershell.exe -File Watch-Health.ps1 -Quiet
           ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. LOAD                                                      │
│    config.json + config.local.json + .env + env var           │
│    state/state.json  (ผลรอบก่อน)                              │
├──────────────────────────────────────────────────────────────┤
│ 2. SAMPLE                                                    │
│    RAM:   Win32_OperatingSystem                              │
│    CPU:   Win32_PerfFormattedData_PerfOS_Processor           │
│    Disk:  Win32_PerfRawData_PerfDisk_PhysicalDisk (raw)      │
│    Proc:  Get-Process  +  Win32_Process (I/O สะสม)           │
├──────────────────────────────────────────────────────────────┤
│ 3. DERIVE                                                    │
│    disk MB/s   = Δbytes / Δtime                              │
│    cpu %/proc  = ΔcpuSec / Δtime / cores * 100               │
│    io MB/s/proc= Δtransfer / Δtime                           │
├──────────────────────────────────────────────────────────────┤
│ 4. EVALUATE                                                  │
│    เทียบ thresholds + นับ streak + ตรวจ service              │
├──────────────────────────────────────────────────────────────┤
│ 5. DECIDE                                                    │
│    ใหม่? / หมด cooldown? / ชนเพดานวัน? / กลับปกติ?           │
├──────────────────────────────────────────────────────────────┤
│ 6. NOTIFY  → Discord webhook (1 embed ต่อรอบ)                │
│ 7. PERSIST → state.json (atomic write) + log (rotate)        │
└──────────────────────────────────────────────────────────────┘
```

## 1.1 ลำดับการอ่านค่า (config resolution)

ค่าตั้งต้นในสคริปต์ → ทับด้วย `config.json` → ทับด้วย `config.local.json` (ถ้ามี)

ส่วน **webhook URL** มีลำดับแยก (ตัวแรกที่เจอชนะ):

| ลำดับ | แหล่ง | ใช้เมื่อ |
|---|---|---|
| 1 | env var `DISCORD_WEBHOOK_URL` | ใช้ชั่วคราว / CI |
| 2 | ไฟล์ `.env` (`dotEnvFile` ใน config) | **วิธีหลักที่แนะนำ** |
| 3 | `config.local.json` → `webhookUrl` | ทางเลือก |
| 4 | `config.json` → `webhookUrl` | ค่าเริ่มต้น (ว่าง) |

ตัวอ่าน `.env` รองรับ: คอมเมนต์ `#`, บรรทัดว่าง, `export KEY=VALUE`, และค่าที่ครอบด้วย `"` หรือ `'`
อ่านไฟล์ใหม่ทุกครั้งที่รัน → แก้ `.env` แล้วมีผลรอบถัดไปทันที (ไม่ต้องรีสตาร์ท Task)

---

## 2. ทำไมไม่ใช้ `% Disk Time` ของ Windowsบน NVMe หลายรุ่น (รวมถึง Samsung PM9A1 + Microsoft NVMe driver บน Windows 11 25H2) ตัวชี้วัด **% Disk Time / % Idle Time** รายงานผิดพลาดได้:

- วัดจริงบนเครื่องทดสอบ: `busy = 80–370%`, `idle = 1–8%` **ตลอดเวลา** แม้ขณะที่ทุก process รวมกันทำ I/O ไม่ถึง 6 MB/s
- ขณะเดียวกัน ค่าที่ "นิ่ง" และตรวจสอบได้คือ **ตัวนับไบต์สะสม (cumulative byte counter)**

ดังนั้นสคริปต์นี้จึง:

1. อ่าน `Win32_PerfRawData_PerfDisk_PhysicalDisk` (ค่าสะสม ไม่ใช่ค่าที่ Windows แปลงเป็น % แล้ว)
2. เก็บค่าลง state พร้อม `Timestamp_PerfTime` / `Frequency_PerfTime`
3. รอบถัดไปคำนวณผลต่างเอง:

```
seconds = (perf_now - perf_prev) / frequency
readMBs = (bytes_now - bytes_prev) / 1MB / seconds
```

**ข้อดี:** ได้ตัวเลข MB/s ที่ตรวจสอบซ้ำได้ด้วยเครื่องมืออื่น และไม่ขึ้นกับ bug ของ %DiskTime

**Guard:** ถ้ารอบก่อนเกิน 15 นาที (เช่น เครื่อง sleep/resume) หรือตัวนับถูกรีเซ็ต (`bytes_now < bytes_prev`) จะคืน `null` แล้วข้ามการประเมินดิสก์ในรอบนั้น

---

## 3. CPU ต่อ process

`Process.TotalProcessorTime` เป็นเวลาสะสม (CPU seconds) ไม่ใช่ %

```
cpuPct = (cpuSec_now - cpuSec_prev) / elapsedSec / numberOfCores * 100
```

- หารด้วยจำนวน logical cores เพื่อให้เทียบกับ Task Manager ได้
- ถ้าเป็น process ที่เพิ่งเกิด (ไม่มีค่าก่อนหน้า) จะเป็น `null` และข้ามไป 1 รอบ
- ถ้า elapsed < 5 วินาที หรือ > 15 นาที จะไม่คำนวณ (กันค่าผิดปกติ)

---

## 4. I/O ต่อ process

ใช้ `Win32_Process.ReadTransferCount / WriteTransferCount` ซึ่งเป็น **ไบต์สะสม** เช่นเดียวกับดิสก์ — เก็บค่ารวมลง state แล้วหาผลต่างรอบถัดไป

ข้อจำกัดที่ต้องรู้:

- I/O ที่เกิดจาก **memory-mapped file / cache flush** อาจไม่ถูกนับใน process counter (ไปนับที่ `System`)
- ถ้า process ตายแล้วเกิดใหม่ key จะเปลี่ยน (key = `ชื่อ#PID`) → รอบนั้นจะไม่มีค่า I/O
- เปิด/ปิดได้ด้วย `trackProcessIo` (ปิด = เบาลง ~15 ms CPU/รอบ แต่จะไม่รู้ว่าใครกินดิสก์)

---

## 5. กติกาแบบ "ต่อเนื่อง N รอบ" (streak)

ปัญหาบางอย่างเป็น spike ชั่ววูบ (เช่น เปิดโปรแกรม) จึงต้องกรองด้วยการนับรอบติดกัน:

```
streak = condition ? streak + 1 : 0
alert  = streak >= samples
```

ใช้กับ: CPU ต่อ process, ดิสก์, CPU รวม
ไม่ใช้กับ (แจ้งทันที): RAM ต่อ process, RAM รวม, service ดับ

---

## 6. State machine ของการแจ้งเตือน

แต่ละ "เรื่อง" มี key คงที่ เช่น `ram:chrome`, `disk`, `svc:WinDefend`

```
                    ┌──────────────┐
   condition true   │              │  cooldown หมด + ยังผิดปกติ
  ┌────────────────►│   ACTIVE     ├───────────────► ส่งซ้ำ
  │                 │              │
  │                 └──────┬───────┘
  │                        │ condition false
  │                        ▼
  │                 ┌──────────────┐
  └─────────────────┤  RECOVERED   │  ส่งข้อความเขียว (ถ้า notifyRecovery)
                    └──────────────┘
```

กติกาการส่งในแต่ละรอบ:

```
if (ยังไม่เคยแจ้ง)                    → ส่ง
else if (now - lastSent >= cooldown)  → ส่งซ้ำ
else                                  → เงียบ
if (daily.count >= maxAlertsPerDay)   → ระงับทั้งหมด (log ไว้)
```

ทุก alert ที่เกิดในรอบเดียวกันจะถูกรวมเป็น **ข้อความเดียว** (embed เดียว) เพื่อไม่ให้ช่อง Discord รก

---

## 7. โครงสร้าง state (`state/state.json`)

```jsonc
{
  "timestamp": "2026-10-25T15:04:12.1234567+07:00",
  "disk": { "read": 293915140096, "write": 296411303936,
            "perf": 123456789, "freq": 10000000 },
  "processes": {
    "chrome#1234": { "cpuSec": 1523.4, "ioRead": 812345678, "ioWrite": 45678901 }
  },
  "streaks": { "disk": 2, "cpu:MsMpEng": 0 },
  "alerts": {
    "disk": { "active": true, "lastSent": "2026-10-25T15:00:00+07:00", "severity": "critical" }
  },
  "daily": { "date": "2026-10-25", "count": 3 }
}
```

- เขียนแบบ **atomic** (เขียน `.tmp` แล้ว `Move-Item -Force`) — ถ้าไฟล์เสียหายจะเริ่มจาก state ว่างแทนที่จะ crash
- `daily` จะรีเซ็ตอัตโนมัติเมื่อขึ้นวันใหม่
- ไฟล์นี้อยู่ใน `.gitignore` (เป็นข้อมูลเฉพาะเครื่อง)

---

## 8. Discord payload

```json
{
  "username": "Win Health Monitor",
  "embeds": [{
    "title": "⚠️ ดิสก์ทำงานหนักผิดปกติ",
    "description": "พบปัญหาเมื่อ 2026-10-25 15:04:12",
    "color": 15158332,
    "timestamp": "2026-10-25T15:04:12.0000000+07:00",
    "fields": [
      { "name": "อ่าน", "value": "194.4 MB/s", "inline": true },
      { "name": "เขียน", "value": "200.4 MB/s", "inline": true },
      { "name": "I/O: svchost", "value": "R 196.2 / W 0.1 MB/s", "inline": false }
    ],
    "footer": { "text": "WinHealthMonitor - DESKTOP-XXX" }
  }]
}
```

- สี: แดง `15158332` (critical), ส้ม `15105570` (warning), เขียว `3066993` (recovery/test)
- ถ้าโดน `HTTP 429` จะรอ 3 วินาทีแล้วลองซ้ำ 1 ครั้ง
- URL ไม่ถูก log หรือพิมพ์ออก console

---

## 9. Log

```
2026-10-25 15:04:12 [WARN] alert sent: disk
2026-10-25 15:04:12 [INFO] ram=41.2% cpu=6% disk=r194.4/w200.4 MB/s alerts=1 sent=1
```

- 1 บรรทัดต่อรอบ (~200 bytes) → ~300 KB/วัน
- เกิน `logMaxKB` จะ rotate เป็น `health-monitor.log.1` (เก็บแค่ 1 ไฟล์เก่า)

---

## 10. ทางเลือกที่พิจารณาแล้วไม่เลือก

| ทางเลือก | เหตุผลที่ไม่ใช้ |
|---|---|
| Windows Performance Counter Alert (Data Collector) | ตั้ง threshold ได้ แต่ส่ง Discord ไม่ได้ ต้องพ่วง script อยู่ดี |
| Windows Event Log + Task trigger on event | delay การแจ้งเตือน และตั้ง condition ซับซ้อน |
| Service (C#/Go) | เบากว่าและแม่นกว่า แต่ติดตั้ง/ดูแลยากเกินความจำเป็น |
| WMI event subscription (`__InstanceCreationEvent`) | กิน resource ฝั่ง WMI มาก และจับ "ค่าสูงต่อเนื่อง" ไม่ได้ |
| `Get-Counter` แบบ path ภาษาอังกฤษ | path ถูกแปลตาม locale (Windows ไทยอาจพัง) — CIM ปลอดภัยกว่า |

---

## 11. ข้อจำกัด

- Task Scheduler ทำงานเฉพาะตอน **user logon** (LogonType = InteractiveToken) — ไม่ใช่ Windows Service
- ถ้าเครื่อง sleep อยู่ จะไม่เก็บข้อมูล (ตามด้วย guard 15 นาทีตอนตื่น)
- ไม่ได้แยกตาม disk/volume — ใช้ `_Total` ของ physical disk
- process ที่กิน RAM แบบ private แต่ working set ต่ำ อาจไม่ถูกจับ (ใช้ WorkingSet64 เป็นหลัก)
- ไม่มี retry แบบ exponential สำหรับ Discord (แค่ 1 ครั้งเมื่อ 429)
