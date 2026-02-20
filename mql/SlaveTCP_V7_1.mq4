//+------------------------------------------------------------------+
//|                                              SlaveTCP_V7_0.mq4 |
//|                                      TCP Version for Elixir Srvr |
//+------------------------------------------------------------------+
#property copyright "ATK"
#property link      "https://www.appcorner.com"
#property version   "7.0"
#property strict

#include "socket-library-mt4.mqh"

input string            InpServerIP    = "127.0.0.1";   // CopyTrade Pro Server
input int               InpServerPort  = 5001;          // Port
input string            InpApiKey      = "sk_live_FOLLOWER_KEY";  // API KEY ของ Follower (เอาจากหน้าเว็บ)
input string            InpMasterToken = "MST-XYZ";               // Token ของ Master ที่จะตาม
input long              InpMagic       = 123456; // Magic Number ที่ใช้เปิด Order ใหม่
input string            InpComment     = "CopyTradePro"; // ข้อความใน comment

// --- Symbol Settings ---
input bool              InpRemoveMasterSuffix  = false;        // เปิดใช้งานการตัด Suffix ของ Master
input string            InpMasterSuffixText    = "-VIPc";      // ข้อความ Suffix ที่ต้องการตัดออก (เช่น -VIPc)
input bool              InpAddSlaveSuffix      = false;        // เปิดใช้งานการเติม Suffix ของ Slave
input string            InpSlaveSuffixText     = ".m";         // ข้อความ Suffix ที่ต้องการเติม (เช่น .m)

// --- Symbol Mapping ---
input bool              InpApplyCustomMap   = false;        // เปิดใช้งานการแปลงชื่อ Symbol
input string            InpCustomMap = "GOLD=XAUUSD,SILVER=XAGUSD"; // แปลงชื่อ Symbol (ไม่แปลง ใส่ค่าว่าง)
   
// --- Money Management ---
enum ENUM_LOT_TYPE {
   LOT_FIXED,        // 1. ฟิกซ์ Lot เท่ากันทุกไม้
   LOT_MULTIPLIER,   // 2. คูณจาก Master (เช่น Master 0.1, เรา x2 = 0.2)
   LOT_SAME_AS_MASTER // 3. ตาม Master เป๊ะๆ
};

input ENUM_LOT_TYPE     InpLotType        = LOT_MULTIPLIER; // เลือกโหมดคำนวณ Lot
input double            InpLotSize        = 0.01;           // ค่า Lot (กรณีใช้ Fixed)
input double            InpLotMultiplier  = 1.0;            // ตัวคูณ (กรณีใช้ Multiplier)
input double            InpMinLotToCopy   = 0.0;            // Copy เฉพาะไม้ที่ Lot มากกว่าค่านี้ (0.0 = เอาหมด)

// --- Copy Settings ---
input bool              InpCopySLTP       = false;           // true=ตาม SL/TP Master, false=ไม่ใส่
input bool              InpReverseTrade   = false;          // โหมดสวนเทรนด์ (Master Buy -> เรา Sell)
input int               InpSyncIntervalMinutes = 15; // ระยะเวลาห่างในการส่ง Orders Snapshot (นาที)

// --- Global Variables ---
ClientSocket *socketClient = NULL;
ulong lastPingTime = 0;
ulong lastConnectAttempt = 0;
bool isSubscribed = false;
uint syncUpdateInterval;
ulong lastSyncTime = 0;
bool IsCopyingActive = true;
string g_sentSymbols[];
int g_sentSymbolsCount = 0;

// --- Order Tracking for SO detection ---
int g_knownTickets[];
int g_knownCount = 0;
int g_closedByCommand[];
int g_closedByCommandCount = 0;
int g_stopOutNotifiedTickets[];
int g_stopOutNotifiedCount = 0;

