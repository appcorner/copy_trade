นี่คือ **สรุปข้อมูลระบบ Copy Trade v7.0.0 (Elixir System)** ฉบับสมบูรณ์

ใช้เป็น **Context Prompt** เมื่อเปิดห้อง Chat ใหม่ เพื่อให้ AI เข้าใจโครงสร้างระบบได้ทันที

---

# 📘 System Architecture Summary: CopyTradePro v7.0.0

## 1. Tech Stack & Infrastructure

* **Backend:** Elixir (Phoenix Framework 1.7+, LiveView)
* **Database:** PostgreSQL (Normalized Schema)
* **Protocol:** TCP Socket (Custom Protocol for MT5 Communication)
* **Frontend:** Phoenix LiveView + Tailwind CSS v4 + Chart.js v4.4.7
* **Trading Terminal:** MetaTrader 5 (MQL5)
* **Font:** Bai Jamjuree (Google Fonts)
* **Deployment:** Docker Container on Cloud Host (2 vCPU, 4GB RAM)
* *Capacity Estimate:* ~300-500 Active Slaves per Master / ~10-20 Concurrent Masters.

---

## 2. Database Schema (v7.0.0 — Multi-Account)

### A. Users (`users`)
* เก็บเฉพาะข้อมูล Login
* **Key Fields:** `id`, `email`, `hashed_password`, `name`
* **หมายเหตุ:** ไม่มี role, api_key, master_token แล้ว (ย้ายไป `trading_accounts`)

### B. Trading Accounts (`trading_accounts`) — ✨ NEW
* 1 User สร้างได้หลาย Account (Master หรือ Follower)
* **Key Fields:**
  * `user_id` (FK → users)
  * `name` (ชื่อพอร์ต)
  * `role` (master / follower)
  * `api_key` (Unique, auto-generated `sk_live_...`)
  * `master_token` (Unique, auto-generated `MST-...` for masters)
  * `copy_mode` (PUBSUB / 1TO1 / RECORD)
  * `partner_id` (FK → self, สำหรับ 1TO1)
  * `following_id` (FK → self, สำหรับ Follower ที่ติดตาม Master)
  * `is_active` (boolean)

### C. Master Trades (`master_trades`)
* เก็บ Signal ต้นฉบับจาก Master (1 Row ต่อ 1 Order ของ Master)
* **Key Fields:** `account_id`, `ticket`, `symbol`, `type` (BUY/SELL), `price`, `volume`, `sl`, `tp`, `status`

### D. Trade Pairs (`trade_pairs`)
* เก็บข้อมูลการตามของ Follower (ผูกกับ Master Trade)
* **Key Fields:**
  * `master_trade_id` (FK → master_trades)
  * `account_id` (FK → trading_accounts)
  * `slave_ticket`, `slave_volume`, `slave_type`
  * `status` (PENDING → OPEN → CLOSED)
  * `profit`, `close_price`

---

## 3. Copy Modes

| Mode | Icon | พฤติกรรม |
|------|------|----------|
| **PUBSUB** | 📡 | กระจายสัญญาณผ่าน Phoenix PubSub ให้ Follower ทุกคน |
| **1TO1** | 🤝 | ส่งสัญญาณตรงถึง Partner คนเดียวผ่าน Registry/PID |
| **RECORD** | 📝 | บันทึกข้อมูลเทรดลง DB เท่านั้น ไม่ส่งสัญญาณให้ Follower |

Master สามารถเปลี่ยน Mode ได้ real-time ผ่าน Dashboard

---

## 4. Workflow & Data Flow

### Step 1: Registration & Account Creation
1. **Register:** สมัครด้วย Email + Name (ไม่เลือก Role ตอนสมัคร)
2. **Create Account:** สร้าง Trading Account → เลือก Role (Master/Follower) → ระบบ gen API Key + Master Token อัตโนมัติ

### Step 2: Signal Reception (Master)
1. **Master EA** ส่ง TCP Command: `CMD_OPEN|TYPE|SYMBOL|PRICE|LOT|SL|TP|TICKET`
2. **TCP Server** รับข้อมูล → บันทึกลง `master_trades`
3. **TradeSignalRouter** ตรวจสอบ `copy_mode`:
   - PUBSUB: Broadcast ผ่าน PubSub
   - 1TO1: ส่งตรงไปที่ Partner PID
   - RECORD: บันทึกเฉยๆ ไม่ส่งต่อ

### Step 3: Signal Processing (Follower)
1. **Follower Worker** รับ Signal → ตรวจสอบเงื่อนไข
2. สร้าง Record ใน `trade_pairs` สถานะ **PENDING**
3. ส่ง TCP Command ไปหา Slave EA

### Step 4: Execution & Acknowledge
1. **Slave EA** ส่ง **ACK**: `ACK_OPEN|MST_TICKET|SLV_TICKET|SLV_LOT|SLV_TYPE`
2. อัปเดต `trade_pairs` เป็น **OPEN**
3. เมื่อปิดออเดอร์ → อัปเดตเป็น **CLOSED** พร้อมบันทึก profit

### Step 5: Dashboard Update
* LiveView + PubSub → อัปเดต Active Trades, กำไรรวม, กราฟกำไรสะสม real-time

---

## 5. Key Features & Logic

### ฝั่ง Backend (Elixir)
* **Multi-Account:** `Accounts.create_trading_account/2`, `list_trading_accounts/1`
* **Mode Switching:** `Accounts.update_copy_mode/2` → เปลี่ยน mode แบบ live
* **TradeSignalRouter:** `dispatch/2` → Route signal ตาม copy_mode
* **Emergency Kill Switch:** (1TO1 only) Stop Out → สั่งปิดคู่แท้ทันที
* **Cumulative Profit:** `TradePairContext.get_cumulative_profit_data/1` → time-series data for charts

### ฝั่ง Frontend (LiveView)
* **Dashboard:** Master/Follower views with profit charts (Chart.js via LiveView Hooks)
* **Account Management:** CRUD with radio card Role selector
* **Settings:** API Keys display + user profile management
* **Mobile Menu:** Responsive with auto-close on navigation

### ฝั่ง EA (MQL5)
* **Inputs:** `InpApiKey`, `InpMasterToken`, `InpLotType`, `InpReverseTrade`, `InpMinLotToCopy`, `InpCustomMap`
* **Symbol Normalization:** `FixSymbolName` + Custom Mapping

---

## 6. File Structure

* `lib/copy_trade/accounts/trading_account.ex` — TradingAccount schema
* `lib/copy_trade/accounts.ex` — Accounts context (CRUD, auth, mode switching)
* `lib/copy_trade/trade_signal_router.ex` — Signal routing (PUBSUB/1TO1/RECORD)
* `lib/copy_trade/trade_pair_context.ex` — Trade business logic + chart data
* `lib/copy_trade/tcp_server.ex` — TCP Connection handler (GenServer)
* `lib/copy_trade_web/live/dashboard_live.ex` — Dashboard (charts, mode switcher)
* `lib/copy_trade_web/live/account_live/` — Account CRUD pages
* `lib/copy_trade_web/live/user_live/settings.ex` — Settings (API Keys + profile)
* `lib/copy_trade_web/components/layouts/menu.html.heex` — Main layout + nav + footer
* `assets/js/app.js` — LiveView Hooks (CumulativeProfitChart)

---

**Version: v7.0.0 | Last Updated: 2026-02-18** 🚀