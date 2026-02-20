//+------------------------------------------------------------------+
//|                                       MasterSenderTCP_V7_0.mq4 |
//|                                      TCP Version for Elixir Srvr |
//+------------------------------------------------------------------+
#property copyright "ATK"
#property link      "https://www.appcorner.com"
#property version   "7.0"
#property strict

#include "socket-library-mt4.mqh"

// --- Config ---
input string            InpServerIP   = "127.0.0.1";    // CopyTrade Pro Server
input int               InpServerPort = 5001;           // Port
input string            InpApiKey     = "sk_live_MASTER_KEY"; // API KEY ของ Master (เอาจากหน้าเว็บ)
input long              InpIgnoreMagic = 123456;        // Magic Number ที่ไม่ต้องการส่ง

// --- Symbol Settings ---
input bool              InpRemoveMasterSuffix = false;        // เปิดใช้งานการตัด Suffix ของ Master
input string            InpMasterSuffixText   = "-VIPc";     // ข้อความ Suffix ที่ต้องการตัดออก (เช่น -VIPc)

// --- Symbol Mapping Settings ---
input bool              InpApplyCustomMap   = false;        // เปิดใช้งานการแปลงชื่อ Symbol
input string            InpCustomMap = "GOLD=XAUUSD,SILVER=XAGUSD"; // แปลงชื่อ Symbol (ไม่แปลง ใส่ค่าว่าง)

// --- Copy Settings ---
enum ENUM_COPY_MODE { MODE_1TO1, MODE_PUBSUB, MODE_RECORD };
input ENUM_COPY_MODE    InpCopyMode = MODE_PUBSUB; // เลือกโหมดการส่งสัญญาณ
input bool              InpSyncModeFromEA = false;  // ส่ง Mode จาก EA ไปอัปเดต Server (ปกติตั้งจาก Web)
input int               InpSyncIntervalMinutes = 5; // ระยะเวลาห่างในการส่ง Orders Snapshot (นาที)

// --- Global Variables ---
ClientSocket *socketClient = NULL;
uint lastPingTime = 0;
double lastSentBid = 0;
uint lastPriceSentTick = 0;
uint priceUpdateInterval = 1000;
bool isAuthenticated = false;
uint syncUpdateInterval;
ulong lastSyncTime = 0;
bool isSendSymbolInit = false;
bool isModeSent = false;

// --- Order Tracking (แทน OnTradeTransaction) ---
int g_knownTickets[];
int g_knownCount = 0;
bool g_isFirstScan = true;

//+------------------------------------------------------------------+
int OnInit() {
   syncUpdateInterval = InpSyncIntervalMinutes * 60 * 1000;
   isSendSymbolInit = false;
   isModeSent = false;
   g_isFirstScan = true;
   g_knownCount = 0;
   ArrayResize(g_knownTickets, 0);
   EventSetTimer(1);
   ConnectToServer();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   if(socketClient != NULL) { 
      delete socketClient;
      socketClient = NULL; 
   }
   EventKillTimer();
}

void OnTimer() {
   if(socketClient == NULL || !socketClient.IsSocketConnected()) {
      if(socketClient != NULL) { 
         delete socketClient;
         socketClient = NULL;
      }
      ConnectToServer();
      return;
   }

   CheckStopOut();

   // 1. อ่านข้อมูลจาก Socket
   string response = socketClient.Receive("\n");
   while(response != "") {
      StringTrimRight(response); StringTrimLeft(response);
      if(StringLen(response) > 0) ProcessCommand(response);
      response = socketClient.Receive("\n");
   }

   if(socketClient != NULL && !socketClient.IsSocketConnected()) {
      Print("[WARNING] Read Failed. Reconnecting...");
      Reconnect(); return;
   }

   if(isAuthenticated && !isModeSent) {
      if(InpSyncModeFromEA) {
         SendMasterMode();
         Print("[MODE] Mode synced from EA to Server");
      }
      isModeSent = true;
   }

   // 2. ตรวจจับการเทรด (แทน OnTradeTransaction)
   if(isAuthenticated) DetectTradeChanges();

   // 3. Ping ทุก 5 วินาที
   if(GetTickCount() - lastPingTime > 5000) {
      if(!SendTCPMessage("PING\n")) {
         Print("[ERROR] Ping failed. Reconnecting...");
         Reconnect(); return;
      }
      lastPingTime = GetTickCount();
      SendMasterSnapshot();
   }

   SendPriceUpdate();
}