int OnInit() {
   syncUpdateInterval = InpSyncIntervalMinutes * 60 * 1000;
   lastSyncTime = 0;
   g_sentSymbolsCount = 0;
   ArrayResize(g_sentSymbols, 0);
   g_knownCount = 0;
   g_closedByCommandCount = 0;
   g_stopOutNotifiedCount = 0;
   ArrayResize(g_knownTickets, 0);
   ArrayResize(g_closedByCommand, 0);
   ArrayResize(g_stopOutNotifiedTickets, 0);
   EventSetMillisecondTimer(100);
   Print("[OK] Slave EA Initialized.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   if(socketClient != NULL) { delete socketClient; socketClient = NULL; }
   EventKillTimer();
   Print("[STOP] EA Stopped.");
}

void ConnectToServer() {
   if(GetTickCount() - lastConnectAttempt < 3000) return;
   lastConnectAttempt = GetTickCount();
   if(socketClient != NULL) { delete socketClient; socketClient = NULL; }

   Print("[CONN] Connecting to ", InpServerIP, ":", InpServerPort, "...");
   socketClient = new ClientSocket(InpServerIP, (ushort)InpServerPort);

   if(socketClient.IsSocketConnected()) {
      Print("[OK] Connected! Sending Auth...");
      isSubscribed = false;
      SendTCPMessage("AUTH:" + InpApiKey + "\n");
      lastPingTime = GetTickCount();
   } else {
      delete socketClient; socketClient = NULL;
      Print("[ERR] Connect Failed. Error: ", GetLastError());
   }
}

void Reconnect() {
Print("[WARN] Connection lost. Reconnecting...");
   if(socketClient != NULL) { delete socketClient; socketClient = NULL; }
}

void OnTimer() {
   if(socketClient == NULL || !socketClient.IsSocketConnected()) {
      ConnectToServer(); return;
   }
   CheckStopOut();

   // 1. อ่านข้อมูลจาก Socket
   string response = socketClient.Receive("\n");
   while(response != "") {
      StringTrimRight(response); StringTrimLeft(response);
      if(StringLen(response) > 0) ProcessCommand(response);
      response = socketClient.Receive("\n");
      Print("[RECV] Received: ", response);
   }
   if(socketClient != NULL && !socketClient.IsSocketConnected()) { Reconnect(); return; }

   // 2. ตรวจจับ external closes
   if(isSubscribed) DetectExternalCloses();

   // 3. Heartbeat
   if(GetTickCount() - lastPingTime > 5000) {
      if(!SendTCPMessage("PING\n")) { Reconnect(); return; }
      lastPingTime = GetTickCount();
      SendSlaveSnapshot();
      //if(isSubscribed) SendTCPMessage("CHECK_STATUS\n");
   }
}

bool SendTCPMessage(string text) {
   if(socketClient == NULL || !socketClient.IsSocketConnected()) return false;
   return socketClient.Send(text);
}

// ------------------------------------------------------------------
// ⚙️ Process Command
// ------------------------------------------------------------------
void ProcessCommand(string cmd) {
   Print("[CMD] RECV: ", cmd);

   if(StringFind(cmd, "AUTH_OK") >= 0) {
      Print("[AUTH] Login Success! Subscribing to ", InpMasterToken);
      SendTCPMessage("SUBSCRIBE:" + InpMasterToken + "\n");
      return;
   }
   if(StringFind(cmd, "SUBSCRIBE_OK") >= 0) {
      Print("[OK] Ready to copy Master: ", InpMasterToken);
      isSubscribed = true;
      InitializeKnownOrders();
      SendSlaveSnapshot();
      SendTCPMessage("CHECK_STATUS\n");
      return;
   }
   if(StringFind(cmd, "SNAPSHOT_OK") >= 0) { Print("[OK] Snapshot OK"); return; }
   if(StringFind(cmd, "ERROR:INVALID_TOKEN") >= 0) { Print("[ERR] Invalid Token!"); return; }

   string parts[];
   int count = StringSplit(cmd, '|', parts);
   if(count <= 0) return;
   string type = parts[0];

   // --- CMD_OPEN ---
   if(type == "CMD_OPEN" && count >= 8) {
      if(!IsCopyingActive) { Print("[SKIP] Ignored: INACTIVE."); return; }
      string typeStr = parts[1];
      string incomingSymbol = parts[2];
      string tradeSymbol = FixSymbolName(incomingSymbol);
      double masterLot = StringToDouble(parts[4]);
      double masterSL = StringToDouble(parts[5]);
      double masterTP = StringToDouble(parts[6]);
      string masterTicket = parts[7];

      if(masterLot <= InpMinLotToCopy) { Print("[WARN] Filtered by MinLot."); return; }

      // Lot calculation
      double tradeLot = InpLotSize;
      if(InpLotType == LOT_SAME_AS_MASTER) tradeLot = masterLot;
      else if(InpLotType == LOT_MULTIPLIER) tradeLot = masterLot * InpLotMultiplier;

      double minLot = MarketInfo(tradeSymbol, MODE_MINLOT);
      double maxLot = MarketInfo(tradeSymbol, MODE_MAXLOT);
      double stepLot = MarketInfo(tradeSymbol, MODE_LOTSTEP);
      tradeLot = MathFloor(tradeLot / stepLot) * stepLot;
      if(tradeLot < minLot) tradeLot = minLot;
      if(tradeLot > maxLot) tradeLot = maxLot;

      // SL/TP & Reverse
      double finalSL = 0, finalTP = 0;
      string finalType = typeStr;
      if(InpReverseTrade) {
         if(typeStr == "BUY") finalType = "SELL"; else if(typeStr == "SELL") finalType = "BUY";
      }
      if(InpCopySLTP) {
         if(InpReverseTrade) { finalSL = masterTP; finalTP = masterSL; }
         else { finalSL = masterSL; finalTP = masterTP; }
      }

      int orderType = (finalType == "BUY") ? OP_BUY : OP_SELL;
      double orderPrice = (finalType == "BUY") ? MarketInfo(tradeSymbol, MODE_ASK) : MarketInfo(tradeSymbol, MODE_BID);

      Print("[OPEN] Opening ", finalType, " ", tradeSymbol);
      int slaveTicket = OrderSend(tradeSymbol, orderType, tradeLot, orderPrice, 10, finalSL, finalTP, InpComment + " " + masterTicket, (int)InpMagic, 0);

      if(slaveTicket > 0) {
         Print("[OK] Opened: #", slaveTicket);
         string ack = "ACK_OPEN|" + masterTicket + "|" + IntegerToString(slaveTicket) + "|" + DoubleToString(tradeLot, 2) + "|" + finalType;
         SendTCPMessage(ack + "\n");
         ArrayResize(g_knownTickets, g_knownCount + 1);
         g_knownTickets[g_knownCount] = slaveTicket;
         g_knownCount++;
      } else {
         Print("[ERR] Failed: Error ", GetLastError());
         SendTCPMessage("ACK_OPEN_FAIL|" + masterTicket + "|Error:" + IntegerToString(GetLastError()) + "\n");
      }
      SendSymbolInit(tradeSymbol, incomingSymbol);
   }
   // --- CMD_CLOSE ---
   else if(type == "CMD_CLOSE" && count >= 4) {
      string incomingSymbol = parts[1];
      string tradeSymbol = FixSymbolName(incomingSymbol);
      int slaveTicket = (int)StringToInteger(parts[2]);
      string masterTicket = parts[3];

      // Mark as closed by command
      ArrayResize(g_closedByCommand, g_closedByCommandCount + 1);
      g_closedByCommand[g_closedByCommandCount] = slaveTicket;
      g_closedByCommandCount++;

      Print("[CLOSE] Closing #", slaveTicket);
      if(OrderSelect(slaveTicket, SELECT_BY_TICKET)) {
         double cp = (OrderType() == OP_BUY) ? MarketInfo(OrderSymbol(), MODE_BID) : MarketInfo(OrderSymbol(), MODE_ASK);
         if(OrderClose(slaveTicket, OrderLots(), cp, 10)) {
            if(OrderSelect(slaveTicket, SELECT_BY_TICKET, MODE_HISTORY)) {
               double profit = OrderProfit() + OrderSwap() + OrderCommission();
               SendTCPMessage("ACK_CLOSE|" + masterTicket + "|" + DoubleToString(OrderClosePrice(), 5) + "|" + DoubleToString(profit, 2) + "\n");
               Print("[OK] Closed. Profit: ", profit);
            }
         } else {
            SendTCPMessage("ACK_CLOSE_FAIL|" + masterTicket + "|Error:" + IntegerToString(GetLastError()) + "\n");
         }
      } else {
         Print("[WARN] Ticket #", slaveTicket, " not found");
      }
      SendSymbolInit(tradeSymbol, incomingSymbol);
   }
   else if(type == "CMD_STOP") {
      IsCopyingActive = false;
      CloseAllPositions();
      Comment("[STOP] COPY TRADE STOPPED");
   }
   else if(type == "CMD_SYNC_CLOSE" && count >= 2) {
      int tk = (int)StringToInteger(parts[1]);
      if(OrderSelect(tk, SELECT_BY_TICKET)) {
         double cp = (OrderType() == OP_BUY) ? MarketInfo(OrderSymbol(), MODE_BID) : MarketInfo(OrderSymbol(), MODE_ASK);
         bool res = OrderClose(tk, OrderLots(), cp, 3);
      }
   }
   else if(type == "STATUS_ACTIVE") {
      if(!IsCopyingActive) { IsCopyingActive = true; Comment(""); Print("[OK] ACTIVE"); }
   }
   else if(type == "STATUS_INACTIVE") {
      if(IsCopyingActive) { IsCopyingActive = false; Comment("[PAUSE] INACTIVE"); Print("[PAUSE] INACTIVE"); }
   }
}

// ------------------------------------------------------------------
// 🔍 Detect External Closes (SO, manual)
// ------------------------------------------------------------------
void InitializeKnownOrders() {
   g_knownCount = 0;
   ArrayResize(g_knownTickets, 0);
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
         if(OrderMagicNumber() == InpMagic && OrderType() <= OP_SELL) {
            ArrayResize(g_knownTickets, g_knownCount + 1);
            g_knownTickets[g_knownCount] = OrderTicket();
            g_knownCount++;
         }
      }
   }
   Print("[INIT] Initialized: ", g_knownCount, " orders");
}

