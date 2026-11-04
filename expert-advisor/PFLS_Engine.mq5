
#property strict
#property version "1.82"
#property description "PFLS Trader - Multi-Timeframe Structure Confluence, Controlled Retry and Cloud Heartbeat"

#include "PFLS_Zones.mqh"
#include "PFLS_Execution.mqh"

// =====================================================
// ENGINE SETTINGS
// =====================================================

input int LookbackBars = 250;
input int PivotStrength = 2;
input int ScanIntervalSeconds = 30;
input int MinimumHTFVotes = 3;

// Leave blank in GitHub.
// Enter the actual secret privately in MT5 EA Inputs.
input string PFLS_BridgeSecret = "";

#define PFLS_TIMEFRAME_COUNT 8
#define PFLS_HTF_COUNT 5
#define PFLS_M5_INDEX 6

// =====================================================
// CLOUD COMMUNICATION SETTINGS
// =====================================================

#define PFLS_BRIDGE_URL "https://pfls-communication-bridge-v2.dlamininjabulombhodziya.workers.dev/api/ea/heartbeat"

#define PFLS_EA_VERSION "1.82"
#define PFLS_HEARTBEAT_INTERVAL 30
#define PFLS_BRIDGE_TIMEOUT 5000

datetime PFLS_LastHeartbeatTime = 0;

// =====================================================
// TIMEFRAMES
// =====================================================

ENUM_TIMEFRAMES PFLS_Timeframes[PFLS_TIMEFRAME_COUNT] =
{
   PERIOD_W1,
   PERIOD_D1,
   PERIOD_H4,
   PERIOD_H1,
   PERIOD_M30,
   PERIOD_M15,
   PERIOD_M5,
   PERIOD_M1
};

// =====================================================
// ZONE STORAGE
// =====================================================

PFLSZoneRecord PFLS_DemandZones[PFLS_TIMEFRAME_COUNT];
PFLSZoneRecord PFLS_SupplyZones[PFLS_TIMEFRAME_COUNT];

bool PFLS_ZonesReady = false;
datetime PFLS_LastScanTime = 0;

// =====================================================
// CONFLUENCE STORAGE
// =====================================================

datetime PFLS_ConfluenceSignalTime = 0;
int PFLS_ConfluenceVotes = 0;
bool PFLS_ConfluencePassed = false;
bool PFLS_ConfluenceEvaluated = false;

// =====================================================
// CLOUD HEARTBEAT
// =====================================================

void PFLS_SendHeartbeat()
{
   if(PFLS_BridgeSecret == "")
      return;

   datetime now = TimeLocal();

   if(PFLS_LastHeartbeatTime > 0 &&
      now - PFLS_LastHeartbeatTime < PFLS_HEARTBEAT_INTERVAL)
      return;

   // Prevent repeated requests if the bridge is unavailable.
   PFLS_LastHeartbeatTime = now;

   bool terminalConnected =
      (bool)TerminalInfoInteger(TERMINAL_CONNECTED);

   string terminalStatus =
      terminalConnected ? "true" : "false";

   string payload = StringFormat(
      "{\"ea_version\":\"%s\","
      "\"symbol\":\"%s\","
      "\"timeframe\":\"%s\","
      "\"status\":\"RUNNING\","
      "\"terminal_connected\":%s}",
      PFLS_EA_VERSION,
      _Symbol,
      EnumToString(_Period),
      terminalStatus
   );

   char requestData[];
   char responseData[];

   string responseHeaders;

   int dataSize = StringToCharArray(
      payload,
      requestData,
      0,
      WHOLE_ARRAY,
      CP_UTF8
   );

   if(dataSize <= 1)
   {
      Print("PFLS BRIDGE: Unable to prepare heartbeat.");
      return;
   }

   // Remove terminating null character.
   ArrayResize(requestData, dataSize - 1);

   string headers =
      "Content-Type: application/json\r\n"
      "Authorization: Bearer " +
      PFLS_BridgeSecret +
      "\r\n";

   ResetLastError();

   int responseCode = WebRequest(
      "POST",
      PFLS_BRIDGE_URL,
      headers,
      PFLS_BRIDGE_TIMEOUT,
      requestData,
      responseData,
      responseHeaders
   );

   if(responseCode == -1)
   {
      Print(
         "PFLS BRIDGE ERROR | WebRequest failed. Error: ",
         GetLastError()
      );

      return;
   }

   string responseText = CharArrayToString(
      responseData,
      0,
      -1,
      CP_UTF8
   );

   if(responseCode == 200)
   {
      Print(
         "PFLS HEARTBEAT ACCEPTED | ",
         "Symbol: ",
         _Symbol,
         " | Terminal connected: ",
         terminalConnected
      );
   }
   else
   {
      Print(
         "PFLS BRIDGE RESPONSE | HTTP: ",
         responseCode,
         " | Response: ",
         responseText
      );
   }
}

// =====================================================
// RESET ZONES
// =====================================================

