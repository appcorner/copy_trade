นี่คือ **สรุปข้อมูลระบบ Copy Trade (Elixir System)** ฉบับสมบูรณ์ครับ

คุณสามารถ Copy ข้อความทั้งหมดนี้ เก็บใส่ Notepad หรือใช้เป็น **Context Prompt** เมื่อเปิดห้อง Chat ใหม่ เพื่อให้ AI เข้าใจโครงสร้างระบบได้ทันทีโดยไม่ต้องเล่าใหม่ครับ

---

# 📘 System Architecture Summary: Elixir Copy Trade Platform

## 1. Tech Stack & Infrastructure

* **Backend:** Elixir (Phoenix Framework 1.7+, LiveView)
* **Database:** PostgreSQL (Normalized Schema)
* **Protocol:** TCP Socket (Custom Protocol for MT5 Communication)
* **Frontend:** Phoenix LiveView + Tailwind CSS
* **Trading Terminal:** MetaTrader 5 (MQL5)
* **Deployment:** Docker Container on Cloud Host (2 vCPU, 4GB RAM)
* *Capacity Estimate:* ~300-500 Active Slaves per Master / ~10-20 Concurrent Masters.



---

## 2. Database Schema (Normalized)

### A. Users (`users`)

* เก็บข้อมูล Login, Role (`master`, `follower`)
* **Key Fields:** `api_key` (สำหรับ Slave), `master_token` (สำหรับ Master), `role`

### B. Master Trades (`master_trades`)

* เก็บ Signal ต้นฉบับจาก Master (1 Row ต่อ 1 Order ของ Master)
* **Key Fields:** `ticket` (Master Ticket), `symbol`, `type` (BUY/SELL), `price`, `volume`, `sl`, `tp`, `status`

### C. Trade Pairs (`trade_pairs`)

* เก็บข้อมูลการตามของ Follower (ผูกกับ Master Trade)
* **Key Fields:**
* `master_trade_id` (FK -> master_trades)
* `user_id` (FK -> users)
* `slave_ticket` (Ticket จริงในพอร์ต Slave)
* `slave_volume` (Lot ที่ออกจริง)
* `slave_type` (BUY/SELL ที่ออกจริง - รองรับ Reverse Trade)
* `status` (PENDING -> OPEN -> CLOSED)
* `profit`, `close_price`



---

## 3. Workflow & Data Flow

### Step 1: Signal Reception (Master)

1. **Master EA** ส่ง TCP Command: `CMD_OPEN|TYPE|SYMBOL|PRICE|LOT|SL|TP|TICKET`
2. **TCP Server** รับข้อมูล -> บันทึกลง Table `master_trades`.
3. **PubSub** Broadcast สัญญาณไปยัง Follower Worker ที่เกี่ยวข้อง.

### Step 2: Signal Processing (Follower)

1. **Follower Worker** รับ Signal -> ตรวจสอบเงื่อนไข (Subscription).
2. คำนวณ Money Management (Lot Multiplier / Fixed).
3. ตรวจสอบเงื่อนไขพิเศษ:
* **Min Lot Filter:** กรองไม้เล็กออก.
* **Reverse Trade:** กลับด้าน BUY/SELL และสลับ SL/TP.


4. สร้าง Record ใน `trade_pairs` สถานะ **PENDING**.
5. ส่ง TCP Command ไปหา Slave EA.

### Step 3: Execution (Slave EA)

1. **Slave EA** รับคำสั่ง -> ทำการ **Symbol Mapping** (เช่น GOLD -> XAUUSD).
2. ส่งคำสั่งเปิด Order ไปที่โบรกเกอร์.
3. เมื่อเปิดสำเร็จ -> ส่ง **ACK** กลับ Server: `ACK_OPEN|MST_TICKET|SLV_TICKET|SLV_LOT|SLV_TYPE`.

### Step 4: Acknowledge (Server)

1. **TCP Server** รับ ACK.
2. อัปเดต `trade_pairs` เป็นสถานะ **OPEN** พร้อมบันทึก `slave_ticket`, `slave_volume`, `slave_type`.

---

## 4. Key Features & Logic

### ฝั่ง Backend (Elixir)

* **Active Menu Logic:** ใช้ `app.html.heex` ร่วมกับ Hook `mount_current_path` เพื่อเปลี่ยนสีเมนู (Active State) ได้ถูกต้องทั้ง Page Controller และ LiveView.
* **Dashboard:**
* **Master View:** แสดง `Master Token`.
* **Follower View:** แสดง Portfolio และ `API Key`.
* **Logic:** แสดงผล Type โดยเทียบ `master_trades.type` vs `trade_pairs.slave_type` (เพื่อดูว่าสวนเทรนด์หรือไม่).



### ฝั่ง EA (MQL5)

* **Inputs:**
* `InpMasterToken` / `InpApiKey`
* `InpLotType` (Multiplier, Fixed)
* `InpReverseTrade` (True/False)
* `InpMinLotToCopy` (Filter)
* `InpCustomMap` (String Input: "GOLD=XAUUSD, BTC=Bitcoin")


* **Symbol Normalization:** มีฟังก์ชัน `FixSymbolName` ตรวจสอบชื่อคู่เงินอัตโนมัติ และรองรับ Custom Mapping.

---

## 5. Current File Structure Highlights

* `lib/copy_trade_web/components/layouts/app.html.heex`: ไฟล์ Layout หลักที่มีเมนูและ Active Logic.
* `lib/copy_trade/trade/trade_pair_context.ex`: Context จัดการ DB (ใช้ Join `master_trades` แทนการเก็บ field ซ้ำ).
* `lib/copy_trade_web/live/dashboard_live.ex`: หน้า Dashboard หลัก (ใช้ `on_mount` เช็ค Auth).
* `lib/copy_trade_web/router.ex`: กำหนด Route และ `live_session` (แยก scope Public/Private).

---

**พร้อมสำหรับการพัฒนาต่อในเฟสถัดไปครับ!** (เช่น ระบบ Billing, Multi-Master Strategy, หรือ Notification Line/Telegram) 🚀