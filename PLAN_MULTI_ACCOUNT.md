# 📋 แผนปรับปรุงระบบบัญชี: Multi-Account Support

> **สถานะ: ✅ ดำเนินการเสร็จสิ้น (v7.0.0 — 2026-02-18)**

เป้าหมาย: เปลี่ยนจาก 1 Login = 1 Account เป็น 1 Login สามารถมีได้หลาย Trading Account (Master/Follower)

---

## 1. ฐานข้อมูล (Database Schema)

เราจะแยกข้อมูล "การเทรด" ออกจาก "ผู้ใช้งาน"

### 1.1 ตาราง `users` (ปรับปรุง) ✅
เก็บเฉพาะข้อมูลการเข้าสู่ระบบ
- `id` (PK)
- `email`
- `hashed_password`
- `name` (ชื่อเจ้าของ User Profile)
- ~~`role`~~ (ลบออกแล้ว)
- ~~`api_key`~~ (ลบออกแล้ว)
- ~~`master_token`~~ (ลบออกแล้ว)
- ~~`copy_mode`~~ (ลบออกแล้ว)
- ~~`partner_id`~~ (ลบออกแล้ว)
- ~~`following_id`~~ (ลบออกแล้ว)

### 1.2 ตารางใหม่ `trading_accounts` ✅
เก็บข้อมูลพอร์ตการลงทุนแต่ละพอร์ต
- `id` (PK)
- `user_id` (FK -> users.id)
- `name` (ชื่อพอร์ต เช่น "My Aggressive Master", "Follower 1")
- `role` (enum: "master", "follower")
- `api_key` (Unique, auto-generated with `sk_live_` prefix)
- `master_token` (Unique, nullable, auto-generated with `MST-` prefix for masters)
- `copy_mode` (default: "PUBSUB", options: "PUBSUB", "1TO1", "RECORD")
- `partner_id` (FK -> trading_accounts.id) — Self-referencing
- `following_id` (FK -> trading_accounts.id) — Self-referencing
- `is_active` (boolean, default: true)

---

## 2. ขั้นตอนการทำงาน (Workflow Changes)

### 2.1 หน้าเว็บไซต์ (Web Dashboard) ✅
1.  **Register:** สมัครสมาชิกด้วยอีเมล + ชื่อ (ไม่ต้องเลือก Role แล้ว)
2.  **Login:** เข้าสู่ระบบด้วย Email/Password ตามเดิม
3.  **Accounts List (`/accounts`):** หน้ารวมบัญชี (My Trading Accounts)
    *   แสดงรายการบัญชีที่มีอยู่ พร้อม badge Master/Follower
    *   ปุ่ม "New Account" → เปิด Modal สร้างบัญชีใหม่
    *   UI เลือก Role แบบ Radio Card (👥 Follower / 🏆 Master)
    *   รายการ auto-refresh หลังสร้างบัญชีสำเร็จ
4.  **Dashboard View (`/dashboard/:id`):** เลือกบัญชีที่จะดู Dashboard
    *   **Master:** Mode Switcher (PUBSUB/1TO1/RECORD), Master Token, API Key, กราฟกำไรสะสม
    *   **Follower:** สถานะการเชื่อมต่อ, Active/Closed Trades, กราฟกำไรสะสม
5.  **Settings (`/users/settings`):** แสดง API Keys ทุกบัญชีด้านบนสุด, ตั้งค่าชื่อ/อีเมล/รหัสผ่าน

### 2.2 การทำงานของ TCP Server ✅
1.  **Authentication:**
    *   เดิม: `AUTH:API_KEY` -> ค้นหา `User`
    *   ใหม่: `AUTH:API_KEY` -> ค้นหา `TradingAccount`
2.  **Logic ภายใน:**
    *   เปลี่ยนการอ้างอิง `user_id` เป็น `account_id` ในทุก Context (TradePair, MasterTrade)
    *   `account_id` จะกลายเป็น Identity หลักในระบบ Trading

---

## 3. แผนการแก้ไข Code (Implementation Plan)

### Phase 1: Database Migration ✅
1.  ✅ สร้าง Migration `20260216120000_create_trading_accounts`
2.  ✅ เขียน Script ย้ายข้อมูลเก่า `20260216121000_migrate_users_data`
3.  ✅ สร้าง Migration `20260216122000_remove_trading_fields_from_users`
4.  ✅ สร้าง Migration `20260216124000_fix_all_references`

### Phase 2: Backend Context ✅
1.  ✅ สร้าง Schema `CopyTrade.Accounts.TradingAccount`
2.  ✅ แก้ไข `CopyTrade.Accounts` context:
    *   ✅ `create_trading_account/2`
    *   ✅ `list_trading_accounts/1`
    *   ✅ `get_account_by_api_key/1`
    *   ✅ `update_copy_mode/2`
    *   ✅ `delete_trading_account/1`

### Phase 3: TCP Server Refactor ✅
1.  ✅ เปลี่ยน Logic ใน `tcp_server.ex`:
    *   `state.user_id` -> `state.account_id`
    *   การตรวจสอบ Role และ Partner ให้เช็คจาก `TradingAccount` struct
2.  ✅ เพิ่ม RECORD mode ใน `TradeSignalRouter` (บันทึกอย่างเดียว ไม่ broadcast)

### Phase 4: Frontend Update ✅
1.  ✅ สร้างหน้า `AccountLive.Index` (list + create modal)
2.  ✅ แก้ไข `DashboardLive` ให้รับ parameter เป็น `account_id`
3.  ✅ เพิ่ม Mode Switcher UI (PUBSUB/1TO1/RECORD) บน Master Dashboard
4.  ✅ เพิ่ม Cumulative Profit Chart (Chart.js + LiveView Hooks)
5.  ✅ เพิ่ม API Keys section ในหน้า Settings
6.  ✅ ลบ Role selector ออกจากหน้า Registration
7.  ✅ เพิ่ม Masters link ใน mobile menu + auto-close on navigate
8.  ✅ Footer รวมเป็นที่เดียว + version badge v7.0.0

---

## 4. สิ่งที่ต้องแลก (Trade-offs)
*   ✅ แก้ไขแล้ว: User เก่าจะถูก Migrate ข้อมูลอัตโนมัติ
*   ✅ แก้ไขแล้ว: Code ในส่วน `TcpServer` และ `Context` ถูก Refactor เรียบร้อย

---

## 5. สิ่งที่ควรทำต่อ (Next Steps)
- [ ] ทดสอบ EA Connection กับ Multi-Account
- [ ] เพิ่ม Account editing (เปลี่ยนชื่อ, toggle active/inactive)
- [ ] เพิ่ม Notification (Line/Telegram) เมื่อมี Trade ใหม่
- [ ] เพิ่ม Billing/Subscription สำหรับ Master
- [ ] Performance testing กับ Follower จำนวนมาก