void DetectExternalCloses() {
   // Build current list
   int currentTickets[];
   int currentCount = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
         if(OrderMagicNumber() == InpMagic && OrderType() <= OP_SELL) {
            ArrayResize(currentTickets, currentCount + 1);
            currentTickets[currentCount] = OrderTicket();
            currentCount++;
         }
      }
   }

   // Find disappeared orders
   for(int i = 0; i < g_knownCount; i++) {
      bool found = false;
      for(int j = 0; j < currentCount; j++) {
         if(g_knownTickets[i] == currentTickets[j]) { found = true; break; }
      }
      if(!found) {
         // Check if closed by our CMD_CLOSE
         bool closedByUs = false;
         for(int k = 0; k < g_closedByCommandCount; k++) {
            if(g_closedByCommand[k] == g_knownTickets[i]) {
               closedByUs = true;
               for(int m = k; m < g_closedByCommandCount - 1; m++) g_closedByCommand[m] = g_closedByCommand[m+1];
               g_closedByCommandCount--;
               ArrayResize(g_closedByCommand, MathMax(g_closedByCommandCount, 0));
               break;
            }
         }
         if(!closedByUs && OrderSelect(g_knownTickets[i], SELECT_BY_TICKET, MODE_HISTORY)) {
            CheckOrderForStopOut(g_knownTickets[i]);
            double profit = OrderProfit() + OrderSwap() + OrderCommission();
            string resp = "ACK_CLOSE_SO|" + IntegerToString(g_knownTickets[i]) + "|" + DoubleToString(OrderClosePrice(), 5) + "|" + DoubleToString(profit, 2);
            SendTCPMessage(resp + "\n");
            Print("[SO] External close #", g_knownTickets[i]);
         }
      }
   }

   // Update
   g_knownCount = currentCount;
   ArrayResize(g_knownTickets, currentCount);
   if(currentCount > 0) ArrayCopy(g_knownTickets, currentTickets);
}

