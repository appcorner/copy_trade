//+------------------------------------------------------------------+
//|                                              SlaveTCP_V7_0.mq5 |
//|                                      TCP Version for Elixir Srvr |
//+------------------------------------------------------------------+
#property copyright "ATK"
#property link      "https://www.appcorner.com"
#property version   "7.0"
#property strict
#include <Trade\Trade.mqh>

input string            InpServerIP    = "127.0.0.1";   // CopyTrade Pro Server
input int               InpServerPort  = 5001;          // Port
input string            InpApiKey      = "sk_live_FOLLOWER_KEY";  // 🔑 API KEY ของ Follower (เอาจากหน้าเว็บ)
input string            InpMasterToken = "MST-XYZ";               // 🎯 Token ของ Master ที่จะตาม
input long              InpMagic       = 123456; // Magic Number ที่ใช้เปิด Order ใหม่
input string            InpComment     = "CopyTradePro"; // ข้อความใน comment

input group             "Symbol Settings"
input bool              InpRemoveMasterSuffix  = false;        // เปิดใช้งานการตัด Suffix ของ Master
input string            InpMasterSuffixText    = "-VIPc";      // ข้อความ Suffix ที่ต้องการตัดออก (เช่น -VIPc)
input bool              InpAddSlaveSuffix      = false;        // เปิดใช้งานการเติม Suffix ของ Slave
input string            InpSlaveSuffixText     = ".m";         // ข้อความ Suffix ที่ต้องการเติม (เช่น .m)

// --- Symbol Mapping Settings ---
input group             "Symbol Mapping"
input bool              InpApplyCustomMap   = false;        // เปิดใช้งานการแปลงชื่อ Symbol
input string            InpCustomMap = "GOLD=XAUUSD,SILVER=XAGUSD"; // แปลงชื่อ Symbol (ไม่แปลง ใส่ค่าว่าง)

// --- Money Management Settings ---
enum ENUM_LOT_TYPE {
   LOT_FIXED,        // 1. ฟิกซ์ Lot เท่ากันทุกไม้
   LOT_MULTIPLIER,   // 2. คูณจาก Master (เช่น Master 0.1, เรา x2 = 0.2)
   LOT_SAME_AS_MASTER // 3. ตาม Master เป๊ะๆ
};

input group             "Money Management"
input ENUM_LOT_TYPE     InpLotType        = LOT_MULTIPLIER; // เลือกโหมดคำนวณ Lot
input double            InpLotSize        = 0.01;           // ค่า Lot (กรณีใช้ Fixed)
input double            InpLotMultiplier  = 1.0;            // ตัวคูณ (กรณีใช้ Multiplier)
input double            InpMinLotToCopy   = 0.0;            // Copy เฉพาะไม้ที่ Lot มากกว่าค่านี้ (0.0 = เอาหมด)

input group             "Copy Settings"
input bool              InpCopySLTP       = false;           // true=ตาม SL/TP Master, false=ไม่ใส่
input bool              InpReverseTrade   = false;          // โหมดสวนเทรนด์ (Master Buy -> เรา Sell)
input int               InpSyncIntervalMinutes = 15; // ระยะเวลาห่างในการส่ง Orders Snapshot (นาที)

int socketHandle = INVALID_HANDLE;
CTrade trade;
ulong lastPingTime = 0;
ulong lastConnectAttempt = 0;
string tcpBuffer = ""; // Accumulator

bool isSubscribed = false;

uint syncUpdateInterval = 5*60*1000;
ulong lastSyncTime = 0;

bool IsCopyingActive = true;

bool isSendSymbolInit = false;

int OnInit() {
   syncUpdateInterval = InpSyncIntervalMinutes*60*1000;
   lastSyncTime = 0;
   isSendSymbolInit = false;   
   trade.SetExpertMagicNumber(InpMagic);
   // ตั้งค่า Slippage และ Deviation ให้เหมาะสม
   trade.SetDeviationInPoints(10);
   
   EventSetMillisecondTimer(100); // Check socket every 100ms
   Print("🟢 Slave EA Initialized. Waiting for Connection...");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   if(socketHandle != INVALID_HANDLE) SocketClose(socketHandle);
   EventKillTimer();
   Print("🔴 EA Stopped.");
}

