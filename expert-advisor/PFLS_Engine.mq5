
#property strict
#property version "1.70"
#property description "PFLS Trader - Multi-Timeframe Zone and Tick Execution Engine"

#include "PFLS_Zones.mqh"
#include "PFLS_Execution.mqh"

// =====================================================
// ENGINE SETTINGS
// =====================================================

input int LookbackBars = 250;
input int PivotStrength = 2;
input int ScanIntervalSeconds = 30;

// =====================================================
// TIMEFRAME CONFIGURATION
// =====================================================

#define PFLS_TIMEFRAME_COUNT 8

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

// M5 is index 6.
#define PFLS_M5_INDEX 6

// =====================================================
// ZONE STORAGE
// =====================================================

PFLSZoneRecord PFLS_DemandZones[PFLS_TIMEFRAME_COUNT];
PFLSZoneRecord PFLS_SupplyZones[PFLS_TIMEFRAME_COUNT];

bool PFLS_ZonesReady = false;
datetime PFLS_LastScanTime = 0;

// =====================================================
// RESET ENGINE ZONES
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

   int detectedTimeframes = 0;

   for(int i = 0; i < PFLS_TIMEFRAME_COUNT; i++)
   {
      ENUM_TIMEFRAMES timeframe = PFLS_Timeframes[i];

      PFLSZoneRecord demand;
      PFLSZoneRecord supply;

      PFLSZ_Reset(demand);
      PFLSZ_Reset(supply);

      bool detected = PFLSZ_DetectNearestZones(
         _Symbol,
         timeframe,
         LookbackBars,
         PivotStrength,
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
      "PFLS v1.70 SCAN | Symbol: ",
      _Symbol,
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

         if(!candidate.valid || candidate.invalidated)
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

         if(!candidate.valid || candidate.invalidated)
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
// PROCESS ENTRY SIGNAL
// =====================================================

void PFLS_ProcessEntry()
{
   bool hasPending = PFLS_ExecutionHasPendingSignal();

   // Without zones, only continue if an earlier setup
   // is already waiting for its breakout.
   if(!PFLS_ZonesReady && !hasPending)
      return;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   if(tick.bid <= 0 || tick.ask <= 0)
      return;

   bool signalFound = false;
   bool isBuy = false;

   PFLSZoneRecord entryZone;
   datetime signalTime = 0;

   PFLSZ_Reset(entryZone);

   // This call also monitors existing pending setups
   // when the latest market scan has no valid zones.
   signalFound = PFLS_ExecutionGetM5Signal(
      PFLS_DemandZones[PFLS_M5_INDEX],
      PFLS_SupplyZones[PFLS_M5_INDEX],
      signalFound,
      isBuy,
      entryZone,
      signalTime
   );

   if(!signalFound)
      return;

   Print(
      "PFLS v1.70 BREAKOUT CONFIRMED | Direction: ",
      isBuy ? "BUY" : "SELL",
      " | Signal time: ",
      TimeToString(signalTime)
   );

   // Reject malformed or invalid entry zones.
   if(!entryZone.valid || entryZone.invalidated)
   {
      Print("PFLS: Invalid entry zone. Signal discarded.");

      PFLS_ExecutionConsumeSignal(signalTime);
      return;
   }

   // Keep a confirmed signal pending if the market scan
   // has not yet supplied target-zone information.
   // It can be checked again on subsequent ticks.
   if(!PFLS_ZonesReady)
   {
      Print(
         "PFLS: Breakout confirmed, but target zones are "
         "temporarily unavailable. Keeping setup pending."
      );

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
      Print(
         "PFLS: No opposing target zone found. "
         "Keeping setup pending for another check."
      );

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

   // Execution remains controlled by the execution module.
   if(!PFLS_EnableExecution)
   {
      Print(
         "PFLS SIGNAL ONLY | ",
         isBuy ? "BUY" : "SELL",
         " | Execution currently disabled."
      );

      PFLS_ExecutionConsumeSignal(signalTime);
      return;
   }

   bool tradeDecision = PFLS_ExecutionTryTrade(
      _Symbol,
      isBuy,
      entryZone,
      targetZone,
      signalTime
   );

   if(tradeDecision)
      Print("PFLS: Execution request accepted by trade module.");
   else
      Print("PFLS: Execution conditions were not satisfied.");

   // One execution decision per confirmed signal.
   PFLS_ExecutionConsumeSignal(signalTime);
}

// =====================================================
// EXPERT INITIALIZATION
// =====================================================

int OnInit()
{
   if(LookbackBars < 50)
   {
      Print("PFLS ERROR: LookbackBars must be at least 50.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(PivotStrength < 1)
   {
      Print("PFLS ERROR: PivotStrength must be at least 1.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(ScanIntervalSeconds < 5)
   {
      Print("PFLS ERROR: Scan interval must be at least 5 seconds.");
      return INIT_PARAMETERS_INCORRECT;
   }

   PFLS_ResetEngineZones();

   if(!EventSetTimer(ScanIntervalSeconds))
   {
      Print("PFLS ERROR: Unable to start scan timer.");
      return INIT_FAILED;
   }

   Print("======================================");
   Print("PFLS TRADER ENGINE v1.70");
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
// EXPERT SHUTDOWN
// =====================================================

void OnDeinit(const int reason)
{
   EventKillTimer();

   Print(
      "PFLS ENGINE v1.70 stopped. Reason: ",
      reason
   );
}
