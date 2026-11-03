
#property strict
#property version "1.71"
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
#define PFLS_M5_INDEX 6

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
      PFLSZoneRecord demand;
      PFLSZoneRecord supply;

      PFLSZ_Reset(demand);
      PFLSZ_Reset(supply);

      bool detected = PFLSZ_DetectNearestZones(
         _Symbol,
         PFLS_Timeframes[i],
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
      "PFLS v1.71 SCAN | Symbol: ",
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

         if(candidate.isDemand)
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

         if(!candidate.isDemand)
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

   // No zones and no pending setup:
   // Nothing to process.
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

   // IMPORTANT:
   // Execution v1.60 requires exactly five arguments:
   // demand, supply, isBuy, signalBarTime, entryZone.
   //
   // Existing pending setups can still be monitored
   // when a market scan temporarily finds no zones.

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
      "PFLS BREAKOUT CONFIRMED | Direction: ",
      isBuy ? "BUY" : "SELL",
      " | Signal time: ",
      TimeToString(signalTime)
   );

   // --------------------------------------------------
   // VALIDATE ENTRY ZONE
   // --------------------------------------------------

   if(!entryZone.valid || entryZone.invalidated)
   {
      Print("PFLS: Invalid entry zone. Signal discarded.");

      PFLS_ExecutionConsumeSignal(signalTime);

      return;
   }

   // --------------------------------------------------
   // WAIT FOR TARGET ZONES
   // --------------------------------------------------

   if(!PFLS_ZonesReady)
   {
      Print(
         "PFLS: Breakout confirmed, but target zones "
         "are unavailable. Keeping setup pending."
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
         "Keeping setup pending."
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

   // --------------------------------------------------
   // SIGNAL-ONLY MODE
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
   // TRADE EXECUTION
   // --------------------------------------------------

   // IMPORTANT:
   // Execution v1.60 requires exactly four arguments:
   // isBuy, entryZone, targetZone, signalBarTime.

   bool tradeDecision = PFLS_ExecutionTryTrade(
      isBuy,
      entryZone,
      targetZone,
      signalTime
   );

   if(tradeDecision)
   {
      Print(
         "PFLS: Trade request accepted by execution module."
      );
   }
   else
   {
      Print(
         "PFLS: Execution conditions were not satisfied."
      );
   }

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
      Print("PFLS ERROR: Scan interval must be at least 5.");
      return INIT_PARAMETERS_INCORRECT;
   }

   PFLS_ResetEngineZones();

   if(!EventSetTimer(ScanIntervalSeconds))
   {
      Print("PFLS ERROR: Unable to start scan timer.");
      return INIT_FAILED;
   }

   Print("======================================");
   Print("PFLS TRADER ENGINE v1.71");
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
      "PFLS ENGINE v1.71 stopped. Reason: ",
      reason
   );
}