void ConnectToServer() {
   if(GetTickCount() - lastConnectAttempt < 3000) return;
   lastConnectAttempt = GetTickCount();

   if(socketHandle != INVALID_HANDLE) SocketClose(socketHandle);

   Print("🔄 Connecting to ", InpServerIP, ":", InpServerPort, "...");
   socketHandle = SocketCreate();
   
   if(socketHandle != INVALID_HANDLE) {
      if(SocketConnect(socketHandle, InpServerIP, InpServerPort, 1000)) {
         Print("✅ Connected! Sending Auth...");
         isSubscribed = false;
         // 1. ส่ง Auth
         SendTCPMessage("AUTH:" + InpApiKey + "\n");
         lastPingTime = GetTickCount();
         
      } else {
         Print("❌ Connect Failed. Error: ", GetLastError());
      }
   }
}

void Reconnect() {
   Print("⚠️ Connection lost. Reconnecting...");
   SocketClose(socketHandle);
   socketHandle = INVALID_HANDLE;
   tcpBuffer = ""; // Clear buffer
}

void OnTimer() {
   if(socketHandle == INVALID_HANDLE) {
      ConnectToServer();
      return;
   }
   
   CheckStopOut();

   // 1. อ่านข้อมูลจาก Socket
   uint rd_len = SocketIsReadable(socketHandle);
   if(rd_len > 0) {
      uchar rsp[];
      ResetLastError();
      int len = SocketRead(socketHandle, rsp, rd_len, 100);

      if(len > 0) {
         string incoming = CharArrayToString(rsp, 0, len);
         tcpBuffer += incoming; // ต่อท้าย Buffer

         // Loop ตัดคำสั่งด้วย \n
         while(true) {
            int sepIndex = StringFind(tcpBuffer, "\n");
            if(sepIndex < 0) break; // ยังไม่จบประโยค รอไปก่อน

            string oneCommand = StringSubstr(tcpBuffer, 0, sepIndex);
            tcpBuffer = StringSubstr(tcpBuffer, sepIndex + 1); // ตัดส่วนที่ใช้แล้วทิ้ง
            
            // ลบ \r และช่องว่าง
            StringTrimRight(oneCommand);
            StringTrimLeft(oneCommand); // กันเหนียว
            
            if(StringLen(oneCommand) > 0) {
               ProcessCommand(oneCommand);
            }
         }
      } else {
         // อ่านพลาด
         int err = GetLastError();
         if(err != 0 && err != 5273) {
            Print("⚠️ Read Failed. Error: ", err);
            Reconnect(); return;
         }
      }
   }

   // 2. Heartbeat
   if(GetTickCount() - lastPingTime > 5000) {
      if(!SendTCPMessage("PING\n")) {
         Reconnect();
         return;
      }
      lastPingTime = GetTickCount();
      SendSlaveSnapshot();
      
      // ✅ เช็คสถานะเป็นระยะ (จับการเปลี่ยนแปลงจาก Dashboard)
      //if(isSubscribed) {
      //   SendTCPMessage("CHECK_STATUS\n");
      //}
   }
}

bool SendTCPMessage(string text) {
   if(socketHandle == INVALID_HANDLE) return false;
   uchar data[];
   StringToCharArray(text, data, 0, StringLen(text));
   return (SocketSend(socketHandle, data, StringLen(text)) >= 0);
}

