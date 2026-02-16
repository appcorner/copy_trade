**TCP Message Specification V7 (Production Test)**
*Updated: Based on logic in `tcp_server.ex`*

เอกสารนี้ใช้อ้างอิงสำหรับการเขียน EA (MQL5) ทั้งฝั่ง Master และ Slave เพื่อให้สื่อสารกับ Server ได้อย่างถูกต้องตาม Logic ปัจจุบัน

---

### 📋 กฎทั่วไป (General Rules)

1. **Format:** Text String
2. **Separator:** ใช้เครื่องหมาย Pipe `|` ในการคั่นข้อมูล
3. **Terminator:** จบข้อความด้วย `\n` (Newline) หรือ `\r\n` เสมอ
4. **Encoding:** UTF-8 / ASCII

---

### 1. การเชื่อมต่อและการตั้งค่า (Connection & Setup)

#### 1.1 ยืนยันตัวตน (Login)
ส่งทันทีหลังเชื่อมต่อ Socket สำเร็จ
* **Request:** `AUTH:API_KEY`
* **Example:** `AUTH:sk_live_123456`
* **Server Response:**
    * Success: `AUTH_OK`
    * Fail: `AUTH_FAILED` (Socket closed immediately)

#### 1.2 การกดติดตาม (Subscription) - *สำหรับ Follower*
ส่งหลังจาก Login ผ่านแล้ว
* **Request:** `SUBSCRIBE:MASTER_TOKEN`
* **Example:** `SUBSCRIBE:MST_998877`
* **Server Response:**
    * Success: `SUBSCRIBE_OK`
    * Fail: `ERROR:MASTER_NOT_FOUND`
    * Fail: `ERROR:MASTER_ALREADY_HAS_PARTNER` (กรณี Master เต็มในโหมด 1TO1)

#### 1.3 ตั้งค่าโหมด Copy (Set Mode) - *สำหรับ Master*
เปลี่ยนโหมดการทำงานระหว่าง 1TO1 (Exclusive) และ PUBSUB (Public)
* **Request:** `CMD_SET_MODE|MODE`
* **Values:** `1TO1` หรือ `PUBSUB`
* **Example:** `CMD_SET_MODE|1TO1`
* **Server Response:**
    * Success: `MODE_UPDATED|1TO1`
    * Fail: `ERROR:MODE_CHANGE_FAILED`

#### 1.4 ตั้งค่า Symbol (Init Symbol)
ส่งข้อมูลจำเพาะของคู่เงินเพื่อ update ลง Cache/DB
* **Request:** `CMD_INIT_SYMBOL|SYMBOL|CONTRACT_SIZE|DIGITS`
* **Example:** `CMD_INIT_SYMBOL|XAUUSD|100.0|2`
* **Server Response:** (None - Async Process)

#### 1.5 อัปเดตราคาตลาด (Market Price)
ส่งราคา Bid/Ask ล่าสุด (Master เป็นคนส่ง)
* **Request:** `CMD_PRICE|SYMBOL|BID|ASK`
* **Example:** `CMD_PRICE|XAUUSD|2030.50|2031.00`
* **Server Response:** (None - Broadcasts to Dashboard)

#### 1.6 เช็คสถานะ (Check Status)
* **Request:** `CHECK_STATUS`
* **Server Response:** `STATUS_ACTIVE` หรือ `STATUS_INACTIVE`

---

### 2. การซิงค์ข้อมูล (Synchronization)

ใช้สำหรับเคลียร์ออเดอร์ค้าง (Zombies) เมื่อเริ่มทำงานหรือต่อเน็ตใหม่

#### 2.1 Master Snapshot
ส่งรายการ Ticket ที่ถืออยู่จริงทั้งหมดบนพอร์ต Master
* **Request:** `MASTER_SNAPSHOT:TICKET1,TICKET2,TICKET3`
* **Example:** `MASTER_SNAPSHOT:1001,1002,1005`
* **Server Response:** `SNAPSHOT_OK`

#### 2.2 Slave Snapshot
ส่งรายการ Ticket ที่ถืออยู่จริงทั้งหมดบนพอร์ต Slave Server จะตรวจสอบว่า Ticket ไหนไม่มีในระบบและสั่งปิดทันที
* **Request:** `SLAVE_SNAPSHOT:TICKET1,TICKET2,TICKET3`
* **Example:** `SLAVE_SNAPSHOT:5001,5002`
* **Server Response:**
    * `SNAPSHOT_OK`
    * อาจได้รับคำสั่ง `CMD_SYNC_CLOSE` แทรกมาถ้ามีออเดอร์ค้าง

---

### 3. ฝั่ง Master (Master -> Server)