// --- Symbol Functions ---
string FixSymbolName(string masterSymbol) {
   string finalSymbol = masterSymbol;
   if(InpRemoveMasterSuffix && StringLen(InpMasterSuffixText) > 0)
      StringReplace(finalSymbol, InpMasterSuffixText, "");
   if (InpApplyCustomMap && StringLen(InpCustomMap) > 0)
      finalSymbol = GetCustomMapping(finalSymbol);

   if(InpAddSlaveSuffix && StringLen(InpSlaveSuffixText) > 0)
      finalSymbol = finalSymbol + InpSlaveSuffixText;
   if(MarketInfo(finalSymbol, MODE_DIGITS) == 0) {
      string coreName = StringSubstr(masterSymbol, 0, 6) + StringSubstr(Symbol(), 6);
      if(MarketInfo(coreName, MODE_DIGITS) > 0) return coreName;
   }
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

void CloseAllPositions() {
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
         if(OrderMagicNumber() == InpMagic) {
            if(OrderType() <= OP_SELL) {
               double cp = (OrderType() == OP_BUY) ? MarketInfo(OrderSymbol(), MODE_BID) : MarketInfo(OrderSymbol(), MODE_ASK);
               bool res = OrderClose(OrderTicket(), OrderLots(), cp, 3);
            } else bool res = OrderDelete(OrderTicket());
         }
      }
   }
}