// ------------------------------------------------------------------
// ⚙️ Process Command (หัวใจหลัก)
// ------------------------------------------------------------------
void ProcessCommand(string cmd) {
   Print("⚙️ RECV: ", cmd);

   // 1. Login ผ่าน -> ส่ง Subscribe ต่อทันที
   if(StringFind(cmd, "AUTH_OK") >= 0) {
      Print("🔓 Login Success! Subscribing to ", InpMasterToken);
      SendTCPMessage("SUBSCRIBE:" + InpMasterToken + "\n");
      return;
   }
   
   if(StringFind(cmd, "SUBSCRIBE_OK") >= 0) {
      Print("✅ Ready to copy Master: ", InpMasterToken);
      isSubscribed = true;
      SendSlaveSnapshot();
      SendTCPMessage("CHECK_STATUS\n");  // ✅ เช็คสถานะทันทีหลัง Subscribe
      return;
   }
   
   if(StringFind(cmd, "SNAPSHOT_OK") >= 0) {
      Print("✅ Order reconciliation ok.");
      return;
   }
   
   if(StringFind(cmd, "ERROR:INVALID_TOKEN") >= 0) {
      Print("❌ Error: Invalid Master Token! Please check inputs.");
      return;
   }

   // 2. แยกคำสั่งด้วย Pipe '|'
   string parts[];
   int count = StringSplit(cmd, '|', parts);
   if(count <= 0) return;

   string type = parts[0];

   // --- CMD_OPEN ---
   // Format: CMD_OPEN|BUY|SYMBOL|PRICE|VOLUMN|SL|TP|MASTER_TICKET
   if(type == "CMD_OPEN" && count >= 8) {
      if(!IsCopyingActive) {
         Print("⛔ Ignored OPEN signal: Copying is INACTIVE.");
         return; 
      }
      string typeStr = parts[1];      // BUY/SELL
      string incomingSymbol = parts[2];
      string tradeSymbol = FixSymbolName(incomingSymbol);
      double price = StringToDouble(parts[3]);
      double masterLot = StringToDouble(parts[4]); // 🔥 Lot ของ Master
      double masterSL = StringToDouble(parts[5]); // 🔥 SL ของ Master
      double masterTP = StringToDouble(parts[6]); // 🔥 TP ของ Master
      string masterTicket = parts[7]; // String เพราะจะส่งคืน Server
      
      // -------------------------------------------------------
      // Filter Logic: กรอง Lot ขั้นต่ำ
      // -------------------------------------------------------
      if(masterLot <= InpMinLotToCopy)
      {
         Print("⚠️ Filtered: Master Lot (", masterLot, ") <= MinLot (", InpMinLotToCopy, "). Ignored.");
         return; // จบการทำงาน ไม่ Copy
      }
      
      // --- 1. คำนวณ Lot Size ---
      double tradeLot = InpLotSize;
      
      if(InpLotType == LOT_SAME_AS_MASTER) {
         tradeLot = masterLot;
      } 
      else if(InpLotType == LOT_MULTIPLIER) {
         tradeLot = masterLot * InpLotMultiplier;
      } 
      else { // LOT_FIXED
         tradeLot = InpLotSize;
      }
      
      // ⚠️ สำคัญ: ต้อง Normalize Lot ให้ตรงกับกฎโบรกเกอร์เรา (เช่น step 0.01)
      double minLot = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MAX);
      double stepLot = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_STEP);
      
      // ปัดเศษให้ลงตัวกับ Step
      tradeLot = MathFloor(tradeLot / stepLot) * stepLot; 
      
      // กันเหนียว ไม่ให้น้อยกว่า min หรือมากกว่า max
      if(tradeLot < minLot) tradeLot = minLot;
      if(tradeLot > maxLot) tradeLot = maxLot;
      
      // --- 2. จัดการ SL/TP ---
      double finalSL = 0.0;
      double finalTP = 0.0;
      
      string finalType = typeStr;
      
      if(InpReverseTrade)
      {
         // สลับฝั่ง: BUY -> SELL, SELL -> BUY
         if(typeStr == "BUY")       finalType = "SELL";
         else if(typeStr == "SELL") finalType = "BUY";
         
         if(InpCopySLTP)
         {
            finalSL = masterSL; // สลับกัน
            finalTP = masterTP; // สลับกัน
         }
         
         Print("🔄 Reverse Mode Active: Master ", typeStr, " -> Slave ", finalType);
      }
      else
      {
         if(InpCopySLTP) {
            finalSL = masterSL;
            finalTP = masterTP;
         }
      }
      
      // --- 3. ส่งคำสั่งเทรด ---      
      ENUM_ORDER_TYPE orderType = (finalType == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      
      Print("🚀 Opening ", finalType, " ", tradeSymbol, " for MasterTicket: ", masterTicket);
      
      // ส่งคำสั่งเทรด (Lot 0.01 ทดสอบก่อน หรือคำนวณตามต้องการ)
      if(trade.PositionOpen(tradeSymbol, orderType, tradeLot, 0, finalSL, finalTP, InpComment + " " + masterTicket)) {
         
         if(trade.ResultRetcode() == TRADE_RETCODE_DONE) {
            ulong slaveTicket = trade.ResultOrder();
            Print("✅ Order Opened: #", slaveTicket);
            
            // สร้างข้อความตอบกลับ
            // Format: ACK_OPEN|MASTER_TICKET|SLAVE_TICKET|VOLUMN|TYPE
            string ackMsg = "ACK_OPEN|" + 
                masterTicket + "|" + 
                IntegerToString(slaveTicket) + "|" + 
                DoubleToString(tradeLot, 2) + "|" + 
                finalType;
                
            SendTCPMessage(ackMsg + "\n");
         }
      } else {
         Print("❌ Open Failed: ", trade.ResultRetcodeDescription());
         
         string ackMsg = "ACK_OPEN_FAIL|" + 
                masterTicket + "|" + trade.ResultRetcodeDescription();
                
         SendTCPMessage(ackMsg + "\n");
      }
      
      SendSymbolInit(tradeSymbol, incomingSymbol);
   }
   
   // --- CMD_CLOSE ---
   // Format: CMD_CLOSE|SYMBOL|SLAVE_TICKET|MASTER_TICKET
   else if(type == "CMD_CLOSE" && count >= 4) {
      string incomingSymbol = parts[1];
      string tradeSymbol = FixSymbolName(incomingSymbol);
      ulong slaveTicket = StringToInteger(parts[2]);
      string masterTicket = parts[3];
      
      Print("✂️ Closing Ticket #", slaveTicket);
      
      // เลือก Position ด้วย Ticket
      if(PositionSelectByTicket(slaveTicket)) {
         if(trade.PositionClose(slaveTicket)) {

            if(trade.ResultRetcode() == TRADE_RETCODE_DONE) {
               // ดึงข้อมูลกำไรเพื่อรายงานผล
               ulong dealTicket = trade.ResultDeal();
               if(HistoryDealSelect(dealTicket)) {
                  double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) 
                                + HistoryDealGetDouble(dealTicket, DEAL_SWAP) 
                                + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
                  double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
                  
                  // ตอบกลับ: ACK_CLOSE|MASTER_TICKET|CLOSE_PRICE|PROFIT
                  string resp = "ACK_CLOSE|" + masterTicket + "|" + DoubleToString(closePrice, 5) + "|" + DoubleToString(profit, 2);
                  SendTCPMessage(resp + "\n");
                  Print("✅ Closed. Profit: ", profit);
               }
            }
         } else {
            string resp = "ACK_CLOSE_FAIL|" + masterTicket + "|" + trade.ResultRetcodeDescription();
            SendTCPMessage(resp + "\n");
             Print("❌ Close Failed: ", trade.ResultRetcodeDescription());
         }
      } else {
         Print("⚠️ Ticket #", slaveTicket, " not found (Already closed?)");
         // อาจจะส่ง ACK_CLOSE กลับไปเลยก็ได้ เพื่อให้ DB อัปเดตสถานะ
      }
      
      SendSymbolInit(tradeSymbol, incomingSymbol);
   }
   else if(type == "CMD_STOP" && count >= 1) {
      Print("⛔ Received STOP command from Server via TCP!");
       
      // 1. หยุดตัวแปร Global
      IsCopyingActive = false;
      
      // 2. เคลียร์พอร์ตทันที
      CloseAllPositions();
      
      // 3. (Optional) แจ้งเตือนบนหน้าจอ
      Comment("⛔ COPY TRADE STOPPED"); 
   }
   else if(type == "CMD_SYNC_CLOSE" && count >= 2) {
      ulong ticket_to_close = StringToInteger(parts[1]);
      
      Print("⛔ Security Alert: Closing unauthorized trade ", ticket_to_close);

      if(!trade.PositionClose(ticket_to_close)) {
         Print("Failed to close position #", ticket_to_close, " Error: ", GetLastError());
      } else {
         Print("Closed position #", ticket_to_close);
      }
   }
   else if (type == "STATUS_ACTIVE") {
      if(!IsCopyingActive) {
         Print("✅ Status changed to ACTIVE. Resuming copy...");
         IsCopyingActive = true;
         Comment(""); // ลบข้อความแจ้งเตือน
      }
   }
   else if (type == "STATUS_INACTIVE") {
      if(IsCopyingActive) {
         Print("⏸️ Status changed to INACTIVE. Pausing copy...");
         IsCopyingActive = false;
         Comment("⏸️ COPY INACTIVE: ยังไม่ได้ผูกกับ Master");
      }
   }
}