#### 3.1 สัญญาณเปิดออเดอร์ (Open Signal)
* **Request:** `SIGNAL_OPEN|TYPE|SYMBOL|PRICE|VOLUME|SL|TP|TICKET`
* **Parameters:**
  * `TYPE`: `BUY` หรือ `SELL`
  * `SYMBOL`: ชื่อคู่เงิน
  * `PRICE`: ราคาเปิด
  * `VOLUME`: Lot Size
  * `SL/TP`: Stop Loss / Take Profit
  * `TICKET`: Ticket ID บนพอร์ต Master
* **Example:** `SIGNAL_OPEN|BUY|XAUUSD|2030.50|0.01|2020.00|2040.00|1001`

#### 3.2 สัญญาณปิดออเดอร์ (Close Signal)
* **Request:** `SIGNAL_CLOSE|SYMBOL|TICKET|PRICE|PROFIT`
* **Parameters:**
  * `TICKET`: Ticket ID ของ Master
  * `PRICE`: ราคาที่ปิด
  * `PROFIT`: กำไร/ขาดทุน
* **Example:** `SIGNAL_CLOSE|XAUUSD|1001|2035.00|15.50`

---

### 4. ฝั่ง Slave (Slave -> Server)

#### 4.1 ยืนยันการเปิด (Ack Open)
ส่งเมื่อเปิดออเดอร์สำเร็จ
* **Request:** `ACK_OPEN|MASTER_TICKET|SLAVE_TICKET|VOLUME|TYPE`
* **Example:** `ACK_OPEN|1001|5001|0.01|BUY`

#### 4.2 ยืนยันการปิด (Ack Close)
ส่งเมื่อปิดออเดอร์สำเร็จ
* **Request:** `ACK_CLOSE|MASTER_TICKET|PRICE|PROFIT`
* **Example:** `ACK_CLOSE|1001|2035.00|15.50`

#### 4.3 แจ้งเตือนเปิดล้มเหลว (Open Failed)
สำคัญมาก! หากเปิดไม่ได้ต้องแจ้ง Server เพื่อให้ Master สั่ง Close ทิ้ง (Sync Close)
* **Request:** `ACK_OPEN_FAIL|MASTER_TICKET|REASON`
* **Example:** `ACK_OPEN_FAIL|1001|not enough money`
* **Action:** Server จะส่ง `CMD_SYNC_CLOSE` กลับไปหา Master (ในโหมด 1TO1)

#### 4.4 ยืนยันปิดจาก Stop Out (Ack Close SO)
ส่งเมื่อออเดอร์ถูกปิดโดย Broker (Stop Out/Cut Loss)
* **Request:** `ACK_CLOSE_SO|SLAVE_TICKET|PRICE|PROFIT`
* **Action:** Server อาจส่ง `CMD_SYNC_CLOSE` ไปหา Master ให้ปิดตาม

---

### 5. คำสั่งจาก Server (Server -> EA)

EA ต้องรอรับข้อความเหล่านี้ตลอดเวลา (ใน OnTick หรือ Timer)

#### 5.1 สั่งเปิดออเดอร์ (Command Open)
* **Format:** `CMD_OPEN|TYPE|SYMBOL|PRICE|VOLUME|SL|TP|MASTER_TICKET`
* **Action:** EA เปิดออเดอร์ทันทีแล้วส่ง `ACK_OPEN` กลับ

#### 5.2 สั่งปิดออเดอร์ (Command Close)
* **Format:** `CMD_CLOSE|SYMBOL|SLAVE_TICKET|MASTER_TICKET`
* **Action:** EA ปิดออเดอร์ทันทีแล้วส่ง `ACK_CLOSE` กลับ

#### 5.3 สั่งปิดทั้งหมดฉุกเฉิน (Emergency Close All)
ใช้เมื่อเกิดเหตุวิกฤต เช่น Stop Out หรือ Partner หลุด
* **Format:** `CMD_CLOSE_ALL|REASON`
* **Action:** EA ต้องปิดทุกออเดอร์ในพอร์ตทันที

#### 5.4 สั่งปิดเฉพาะออเดอร์ (Sync Close)
ใช้เมื่อเกิดการคลาดเคลื่อนของข้อมูล หรือ Master/Slave เปิดไม่สำเร็จ
* **Format:** `CMD_SYNC_CLOSE|MASTER_TICKET|REASON`
* **Action:** Master ต้องค้นหา Ticket นี้แล้วปิดทิ้ง (กรณี Master) 或者 Slave ปิดทิ้ง (กรณี Snapshot)

---

### 6. การแจ้งเตือน (Alerts)

#### 6.1 แจ้งเหตุ Stop Out (Alert Stop Out)
ส่งเมื่อ Equity ต่ำกว่ากำหนดหรือโดน Broker บังคับปิด
* **Request:** `ALERT_STOP_OUT|REASON`
* **Example:** `ALERT_STOP_OUT|equity low`
* **Action:** Server จะสั่ง `CMD_CLOSE_ALL` ไปยัง Partner ทันที (โหมด 1TO1)