void PFLS_ResetEngineZones()
{
   for(int i = 0; i < PFLS_TIMEFRAME_COUNT; i++)
   {
      PFLSZ_Reset(PFLS_DemandZones[i]);
      PFLSZ_Reset(PFLS_SupplyZones[i]);
   }
}

// =====================================================
// HIGHER TIMEFRAME CONFLUENCE
// =====================================================

bool PFLS_CheckHigherTimeframeConfluence(
   bool isBuy,
   int &votes
)
{
   votes = 0;

   int requiredDirection = isBuy ? 1 : -1;

   for(int i = 0; i < PFLS_HTF_COUNT; i++)
   {
      int bias = (int)PFLSZ_DetectMarketStructure(
         _Symbol,
         PFLS_Timeframes[i],
         LookbackBars,
         PivotStrength
      );

      string structure = "NEUTRAL";

      if(bias > 0)
         structure = "BULLISH";
      else if(bias < 0)
         structure = "BEARISH";

      Print(
         "PFLS STRUCTURE | ",
         EnumToString(PFLS_Timeframes[i]),
         " | ",
         structure
      );

      if(bias == requiredDirection)
         votes++;
   }

   Print(
      "PFLS CONFLUENCE | Direction: ",
      isBuy ? "BUY" : "SELL",
      " | Votes: ",
      votes,
      "/",
      PFLS_HTF_COUNT,
      " | Required: ",
      MinimumHTFVotes
   );

   return (votes >= MinimumHTFVotes);
}

// =====================================================
// MARKET SCAN
// =====================================================

void ScanMarket()
{
   PFLS_ZonesReady = false;

   PFLS_ResetEngineZones();

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("PFLS: Unable to obtain market price.");
      return;
   }

   if(tick.bid <= 0.0 || tick.ask <= 0.0)
      return;

   double currentPrice = (tick.bid + tick.ask) / 2.0;

   int detectedTimeframes = 0;

   for(int i = 0; i < PFLS_TIMEFRAME_COUNT; i++)
   {
      PFLSZoneRecord demand;
      PFLSZoneRecord supply;

      PFLSZ_Reset(demand);
      PFLSZ_Reset(supply);

      bool detected = PFLSZ_DetectNearestZones(
         _Symbol,
         PFLS_Timeframes[i],
         LookbackBars,
         PivotStrength,
         currentPrice,
         demand,
         supply
      );

      if(detected)
      {
         PFLS_DemandZones[i] = demand;
         PFLS_SupplyZones[i] = supply;

         detectedTimeframes++;
      }
   }

   PFLS_ZonesReady = (detectedTimeframes > 0);

   PFLS_LastScanTime = TimeCurrent();

   Print(
      "PFLS v1.82 SCAN | Symbol: ",
      _Symbol,
      " | Price: ",
      DoubleToString(currentPrice, _Digits),
      " | Valid timeframes: ",
      detectedTimeframes,
      "/",
      PFLS_TIMEFRAME_COUNT,
      " | Zones ready: ",
      PFLS_ZonesReady
   );
}

// =====================================================
// FIND NEAREST OPPOSING TARGET
// =====================================================

bool PFLS_FindNearestTarget(
   bool isBuy,
   double currentPrice,
   PFLSZoneRecord &target
)
{
   PFLSZ_Reset(target);

   double bestDistance = DBL_MAX;

   for(int i = 0; i < PFLS_TIMEFRAME_COUNT; i++)
   {
      PFLSZoneRecord candidate;

      if(isBuy)
      {
         candidate = PFLS_SupplyZones[i];

         if(!candidate.valid ||
            candidate.invalidated ||
            candidate.isDemand)
            continue;

         if(candidate.lower <= currentPrice)
            continue;

         double distance = candidate.lower - currentPrice;

         if(distance < bestDistance)
         {
            bestDistance = distance;
            target = candidate;
         }
      }
      else
      {
         candidate = PFLS_DemandZones[i];

         if(!candidate.valid ||
            candidate.invalidated ||
            !candidate.isDemand)
            continue;

         if(candidate.upper >= currentPrice)
            continue;

         double distance = currentPrice - candidate.upper;

         if(distance < bestDistance)
         {
            bestDistance = distance;
            target = candidate;
         }
      }
   }

   return target.valid;
}

// =====================================================
// PROCESS ENTRY
// =====================================================