//+------------------------------------------------------------------+
//| Trade Transaction (ดักจับการเทรด)                                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result) {
   
   // เราสนใจเฉพาะตอนเกิด Deal (จับคู่ซื้อขายสำเร็จ)
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   
   ulong dealTicket = trans.deal;
   if(HistoryDealSelect(dealTicket)) {      
      // ตรวจสอบว่าเหตุผลการปิดมาจากระบบ (ไม่ใช่จาก EA สั่งเอง)
      if(HistoryDealGetInteger(dealTicket, DEAL_REASON) == DEAL_REASON_SO) {
         //Print("debug dealTicket: ", dealTicket);
         //Print("debug DEAL_REASON: ", HistoryDealGetInteger(dealTicket, DEAL_REASON));
         //Print("debug DEAL_COMMENT: ", HistoryDealGetString(dealTicket, DEAL_COMMENT));

         // ไปเช็คต่อใน Comment ว่าใช่ SO หรือไม่
         //if (CheckDealForStopOut(dealTicket)) return;
         CheckDealForStopOut(dealTicket);
      }
      
      // ✅ 3. ดึงข้อมูลพื้นฐาน
      long entry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);      
      if(entry == DEAL_ENTRY_OUT) {
         double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
         double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) + HistoryDealGetDouble(dealTicket, DEAL_SWAP) + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);         
         ulong slaveTicket = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
         
         // Format: ACK_CLOSE_SO|SLAVE_TICKET|CLOSE_PRICE|PROFIT
         string resp = "ACK_CLOSE_SO|" + IntegerToString(slaveTicket) + "|" + DoubleToString(closePrice, 5) + "|" + DoubleToString(profit, 2);
         SendTCPMessage(resp + "\n");
         Print("✅ Closed. Profit: ", profit);

      }
   }
}
   
