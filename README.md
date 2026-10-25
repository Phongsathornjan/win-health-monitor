# WinHealthMonitor

มอนิเตอร์สุขภาพเครื่อง Windows แบบเบา ๆ ที่คอยจับ **process กิน RAM / CPU / ดิสก์ผิดปกติ** และ **service ที่ควรทำงานแต่ดับไป** แล้วส่งแจ้งเตือนเข้า **Discord** ผ่าน webhook

ออกแบบมาให้รันทุก 1 นาทีจาก Task Scheduler — กิน resource แทบไม่รู้สึก (วัดจริงบน Ryzen 7 7435HS: **~20–40 ms CPU ต่อรอบ**, RAM ~60 MB ชั่วคราว, ดิสก์ ~1–3 MB/วัน)

---

## ทำอะไรได้บ้าง

| กติกา | ค่าเริ่มต้น | ลักษณะ |
|---|---|---|
| process ใช้ RAM เกิน | 1,500 MB | แจ้งทันที |
| process ใช้ CPU เกิน | 70% ติดต่อ 3 รอบ | ต้องต่อเนื่อง |
| ดิสก์อ่าน/เขียนเกิน | 50 MB/s ติดต่อ 3 รอบ | ต้องต่อเนื่อง |
| RAM รวมของระบบ | 90% | แจ้งทันที |
| CPU รวมของระบบ | 90% ติดต่อ 5 รอบ | ต้องต่อเนื่อง |
| service ที่เฝ้าอยู่ดับ | Audiosrv, AudioEndpointBuilder, Dnscache, WinDefend | แจ้งทันที |
| กลับมาปกติ | เปิดใช้ | แจ้งเตือนสีเขียว |

พร้อมระบบกันสแปม: **cooldown ต่อเรื่อง (60 นาที)**, **เพดานข้อความ/วัน (24)**, รวมทุก alert ของรอบนั้นเป็น **ข้อความเดียว**

---

## ความต้องการ

- Windows 10 / 11
- Windows PowerShell 5.1 (มีมาให้อยู่แล้ว) — ไม่ต้องลงโมดูลเพิ่ม
- สิทธิ์ผู้ใช้ธรรมดา (ไม่ต้อง admin) — อ่าน counter ทั้งหมดที่ใช้เป็นแบบ user-level
- Discord webhook URL

---

## ติดตั้งใน 4 ขั้น

### 1) สร้าง Discord webhook

1. เปิด Discord → **Server Settings → Integrations → Webhooks → New Webhook**
2. เลือก channel ปลายทาง → **Copy Webhook URL**
3. เก็บ URL ไว้ (จะใช้ในขั้นถัดไป)

### 2) ตั้งค่า webhook (ไม่เก็บลง git)

```powershell
# แบบถาวรระดับผู้ใช้ (แนะนำ)
[Environment]::SetEnvironmentVariable('DISCORD_WEBHOOK_URL', 'https://discord.com/api/webhooks/...', 'User')
```

หรือจะใช้ไฟล์ก็ได้ (ถูก gitignore ไว้แล้ว):

```powershell
Copy-Item config.local.example.json config.local.json
notepad config.local.json
```

### 3) ทดสอบ

```powershell
# เปิด PowerShell ใหม่ก่อน (ให้อ่าน env var ใหม่)
cd C:\Users\Phongsathorn\projects\win-health-monitor

.\Watch-Health.ps1 -TestAlert      # ต้องมีข้อความทดสอบใน Discord
.\Watch-Health.ps1 -NoAlert        # รันจริง 1 รอบ แต่ไม่ส่ง Discord (ดูผลใน console)
```

### 4) ลง Task Scheduler (รันทุก 1 นาที)

```powershell
.\Install-Task.ps1                 # ค่าเริ่มต้น: ทุก 1 นาที
.\Install-Task.ps1 -IntervalMinutes 5   # หรือปรับตามต้องการ

Start-ScheduledTask -TaskName WinHealthMonitor   # ลองรันเดี๋ยวนี้
```

ถอนออก:

```powershell
.\Uninstall-Task.ps1
```

---

## ตัวอย่างข้อความที่ได้รับ

```
⚠️ ดิสก์ทำงานหนักผิดปกติ
พบปัญหาเมื่อ 2026-10-25 15:04:12
อ่าน: 194.4 MB/s | เขียน: 200.4 MB/s | ต่อเนื่อง: 3 รอบ
I/O: svchost: R 196.2 / W 0.1 MB/s
I/O: MsMpEng: R 27.9 / W 0.3 MB/s
```

```
⚠️ RAM สูง: DtsApo4Service
Process: DtsApo4Service (PID 7160) | RAM: 2262 MB
```

```
✅ กลับมาปกติ
ดิสก์: กลับมาปกติแล้ว
```

---

## ตั้งค่า (`config.json`)