void SendSlaveSnapshot() {
   if(socketClient == NULL || !isSubscribed) return;
   uint currentTick = GetTickCount();
   if((currentTick - lastSyncTime) >= syncUpdateInterval) {
      string tickets = "";
      for(int i = OrdersTotal() - 1; i >= 0; i--) {
         if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
            if(OrderMagicNumber() == InpMagic && OrderType() <= OP_SELL) {
               if(tickets != "") tickets += ",";
               tickets += IntegerToString(OrderTicket());
            }
         }
      }
      SendTCPMessage("SLAVE_SNAPSHOT:" + tickets + "\n");
      lastSyncTime = currentTick;
   }
}

void SendSymbolInit(string _tradeSymbol, string _masterSymbol) {
   if(HasSentSymbol(_masterSymbol)) return;
   double cs = MarketInfo(_tradeSymbol, MODE_LOTSIZE);
   int dg = (int)MarketInfo(_tradeSymbol, MODE_DIGITS);
   SendTCPMessage("CMD_INIT_SYMBOL|" + _masterSymbol + "|" + DoubleToString(cs, 2) + "|" + IntegerToString(dg) + "\n");
   MarkSentSymbol(_masterSymbol);
}

void CheckStopOut() {
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double soLevel = AccountStopoutLevel();
   if(marginLevel <= soLevel && marginLevel > 0) {
      int ourCount = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--) {
         if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && OrderMagicNumber() == InpMagic) ourCount++;
      }
      if(ourCount <= 1) {
         SendTCPMessage("ALERT_STOP_OUT|MarginLevel:" + DoubleToString(marginLevel, 2) + "\n");
         Print("[SO] STOP OUT!");
      }
      lastSyncTime = GetTickCount();
   }
   Comment(StringFormat("SO Level:%.f, Margin Level:%.2f", soLevel, marginLevel));
}

bool CheckOrderForStopOut(int ticket) {
   if(IsStopOutTicketNotified(ticket)) return false;
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY)) return false;

   string comment = OrderComment();
   string lowerComment = comment;
   StringToLower(lowerComment);

   if(StringFind(lowerComment, "so") >= 0 || StringFind(lowerComment, "stop out") >= 0) {
      string msg = "ALERT_STOP_OUT|Comment:" + comment;
      SendTCPMessage(msg + "\n");
      Print("[SO] STOP OUT detected by order comment. Ticket #", ticket, " Comment: ", comment);
      MarkStopOutTicketNotified(ticket);
      lastSyncTime = GetTickCount();
      return true;
   }
   return false;
}

bool IsStopOutTicketNotified(int ticket) {
   for(int i = 0; i < g_stopOutNotifiedCount; i++) {
      if(g_stopOutNotifiedTickets[i] == ticket) return true;
   }
   return false;
}

void MarkStopOutTicketNotified(int ticket) {
   ArrayResize(g_stopOutNotifiedTickets, g_stopOutNotifiedCount + 1);
   g_stopOutNotifiedTickets[g_stopOutNotifiedCount] = ticket;
   g_stopOutNotifiedCount++;
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