// ------------------------------------------------------------------
// ⚙️ Process Command
// ------------------------------------------------------------------
void ProcessCommand(string cmd) {
   Print("[CMD] RECV: ", cmd);

   if(StringFind(cmd, "AUTH_OK") >= 0) {
      Print("[AUTH] Login Success!");
      isAuthenticated = true;
      InitializeKnownOrders();
      SendMasterSnapshot();
      return;
   }

   if(StringFind(cmd, "SNAPSHOT_OK") >= 0) { 
      Print("[OK] Order reconciliation ok.");
      return;
   }

   string parts[];
   int count = StringSplit(cmd, '|', parts);
   if(count <= 0) return;
   string type = parts[0];

   if(type == "CMD_STOP") {
       Print("[STOP] Received STOP command from Server via TCP!");
      Comment("[STOP] COPY TRADE STOPPED");
   }
   else if(type == "CMD_SYNC_CLOSE" && count >= 2) {
      int ticket = (int)StringToInteger(parts[1]);
      Print("[STOP] Sync Alert: Closing unauthorized trade ", ticket);
      if(OrderSelect(ticket, SELECT_BY_TICKET)) {
         double cp = (OrderType() == OP_BUY) ? MarketInfo(OrderSymbol(), MODE_BID) : MarketInfo(OrderSymbol(), MODE_ASK);
         OrderClose(ticket, OrderLots(), cp, 3);
         Print("Closed position #", ticket);
      }
   }
   else if(type == "CMD_CLOSE_ALL") {
      Print("[SO] EMERGENCY: Closing all positions due to Partner Stop Out!");

      CloseAllPositions();
      Comment("[SO] EMERGENCY STOP: PARTNER STOPPED OUT!");
   }
}

// ------------------------------------------------------------------
// 🔍 Trade Detection (แทน OnTradeTransaction)
// ------------------------------------------------------------------
void InitializeKnownOrders() {
   g_knownCount = 0;
   ArrayResize(g_knownTickets, 0);
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() != InpIgnoreMagic && OrderType() <= OP_SELL) {
            ArrayResize(g_knownTickets, g_knownCount + 1);
            g_knownTickets[g_knownCount] = OrderTicket();
            g_knownCount++;
         }
      }
   }
   g_isFirstScan = false;
   Print("[INIT] Initialized with ", g_knownCount, " known orders");
}

void DetectTradeChanges() {
   if(g_isFirstScan) return;

   // Build current order list
   int currentTickets[];
   int currentCount = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() != InpIgnoreMagic && OrderType() <= OP_SELL) {
            ArrayResize(currentTickets, currentCount + 1);
            currentTickets[currentCount] = OrderTicket();
            currentCount++;
         }
      }
   }

   // Find NEW orders
   for(int i = 0; i < currentCount; i++) {
      bool found = false;
      for(int j = 0; j < g_knownCount; j++) {
         if(currentTickets[i] == g_knownTickets[j]) { found = true; break; }
      }
      if(!found && OrderSelect(currentTickets[i], SELECT_BY_TICKET)) {
         string tradeSymbol = FixSymbolName(OrderSymbol());
         string side = (OrderType() == OP_BUY) ? "BUY" : "SELL";
         int digits = (int)MarketInfo(OrderSymbol(), MODE_DIGITS);
         string msg = "SIGNAL_OPEN|" + side + "|" + tradeSymbol + "|"
            + DoubleToString(OrderOpenPrice(), digits) + "|"
            + DoubleToString(OrderLots(), 2) + "|"
            + DoubleToString(OrderStopLoss(), digits) + "|"
            + DoubleToString(OrderTakeProfit(), digits) + "|"
            + IntegerToString(OrderTicket());
         if(!SendTCPMessage(msg + "\n")) {
            Reconnect();
            SendSymbolInit(tradeSymbol, OrderSymbol());
            SendTCPMessage(msg + "\n");
         } else {
            Print("[CMD] Sent: ", msg);
         }
      }
   }

   // Find CLOSED orders
   for(int i = 0; i < g_knownCount; i++) {
      bool found = false;
      for(int j = 0; j < currentCount; j++) {
         if(g_knownTickets[i] == currentTickets[j]) { found = true; break; }
      }
      if(!found && OrderSelect(g_knownTickets[i], SELECT_BY_TICKET, MODE_HISTORY)) {
         string tradeSymbol = FixSymbolName(OrderSymbol());
         double profit = OrderProfit() + OrderSwap() + OrderCommission();
         string msg = "SIGNAL_CLOSE|" + tradeSymbol + "|"
            + IntegerToString(OrderTicket()) + "|"
            + DoubleToString(OrderClosePrice(), 5) + "|"
            + DoubleToString(profit, 2);
         if(!SendTCPMessage(msg + "\n")) {
            Reconnect();
            SendSymbolInit(tradeSymbol, OrderSymbol());
            SendTCPMessage(msg + "\n");
         } else {
            Print("[CMD] Sent: ", msg);
         }
      }
   }

   // Update known list
   g_knownCount = currentCount;
   ArrayResize(g_knownTickets, currentCount);
   if(currentCount > 0) ArrayCopy(g_knownTickets, currentTickets);
}

// ------------------------------------------------------------------
// 🔌 Connection
// ------------------------------------------------------------------
void ConnectToServer() {
   isAuthenticated = false;
   isModeSent = false;
   socketClient = new ClientSocket(InpServerIP, (ushort)InpServerPort);
   if(socketClient.IsSocketConnected()) {
      Print("[OK] Connected! Sending Auth...");
      SendTCPMessage("AUTH:" + InpApiKey + "\n");
      lastPingTime = GetTickCount();
   } else {
      delete socketClient; socketClient = NULL;
   }
}