| key | ค่าเริ่มต้น | ความหมาย |
|---|---|---|
| `webhookUrl` | `""` | ใช้เมื่อไม่ได้ตั้ง env var `DISCORD_WEBHOOK_URL` |
| `statePath` | `state/state.json` | ไฟล์เก็บสถานะระหว่างรอบ |
| `logPath` | `logs/health-monitor.log` | ไฟล์ log (rotate อัตโนมัติ) |
| `logMaxKB` | `2048` | ขนาดสูงสุดก่อน rotate |
| `cooldownMinutes` | `60` | เว้นกี่นาทีจึงแจ้งเรื่องเดิมซ้ำ |
| `maxAlertsPerDay` | `24` | เพดานข้อความ/วัน (กันสแปม) |
| `notifyRecovery` | `true` | แจ้งเมื่อกลับมาปกติ |
| `trackProcessIo` | `true` | เก็บ I/O ต่อ process (ปิดได้ถ้าอยากเบาที่สุด) |
| `topProcessCount` | `5` | จำนวน process ที่เอามาคิดเรื่อง RAM |
| `ignoreProcesses` | Idle, System, ... | ข้าม process พวกนี้ |
| `watchServices` | Audiosrv, ... | service ที่ต้อง Running ตลอด |
| `thresholds.processRamMB` | `1500` | เกณฑ์ RAM ต่อ process (MB) |
| `thresholds.processCpuPercent` | `70` | เกณฑ์ CPU ต่อ process (%) |
| `thresholds.processCpuSamples` | `3` | ต้องเกินติดกันกี่รอบ |
| `thresholds.totalRamPercent` | `90` | เกณฑ์ RAM รวม (%) |
| `thresholds.systemCpuPercent` | `90` | เกณฑ์ CPU รวม (%) |
| `thresholds.systemCpuSamples` | `5` | ต้องเกินติดกันกี่รอบ |
| `thresholds.diskReadMBps` | `50` | เกณฑ์อ่านดิสก์ (MB/s) |
| `thresholds.diskWriteMBps` | `50` | เกณฑ์เขียนดิสก์ (MB/s) |
| `thresholds.diskSamples` | `3` | ต้องเกินติดกันกี่รอบ |

> ปรับค่าตามเครื่องคุณ: ถ้า RAM 32 GB ก็ขยับ `processRamMB` ขึ้นได้, ถ้าเป็น NVMe เร็ว ๆ ก็ขยับ `diskReadMBps` ขึ้น

---

## หลักการทำงาน (สรุป)

```
Task Scheduler (ทุก 1 นาที)
        │
        ▼
  Watch-Health.ps1
        │  1. อ่าน metrics (RAM, CPU, disk raw counter, process list)
        │  2. เทียบกับ state รอบก่อน → คำนวณ disk MB/s, CPU%/process, I/O ต่อ process
        │  3. ประเมินกติกา + นับ streak (ต้องเกินติดกัน N รอบ)
        │  4. ตัดสินว่าจะส่งไหม (cooldown / เพดานต่อวัน / recovery)
        │  5. ส่ง Discord embed (1 ข้อความต่อรอบ)
        ▼
  state/state.json  +  logs/health-monitor.log
```

รายละเอียดเชิงลึก (สูตรคำนวณ, state schema, state machine, เหตุผลการเลือก counter) อยู่ใน **[docs/how-it-works.md](docs/how-it-works.md)**

---

## Resource ที่ใช้จริง (วัดบนเครื่องนี้)

| งาน | CPU/รอบ | เวลา wall |
|---|---|---|
| `Get-Process` + จัดอันดับ RAM | 10 ms | 9 ms |
| อ่าน disk counter (CIM) | 14 ms | ~400 ms (รอ I/O) |
| อ่าน process counter (CIM) | 16 ms | ~345 ms |
| รวมต่อรอบ (โดยประมาณ) | **20–40 ms** | 0.5–1 s |

- 1,440 รอบ/วัน → CPU รวม ~1–2 นาที/วัน (~0.03% ของ 16 threads)
- RAM: PowerShell ~55–70 MB ตอนรัน แล้วจบไป (ไม่มีอะไรค้าง)
- ดิสก์: log ~200 bytes/รอบ ≈ 300 KB/วัน (มี rotate ที่ 2 MB)
- เน็ตเวิร์ก: เฉพาะตอนมี alert (~1–2 KB ต่อข้อความ)

---

## ความปลอดภัย

- **ห้าม commit webhook URL** — ไฟล์ `config.local.json` และ `state/` ถูก `.gitignore` ไว้แล้ว
- แนะนำให้ตั้งผ่าน **environment variable** มากกว่าใส่ในไฟล์
- log ไม่เคยพิมพ์ webhook URL ออกมา (และไม่ log ข้อมูลติตต่อผู้ใช้)
- สคริปต์ไม่ต้อง admin และไม่แก้ registry/service ใด ๆ

---

## Troubleshooting

| อาการ | สาเหตุ/วิธีแก้ |
|---|---|
| ไม่มีข้อความทดสอบ | ยังไม่ได้เปิด PowerShell ใหม่หลังตั้ง env var / URL ผิด / webhook ถูกลบ |
| ขึ้น `HTTP 401` | webhook URL ไม่ถูกต้องหรือถูกลบแล้ว |
| ขึ้น `HTTP 429` | ส่งถี่เกิน rate limit ของ Discord — สคริปต์จะลองซ้ำ 1 ครั้ง (ปกติไม่เกิดเพราะมี cooldown) |
| Alert ไม่ยอมส่งซ้ำ | เป็นเรื่องปกติ ถูก cooldown 60 นาที หรือชนเพดาน `maxAlertsPerDay` |
| ค่า disk ขึ้น `n/a` | รอบแรกยังไม่มีข้อมูลเปรียบเทียบ (ต้องรัน 2 รอบขึ้นไป) หรือเครื่องเพิ่ง resume จาก sleep >15 นาที |
| อยากดูว่ารอบล่าสุดเป็นยังไง | `Get-Content logs/health-monitor.log -Tail 20` |
| Task ไม่รัน | `Get-ScheduledTaskInfo -TaskName WinHealthMonitor` ดู `LastTaskResult` |

---

## License

MIT — ดู [LICENSE](LICENSE)