void PFLS_ProcessEntry()
{
   bool hasPending = PFLS_ExecutionHasPendingSignal();

   if(!PFLS_ZonesReady && !hasPending)
      return;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   if(tick.bid <= 0.0 || tick.ask <= 0.0)
      return;

   bool isBuy = false;
   datetime signalTime = 0;

   PFLSZoneRecord entryZone;
   PFLSZ_Reset(entryZone);

   bool signalFound = PFLS_ExecutionGetM5Signal(
      PFLS_DemandZones[PFLS_M5_INDEX],
      PFLS_SupplyZones[PFLS_M5_INDEX],
      isBuy,
      signalTime,
      entryZone
   );

   if(!signalFound)
      return;

   Print(
      "PFLS BREAKOUT CONFIRMED | ",
      isBuy ? "BUY" : "SELL",
      " | ",
      TimeToString(signalTime)
   );

   // --------------------------------------------------
   // ENTRY ZONE VALIDATION
   // --------------------------------------------------

   if(!entryZone.valid || entryZone.invalidated)
   {
      Print("PFLS: Invalid entry zone.");

      PFLS_ExecutionConsumeSignal(signalTime);
      return;
   }

   // --------------------------------------------------
   // HIGHER TIMEFRAME CONFLUENCE
   // --------------------------------------------------

   if(!PFLS_ConfluenceEvaluated ||
      PFLS_ConfluenceSignalTime != signalTime)
   {
      PFLS_ConfluenceSignalTime = signalTime;
      PFLS_ConfluenceVotes = 0;

      PFLS_ConfluencePassed =
         PFLS_CheckHigherTimeframeConfluence(
            isBuy,
            PFLS_ConfluenceVotes
         );

      PFLS_ConfluenceEvaluated = true;
   }

   if(!PFLS_ConfluencePassed)
   {
      Print(
         "PFLS SIGNAL REJECTED | Insufficient higher timeframe agreement."
      );

      PFLS_ExecutionConsumeSignal(signalTime);
      return;
   }

   Print(
      "PFLS CONFLUENCE PASSED | ",
      PFLS_ConfluenceVotes,
      "/",
      PFLS_HTF_COUNT
   );

   // --------------------------------------------------
   // TARGET ZONE VALIDATION
   // --------------------------------------------------

   if(!PFLS_ZonesReady)
   {
      Print("PFLS: Target zones unavailable. Retaining setup.");
      return;
   }

   double currentPrice = isBuy ? tick.ask : tick.bid;

   PFLSZoneRecord targetZone;

   if(!PFLS_FindNearestTarget(
      isBuy,
      currentPrice,
      targetZone
   ))
   {
      Print("PFLS: No opposing target zone. Retaining setup.");
      return;
   }

   Print(
      "PFLS TARGET FOUND | ",
      isBuy ? "SUPPLY" : "DEMAND",
      " | Lower: ",
      targetZone.lower,
      " | Upper: ",
      targetZone.upper
   );

   // --------------------------------------------------
   // SIGNAL ONLY MODE
   // --------------------------------------------------

   if(!PFLS_EnableExecution)
   {
      Print(
         "PFLS SIGNAL ONLY | ",
         isBuy ? "BUY" : "SELL",
         " | Execution disabled."
      );

      PFLS_ExecutionConsumeSignal(signalTime);
      return;
   }

   // --------------------------------------------------
   // TRADE EXECUTION AND RETRY HANDLING
   // --------------------------------------------------

   bool tradeDecision = PFLS_ExecutionTryTrade(
      isBuy,
      entryZone,
      targetZone,
      signalTime
   );

   if(tradeDecision)
   {
      Print("PFLS: Trade request accepted. Consuming signal.");

      PFLS_ExecutionConsumeSignal(signalTime);
   }
   else
   {
      Print(
         "PFLS: Trade not accepted. "
         "Pending signal retained for controlled retry."
      );
   }
}

// =====================================================
// INITIALIZATION
// =====================================================

int OnInit()
{
   if(LookbackBars < 50 ||
      PivotStrength < 1 ||
      ScanIntervalSeconds < 5 ||
      MinimumHTFVotes < 1 ||
      MinimumHTFVotes > PFLS_HTF_COUNT)
   {
      Print("PFLS ERROR: Invalid engine settings.");
      return INIT_PARAMETERS_INCORRECT;
   }

   PFLS_ResetEngineZones();

   if(!EventSetTimer(ScanIntervalSeconds))
   {
      Print("PFLS ERROR: Timer initialization failed.");
      return INIT_FAILED;
   }

   Print("======================================");
   Print("PFLS TRADER ENGINE v1.82");
   Print("Symbol: ", _Symbol);
   Print("Timeframes: 8");
   Print("Structure timeframes: 5");
   Print("Minimum structure votes: ", MinimumHTFVotes);
   Print("Execution enabled: ", PFLS_EnableExecution);
   Print("Controlled retry handling: ACTIVE");
   Print("Cloud heartbeat: ", 
         PFLS_BridgeSecret != "" ? "CONFIGURED" : "NOT CONFIGURED");
   Print("======================================");

   if(PFLS_BridgeSecret == "")
   {
      Print(
         "PFLS NOTICE: Cloud heartbeat disabled. "
         "Enter the bridge secret in EA Inputs."
      );
   }

   ScanMarket();

   return INIT_SUCCEEDED;
}

// =====================================================
// TICK EVENT
// =====================================================

void OnTick()
{
   PFLS_ProcessEntry();
}

// =====================================================
// TIMER EVENT
// =====================================================

void OnTimer()
{
   ScanMarket();

   PFLS_SendHeartbeat();
}

// =====================================================
// SHUTDOWN
// =====================================================

void OnDeinit(const int reason)
{
   EventKillTimer();

   Print(
      "PFLS ENGINE v1.82 stopped. Reason: ",
      reason
   );
}