//+------------------------------------------------------------------+
//| Helper: เชื่อมต่อ Server                                           |
//+------------------------------------------------------------------+

// --- ฟังก์ชันสำหรับแปลงชื่อ Symbol ---
string FixSymbolName(string masterSymbol)
{
   string finalSymbol = masterSymbol;

   // 1. ถ้าเปิดใช้งานการตัด Suffix
   if(InpRemoveMasterSuffix && StringLen(InpMasterSuffixText) > 0)
   {
      // ใช้ StringReplace เพื่อลบคำนั้นทิ้ง (เปลี่ยนเป็นค่าว่าง)
      StringReplace(finalSymbol, InpMasterSuffixText, "");
   }
   
   if (InpApplyCustomMap && StringLen(InpCustomMap) > 0)
   {
      finalSymbol = GetCustomMapping(finalSymbol);
   }
   
   if(InpAddSlaveSuffix && StringLen(InpSlaveSuffixText) > 0)
   {
      finalSymbol = finalSymbol + InpSlaveSuffixText;
   }
   
   // 2. (แถม) ตรวจสอบว่าในกระดานเรามี Symbol นี้ไหม?
   // ถ้าไม่มี ให้ลองตัดตัวอักษรส่วนเกินออกเหลือแค่ 6 ตัวแรก (เช่น EURUSD) เผื่อกรณีฉุกเฉิน
   if(!SymbolSelect(finalSymbol, true)) 
   {
      // พยายามค้นหาแบบ Auto (กรณีตัดแล้วยังไม่เจอ หรือ User กรอกผิด)
      Print("Warning: Symbol " + finalSymbol + " not found. Trying auto-detection...");
      
      // ตัวอย่าง: ถ้า Master ส่ง XAUUSD-VIPc มา แล้วเราตัดผิด หรือยังไม่เจอ
      // ลองค้นหา XAUUSD ใน Market Watch เรา
      string coreName = StringSubstr(masterSymbol, 0, 6) + StringSubstr(Symbol(), 6);
      Print("Auto-detection: Symbol " + coreName);
      if(SymbolSelect(coreName, true)) return coreName;
   }

   return finalSymbol;
}

