//+------------------------------------------------------------------+
//|                                       MasterSenderTCP_V7_0.mq5 |
//|                                      TCP Version for Elixir Srvr |
//+------------------------------------------------------------------+
#property copyright "ATK"
#property link      "https://www.appcorner.com"
#property version   "7.0"
#property strict
#include <Trade\Trade.mqh>

// --- ⚙️ Config ---
input string            InpServerIP   = "127.0.0.1";    // CopyTrade Pro Server
input int               InpServerPort = 5001;           // Port
input string            InpApiKey     = "sk_live_MASTER_KEY"; // 🔑 API KEY ของ Master (เอาจากหน้าเว็บ)
input long              InpIgnoreMagic = 123456;        // Magic Number ที่ไม่ต้องการส่ง

input group             "Symbol Settings"
input bool              InpRemoveMasterSuffix   = false;        // เปิดใช้งานการตัด Suffix ของ Master
input string            InpMasterSuffixText     = "-VIPc";     // ข้อความ Suffix ที่ต้องการตัดออก (เช่น -VIPc)

input group             "Symbol Mapping"
input bool              InpApplyCustomMap   = false;        // เปิดใช้งานการแปลงชื่อ Symbol
input string            InpCustomMap = "GOLD=XAUUSD,SILVER=XAGUSD"; // แปลงชื่อ Symbol (ไม่แปลง ใส่ค่าว่าง)

input group    "Copy Settings"
enum ENUM_COPY_MODE { MODE_1TO1, MODE_PUBSUB, MODE_RECORD };
input ENUM_COPY_MODE    InpCopyMode = MODE_PUBSUB; // 📋 เลือกโหมดการส่งสัญญาณ
input bool              InpSyncModeFromEA = false;  // ✅ ส่ง Mode จาก EA ไปอัปเดต Server (ปกติตั้งจาก Web)
input int               InpSyncIntervalMinutes = 15; // ระยะเวลาห่างในการส่ง Orders Snapshot (นาที)

// --- 🔧 Global Variables ---
int socketHandle = INVALID_HANDLE;
CTrade trade;
uint lastPingTime = 0;
string tcpBuffer = ""; // Accumulator

double lastSentBid = 0;
uint lastPriceSentTick = 0;
uint priceUpdateInterval = 1000; // ส่งทุกๆ 1000 ms (1 ครั้ง/วินาที)

bool isAuthenticated = false;

uint syncUpdateInterval = 5*60*1000;
ulong lastSyncTime = 0;

string g_sentSymbols[];
int g_sentSymbolsCount = 0;

bool isModeSent = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   syncUpdateInterval = InpSyncIntervalMinutes*60*1000;
   g_sentSymbolsCount = 0;
   ArrayResize(g_sentSymbols, 0);
   isModeSent = false;
   EventSetTimer(1); // เช็คการเชื่อมต่อทุก 1 วินาที
   ConnectToServer();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(socketHandle != INVALID_HANDLE) {
      SocketClose(socketHandle);
   }
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| Timer function (Heartbeat & Reconnect)                           |
//+------------------------------------------------------------------+
void OnTimer() {
   // ถ้า Socket หลุด ให้ต่อใหม่
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
   
   if(isAuthenticated && !isModeSent) {
      if(InpSyncModeFromEA) {
         SendMasterMode();
         Print("📡 Mode synced from EA to Server");
      }
      isModeSent = true;
   }
   
   // ส่ง Ping ทุก 5 วินาที เพื่อเลี้ยงสาย
   if(GetTickCount() - lastPingTime > 5000) {
      if(!SendTCPMessage("PING\n")) {
         Print("❌ Ping failed. Reconnecting...");
         Reconnect(); return;

      }
      lastPingTime = GetTickCount();
      
      SendMasterSnapshot();
   }
   
   SendPriceUpdate();
}