void Reconnect() {
   if(socketClient != NULL) { 
      delete socketClient;
      socketClient = NULL;
   }
   ConnectToServer();
}

bool SendTCPMessage(string text) {
   if(socketClient == NULL || !socketClient.IsSocketConnected()) return false;
   return socketClient.Send(text);
}

string FixSymbolName(string masterSymbol) {
   string finalSymbol = masterSymbol;
   if(InpRemoveMasterSuffix && StringLen(InpMasterSuffixText) > 0)
      StringReplace(finalSymbol, InpMasterSuffixText, "");
   
   if (InpApplyCustomMap && StringLen(InpCustomMap) > 0)
      finalSymbol = GetCustomMapping(finalSymbol);
   return finalSymbol;
}

string GetCustomMapping(string serverSymbol) {
   if(InpCustomMap == "") return serverSymbol;
   string maps[];
   int count = StringSplit(InpCustomMap, ',', maps);
   for(int i = 0; i < count; i++) {
      string pts[];
      if(StringSplit(maps[i], '=', pts) == 2) {
         StringTrimLeft(pts[0]); StringTrimRight(pts[0]);
         StringTrimLeft(pts[1]); StringTrimRight(pts[1]);
         if(StringCompare(pts[0], serverSymbol, false) == 0) return pts[1];
      }
   }
   return serverSymbol;
}

void SendPriceUpdate() {
   if(socketClient == NULL) return;
   double currentBid = MarketInfo(Symbol(), MODE_BID);
   double currentAsk = MarketInfo(Symbol(), MODE_ASK);
   uint currentTick = GetTickCount();
   if(MathAbs(currentBid - lastSentBid) > 0.1 || (currentTick - lastPriceSentTick) >= priceUpdateInterval) {
      string msg = "CMD_PRICE|" + Symbol() + "|" + DoubleToString(currentBid, Digits) + "|" + DoubleToString(currentAsk, Digits);
      if(SendTCPMessage(msg + "\n")) {
         lastSentBid = currentBid;
         lastPriceSentTick = currentTick;
         lastPingTime = currentTick;
      }
   }
}

void SendMasterSnapshot() {
   if(socketClient == NULL || !isAuthenticated) return;
   uint currentTick = GetTickCount();
   if((currentTick - lastSyncTime) >= syncUpdateInterval) {
      string tickets = "";
      for(int i = OrdersTotal() - 1; i >= 0; i--) {
         if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
            if(OrderSymbol() == Symbol() && OrderMagicNumber() != InpIgnoreMagic && OrderType() <= OP_SELL) {
               if(tickets != "") tickets += ",";
               tickets += IntegerToString(OrderTicket());
            }
         }
      }
      SendTCPMessage("MASTER_SNAPSHOT:" + tickets + "\n");
      lastSyncTime = currentTick;
   }
}

void SendSymbolInit(string _tradeSymbol, string _masterSymbol) {
   if(isSendSymbolInit) return;
   double cs = MarketInfo(_masterSymbol, MODE_LOTSIZE);
   int dg = (int)MarketInfo(_masterSymbol, MODE_DIGITS);
   string msg = "CMD_INIT_SYMBOL|" + _tradeSymbol + "|" + DoubleToString(cs, 2) + "|" + IntegerToString(dg);
   SendTCPMessage(msg + "\n");
   isSendSymbolInit = true;
}

void SendMasterMode() {
   if(socketClient == NULL) return;
   string mode_str = "PUBSUB";
   if(InpCopyMode == MODE_1TO1) mode_str = "1TO1";
   else if(InpCopyMode == MODE_RECORD) mode_str = "RECORD";
   SendTCPMessage("CMD_SET_MODE|" + mode_str + "\n");
}

void CheckStopOut() {
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double soLevel = AccountStopoutLevel();
   if(marginLevel <= soLevel && marginLevel > 0) {
      if(OrdersTotal() == 1) {
         SendTCPMessage("ALERT_STOP_OUT|MarginLevel:" + DoubleToString(marginLevel, 2) + "\n");
         Print("[SO] STOP OUT DETECTED!");
      }
      lastSyncTime = GetTickCount();
   }
   Comment(StringFormat("SO Level:%.f, Margin Level:%.2f", soLevel, marginLevel));
}

void CloseAllPositions() {
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
         if(OrderSymbol() == Symbol()) {
            if(OrderType() <= OP_SELL) {
               double cp = (OrderType() == OP_BUY) ? MarketInfo(Symbol(), MODE_BID) : MarketInfo(Symbol(), MODE_ASK);
               OrderClose(OrderTicket(), OrderLots(), cp, 3);
            } else {
               OrderDelete(OrderTicket());
            }
         }
      }
   }
}