void CloseAllPositions() {
   trade.SetAsyncMode(false);
   // 1. ปิด Positions (Buy/Sell) ที่เปิดค้างอยู่
   // ต้องวน Loop ย้อนกลับ (Count Down) เพราะจำนวน Position จะเปลี่ยนเมื่อเราปิด
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      
      if(ticket > 0) {
         // เช็คว่าเป็นออเดอร์ของ EA ตัวนี้หรือไม่ (ด้วย Magic Number)
         if(PositionGetInteger(POSITION_MAGIC) == InpMagic) {
            
            // สั่งปิดออเดอร์
            if(!trade.PositionClose(ticket)) {
               Print("Failed to close position #", ticket, " Error: ", GetLastError());
            } else {
               Print("Closed position #", ticket);
            }
         }
      }
   }

   // 2. ลบ Pending Orders (Buy Limit, Sell Stop ฯลฯ) ที่ค้างอยู่
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      
      if(ticket > 0) {
         // เช็ค Magic Number เช่นกัน
         if(OrderGetInteger(ORDER_MAGIC) == InpMagic) {
            
            // สั่งลบออเดอร์
            if(!trade.OrderDelete(ticket)) {
               Print("Failed to delete pending order #", ticket, " Error: ", GetLastError());
            } else {
               Print("Deleted pending order #", ticket);
            }
         }
      }
   }
   trade.SetAsyncMode(true);
}

// ฟังก์ชันค้นหาชื่อจาก Custom Input
string GetCustomMapping(string serverSymbol)
{
   // 1. ถ้าไม่ได้กรอกอะไรมา ก็ข้ามไป
   if(InpCustomMap == "") return serverSymbol;

   string maps[];
   // แยกข้อความด้วยเครื่องหมาย "," (เช่น "GOLD=XAUUSD" , "SILVER=XAGUSD")
   int count = StringSplit(InpCustomMap, ',', maps);
   
   for(int i=0; i<count; i++)
   {
      string pair = maps[i];
      string parts[];
      
      // แยกด้วยเครื่องหมาย "=" (เช่น "GOLD" = "XAUUSD")
      if(StringSplit(pair, '=', parts) == 2)
      {
         string srvName = parts[0]; // ชื่อจาก Server
         string locName = parts[1]; // ชื่อในพอร์ตเรา
         
         // ลบช่องว่างเผื่อมีคนเผลอเคาะวรรค
         StringTrimLeft(srvName); StringTrimRight(srvName);
         StringTrimLeft(locName); StringTrimRight(locName);
         
         // ถ้าชื่อตรงกันเป๊ะๆ (Case Insensitive เผื่อตัวเล็กใหญ่)
         if(StringCompare(srvName, serverSymbol, false) == 0)
         {
            return locName; // เจอแล้ว! ส่งชื่อในพอร์ตเรากลับไป
         }
      }
   }
   
   return serverSymbol; // ไม่เจอ
}

