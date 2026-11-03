
#property strict
#property version "1.72"
#property description "PFLS Trader - Multi-Timeframe Zone and Tick Execution Engine"

#include "PFLS_Zones.mqh"
#include "PFLS_Execution.mqh"

// =====================================================
// ENGINE SETTINGS
// =====================================================

input int LookbackBars = 250;
input int PivotStrength = 2;
input int ScanIntervalSeconds = 30;

#define PFLS_TIMEFRAME_COUNT 8
#define PFLS_M5_INDEX 6

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

      // Zones v1.30 requires currentPrice.
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
      "PFLS v1.72 SCAN | Symbol: ",
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

   // Execution v1.60: exactly five arguments.
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

   if(!entryZone.valid || entryZone.invalidated)
   {
      Print("PFLS: Invalid entry zone.");

      PFLS_ExecutionConsumeSignal(signalTime);
      return;
   }

   // Wait for fresh target-zone information.
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

   // Execution v1.60: exactly four arguments.
   bool tradeDecision = PFLS_ExecutionTryTrade(
      isBuy,
      entryZone,
      targetZone,
      signalTime
   );

   if(tradeDecision)
      Print("PFLS: Trade request accepted.");
   else
      Print("PFLS: Trade conditions not satisfied.");

   PFLS_ExecutionConsumeSignal(signalTime);
}

// =====================================================
// INITIALIZATION
// =====================================================

int OnInit()
{
   if(LookbackBars < 50 ||
      PivotStrength < 1 ||
      ScanIntervalSeconds < 5)
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
   Print("PFLS TRADER ENGINE v1.72");
   Print("Symbol: ", _Symbol);
   Print("Timeframes: 8");
   Print("Execution enabled: ", PFLS_EnableExecution);
   Print("======================================");

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
}

// =====================================================
// SHUTDOWN
// =====================================================

void OnDeinit(const int reason)
{
   EventKillTimer();

   Print(
      "PFLS ENGINE v1.72 stopped. Reason: ",
      reason
   );
}