// ------------------------------------------------------------------
// ⚙️ Process Command (หัวใจหลัก)
// ------------------------------------------------------------------
void ProcessCommand(string cmd) {
   Print("⚙️ RECV: ", cmd);

   // 1. Login ผ่าน -> ส่ง Subscribe ต่อทันที
   if(StringFind(cmd, "AUTH_OK") >= 0) {
      Print("🔓 Login Success!");
      isAuthenticated = true;
      SendMasterSnapshot();
      return;
   }
   
   if(StringFind(cmd, "SNAPSHOT_OK") >= 0) {
      Print("✅ Order reconciliation ok.");
      return;
   }

   // 2. แยกคำสั่งด้วย Pipe '|'
   string parts[];
   int count = StringSplit(cmd, '|', parts);
   if(count <= 0) return;

   string type = parts[0];

   if(type == "CMD_STOP" && count >= 1) {
      Print("⛔ Received STOP command from Server via TCP!");
       
      // 1. หยุดตัวแปร Global
      //IsCopyingActive = false;
      
      // 2. เคลียร์พอร์ตทันที
      //CloseAllPositions();
      
      // 3. (Optional) แจ้งเตือนบนหน้าจอ
      Comment("⛔ COPY TRADE STOPPED"); 
   }
   else if(type == "CMD_SYNC_CLOSE" && count >= 2) {
      ulong ticket_to_close = StringToInteger(parts[1]);
      
      Print("⛔ Sync Alert: Closing unauthorized trade ", ticket_to_close);

      if(!trade.PositionClose(ticket_to_close)) {
         Print("Failed to close position #", ticket_to_close, " Error: ", GetLastError());
      } else {
         Print("Closed position #", ticket_to_close);
      }
   }
   else if(type == "CMD_CLOSE_ALL" && count >= 1) {
      Print("🚨 EMERGENCY: Closing all positions due to Partner Stop Out!");
      
      CloseAllPositions();

      // แสดงข้อความเตือนบนกราฟ
      Comment("🚨 EMERGENCY STOP: PARTNER STOPPED OUT!");
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
      if(HistoryDealGetInteger(dealTicket, DEAL_REASON) != DEAL_REASON_EXPERT) {
          // ไปเช็คต่อใน Comment ว่าใช่ SO หรือไม่
          //if (CheckDealForStopOut(dealTicket)) return;
          CheckDealForStopOut(dealTicket);
      }

      string masterSymbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      if(masterSymbol != _Symbol) return;
      
      // ✅ 1. ตรวจสอบ Magic Number
      long magic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      // ถ้า Magic ตรงกับที่ตั้งให้ข้าม (เช่น เป็นออเดอร์ที่ EA ตัวนี้เปิดเอง)
      if(magic == InpIgnoreMagic) return;
      
      // ✅ 2. ดึง Master Ticket (ใช้ Position ID แม่นยำที่สุด)
      long masterTicket = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      
      // เช็คเพิ่มเติม: ถ้า Position ID เป็น 0 อาจเป็น Deal แปลกๆ ให้ข้าม
      if(masterTicket == 0) return;

      // ตรวจสอบ Magic ของ Order ต้นทาง (เผื่อ Deal ไม่มี Magic)
      if(HistoryOrderSelect(masterTicket)) {
         long orderMagic = HistoryOrderGetInteger(masterTicket, ORDER_MAGIC);
         if(orderMagic == InpIgnoreMagic) return;
      }
      
      // ✅ 3. ดึงข้อมูลพื้นฐาน
      long entry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      int digits = (int)SymbolInfoInteger(masterSymbol, SYMBOL_DIGITS);
      double volume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      double price = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      double lot = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      double sl = HistoryDealGetDouble(dealTicket, DEAL_SL);
      double tp = HistoryDealGetDouble(dealTicket, DEAL_TP);
      
      string tradeSymbol = FixSymbolName(masterSymbol);
      
      string msg = "";
      
      // --- กรณีเปิดออเดอร์ (Entry In) ---
      if(entry == DEAL_ENTRY_IN) {
         long type = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
         string side = "";
         
         if(type == DEAL_TYPE_BUY) side = "BUY";
         else if(type == DEAL_TYPE_SELL) side = "SELL";
         
         if(side != "") {
            // Format: SIGNAL_OPEN|BUY|SYMBOL|PRICE|VOLUME|SL|TP|MASTER_TICKET
            msg = "SIGNAL_OPEN|" + side + "|" + tradeSymbol + "|" + DoubleToString(price, digits)
               + "|" + DoubleToString(lot, 2)
               + "|" + DoubleToString(sl, digits)
               + "|" + DoubleToString(tp, digits)
               + "|" + IntegerToString(masterTicket);
         }
      }
      // --- กรณีปิดออเดอร์ (Entry Out) ---
      else if(entry == DEAL_ENTRY_OUT) {
         double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
         double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) + HistoryDealGetDouble(dealTicket, DEAL_SWAP) + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         // Format: SIGNAL_CLOSE|SYMBOL|MASTER_TICKET|CLOSE_PRICE|PROFIT
         msg = "SIGNAL_CLOSE|" + tradeSymbol + "|" + IntegerToString(masterTicket) 
               + "|" + DoubleToString(closePrice, 5)
               + "|" + DoubleToString(profit, 2);
      }

      // ✅ 4. ส่งผ่าน Socket ทันที
      if(msg != "") {
         if(!SendTCPMessage(msg + "\n")) {
            // ถ้าส่งไม่ผ่าน ให้ลองต่อใหม่แล้วส่งอีกรอบ
            Reconnect();
            SendSymbolInit(tradeSymbol, masterSymbol);
            SendTCPMessage(msg + "\n"); 
         } else {
            Print("🚀 Sent: ", msg);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helper: เชื่อมต่อ Server                                           |
//+------------------------------------------------------------------+
void ConnectToServer() {
   socketHandle = SocketCreate();
   if(socketHandle == INVALID_HANDLE) {
      // Print("❌ Failed to create socket");
      return;
   }
   
   if(SocketConnect(socketHandle, InpServerIP, InpServerPort, 1000)) {
      Print("✅ Connected! Sending Auth...");
      isAuthenticated = false;
      // 🔥 ส่ง API Key เพื่อยืนยันตัวตน
      string authMsg = "AUTH:" + InpApiKey;
      SendTCPMessage(authMsg + "\n");
      
      lastPingTime = GetTickCount();
   } else {
      SocketClose(socketHandle);
      socketHandle = INVALID_HANDLE;
   }
}

void Reconnect() {
   SocketClose(socketHandle);
   socketHandle = INVALID_HANDLE;
   ConnectToServer();
   tcpBuffer = ""; // Clear buffer
}

// ฟังก์ชันส่งข้อความ String
bool SendTCPMessage(string text) {
   if(socketHandle == INVALID_HANDLE) return false;
   uchar data[];
   StringToCharArray(text, data, 0, StringLen(text));
   return (SocketSend(socketHandle, data, StringLen(text)) >= 0);
}

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

   //Print("debug: ", finalSymbol);
   //string coreName = StringSubstr(masterSymbol, 0, 6) + StringSubstr(Symbol(), 6);
   //Print("Auto-detection: Symbol " + coreName);

   return finalSymbol;
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

void SendPriceUpdate() {
   if(socketHandle == INVALID_HANDLE) return;

    double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    uint   currentTick = GetTickCount();
    
    // เงื่อนไข: ราคาเปลี่ยนเกินระยะที่กำหนด OR ครบกำหนดเวลา (ms)
    if(MathAbs(currentBid - lastSentBid) > 0.1|| (currentTick - lastPriceSentTick) >= priceUpdateInterval) {
        
        // Format: CMD_PRICE|SYMBOL|BID|ASK
        string msg = "CMD_PRICE|" + _Symbol + "|" + 
                     DoubleToString(currentBid, _Digits) + "|" + 
                     DoubleToString(currentAsk, _Digits);
        // Print(msg);
        
        if(SendTCPMessage(msg + "\n")) { // ใช้ฟังก์ชันส่ง TCP เดิมของคุณ
            lastSentBid = currentBid;
            lastPriceSentTick = currentTick;
            
            lastPingTime = currentTick;
        }
    }
}

void SendMasterSnapshot() {
   if(socketHandle == INVALID_HANDLE) return;
   if(!isAuthenticated) return;

   uint currentTick = GetTickCount();
   
   if((currentTick - lastSyncTime) >= syncUpdateInterval) {
      string tickets = "";
      for(int i=PositionsTotal()-1; i>=0; i--) {
         ulong ticket = PositionGetTicket(i);
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) != InpIgnoreMagic) {
            tickets += IntegerToString(ticket) + (i > 0 ? "," : "");
         }
      }
      // ส่ง Format: SNAPSHOT:TICKET1,TICKET2,TICKET3
      string msg = "MASTER_SNAPSHOT:" + tickets;
      Print(msg);
      SendTCPMessage(msg + "\n");
      
      lastSyncTime = currentTick;
   }
}

void SendSymbolInit(string _tradeSymbol, string _masterSymbol) {
   if (HasSentSymbol(_tradeSymbol)) return;
   
   double contract_size = SymbolInfoDouble(_masterSymbol, SYMBOL_TRADE_CONTRACT_SIZE);
   int digits = (int)SymbolInfoInteger(_masterSymbol, SYMBOL_DIGITS);
   
   // รูปแบบ: CMD_INIT_SYMBOL|SYMBOL|CONTRACT_SIZE|DIGITS
   string msg = "CMD_INIT_SYMBOL|" + _tradeSymbol + "|" + 
                DoubleToString(contract_size, 2) + "|" + IntegerToString(digits);
   SendTCPMessage(msg + "\n");
   Print("System: Symbol configuration sent to server.");
   Print(msg);
   MarkSentSymbol(_tradeSymbol);
}

void SendMasterMode() {
   if(socketHandle == INVALID_HANDLE) return;
   
   string mode_str = "PUBSUB";
   if(InpCopyMode == MODE_1TO1)       mode_str = "1TO1";
   else if(InpCopyMode == MODE_RECORD) mode_str = "RECORD";
   string msg = "CMD_SET_MODE|" + mode_str;
   
   Print("📡 Sending Master Mode: ", mode_str);
   SendTCPMessage(msg + "\n");
}

void CheckDealForStopOut(ulong _ticket) {
   if(HistoryDealGetString(_ticket, DEAL_SYMBOL) == _Symbol) {
      string comment = HistoryDealGetString(_ticket, DEAL_COMMENT);
      
      // ตรวจสอบคำว่า "so" หรือ "stop out" (ตัวเล็กตัวใหญ่ไม่เกี่ยง)
      string lowerComment = comment;
      StringToLower(lowerComment);
      
      if(StringFind(lowerComment, "so") >= 0 || StringFind(lowerComment, "stop out") >= 0) {
         if (PositionsTotal() == 1)
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

void CloseAllPositions() {
   trade.SetAsyncMode(true);
   // 1. ปิด Positions (Buy/Sell) ที่เปิดค้างอยู่
   // ต้องวน Loop ย้อนกลับ (Count Down) เพราะจำนวน Position จะเปลี่ยนเมื่อเราปิด
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      
      if(ticket > 0) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol) {
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
         if(OrderGetString(ORDER_SYMBOL) == _Symbol) {
            if(!trade.OrderDelete(ticket)) {
               Print("Failed to delete pending order #", ticket, " Error: ", GetLastError());
            } else {
               Print("Deleted pending order #", ticket);
            }
         }
      }
   }
   trade.SetAsyncMode(false);
}

bool HasSentSymbol(string symbol) {
   for(int i = 0; i < g_sentSymbolsCount; i++) {
      if(g_sentSymbols[i] == symbol) return true;
   }
   return false;
}

void MarkSentSymbol(string symbol) {
   ArrayResize(g_sentSymbols, g_sentSymbolsCount + 1);
   g_sentSymbols[g_sentSymbolsCount] = symbol;
   g_sentSymbolsCount++;
}