void SendSlaveSnapshot() {
   if(socketHandle == INVALID_HANDLE) return;
   if(!isSubscribed) return;
   
   uint currentTick = GetTickCount();
   
   if((currentTick - lastSyncTime) >= syncUpdateInterval) {
      string tickets = "";
      for(int i=PositionsTotal()-1; i>=0; i--) {
         ulong ticket = PositionGetTicket(i);
         if(PositionGetInteger(POSITION_MAGIC) == InpMagic) {
            tickets += IntegerToString(ticket) + (i > 0 ? "," : "");
         }
      }
      // ส่ง Format: SNAPSHOT:TICKET1,TICKET2,TICKET3
      string msg = "SLAVE_SNAPSHOT:" + tickets;
      Print(msg);
      SendTCPMessage(msg + "\n");
      
      lastSyncTime = currentTick;
   }
}

void SendSymbolInit(string _tradeSymbol, string _masterSymbol) {
   if (isSendSymbolInit) return;
   
   double contract_size = SymbolInfoDouble(_tradeSymbol, SYMBOL_TRADE_CONTRACT_SIZE);
   int digits = (int)SymbolInfoInteger(_tradeSymbol, SYMBOL_DIGITS);
   
   // รูปแบบ: CMD_INIT_SYMBOL|SYMBOL|CONTRACT_SIZE|DIGITS
   string msg = "CMD_INIT_SYMBOL|" + _masterSymbol + "|" + 
                DoubleToString(contract_size, 2) + "|" + (string)digits;
   SendTCPMessage(msg + "\n");
   Print("System: Symbol configuration sent to server.");
   Print(msg);
   isSendSymbolInit = true;
}

void CheckDealForStopOut(ulong _ticket) {
   if(HistoryDealGetString(_ticket, DEAL_SYMBOL) == _Symbol) {
      string comment = HistoryDealGetString(_ticket, DEAL_COMMENT);
      
      // ตรวจสอบคำว่า "so" หรือ "stop out" (ตัวเล็กตัวใหญ่ไม่เกี่ยง)
      string lowerComment = comment;
      StringToLower(lowerComment);
      
      if(StringFind(lowerComment, "so") >= 0 || StringFind(lowerComment, "stop out") >= 0) {
         if (PositionsTotal() == 0)
         {
            string msg = "ALERT_STOP_OUT|Comment:" + comment;
            SendTCPMessage(msg + "\n");
            Print("🚨 STOP OUT DETECTED!");
         }
         
         lastSyncTime = GetTickCount();
         //return true;
      }
   }
   //return false;
}
void CheckStopOut() {
   // 1. ดึงค่า Margin Level (เป็น %)
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   
   // 2. ดึงค่า Stop Out Mode และ Level ของโบรกเกอร์นั้นๆ
   double soLevel = AccountInfoDouble(ACCOUNT_MARGIN_SO_SO);
   //long soMode = AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE);
   
   // ตรวจสอบว่า Margin Level ต่ำกว่าเกณฑ์ที่โบรกเกอร์กำหนดหรือไม่
   // soMode 0 = Percentage (เช่น 30%), 1 = Monetary (เหลือเงินเท่าไหร่)
   if(marginLevel <= soLevel && marginLevel > 0) {
      if (PositionsTotal() == 1)
      {
         string msg = "ALERT_STOP_OUT|MarginLevel:" + DoubleToString(marginLevel, 2);
         SendTCPMessage(msg + "\n");
         Print("🚨 STOP OUT DETECTED!");
      }
      
      lastSyncTime = GetTickCount();
   }
   Comment(StringFormat("SO Level:%2.f, Margin Level:%.2f", soLevel, marginLevel));
}