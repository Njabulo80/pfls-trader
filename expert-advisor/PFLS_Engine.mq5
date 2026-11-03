
#property strict
#property version "1.60"
#property description "PFLS Trader - Coordinated Multi-Timeframe Zone and Execution Engine"

#include "PFLS_Zones.mqh"
#include "PFLS_Execution.mqh"

// =====================================================
// PFLS TRADER
// PRICE FLOW LADDER SEQUENCE
// ENGINE VERSION 1.60
// =====================================================

// -----------------------------------------------------
// ENGINE SETTINGS
// -----------------------------------------------------

input int LookbackBars = 250;
input int PivotStrength = 2;
input int ScanIntervalSeconds = 30;

// -----------------------------------------------------
// TIMEFRAMES
// -----------------------------------------------------

ENUM_TIMEFRAMES Timeframes[8] =
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

string TimeframeNames[8] =
{
   "W1", "D1", "H4", "H1",
   "M30", "M15", "M5", "M1"
};

// -----------------------------------------------------
// SHARED ZONE SNAPSHOTS
// -----------------------------------------------------

PFLSZoneRecord PFLS_DemandZones[8];
PFLSZoneRecord PFLS_SupplyZones[8];

bool PFLS_ZonesReady = false;

// =====================================================
// ZONE STATE LABEL
// =====================================================

string PFLS_GetZoneStateName(
   ENUM_PFLS_ZONE_STATE state
)
{
   switch(state)
   {
      case PFLS_ZONE_APPROACHING:
         return "APPROACHING";

      case PFLS_ZONE_INSIDE:
         return "INSIDE";

      case PFLS_ZONE_DEPARTED:
         return "DEPARTED";

      case PFLS_ZONE_UNTESTED:
         return "UNTESTED";
   }

   return "UNKNOWN";
}

// =====================================================
// PRINT ZONE
// =====================================================

void PrintZone(
   string label,
   PFLSZoneRecord &zone,
   int digits
)
{
   if(!zone.valid)
   {
      Print(label, ": unavailable");
      return;
   }

   Print(
      label, ": ",
      DoubleToString(zone.lower, digits),
      " - ",
      DoubleToString(zone.upper, digits),
      " | State: ",
      PFLS_GetZoneStateName(zone.zoneState),
      " | Touches: ",
      zone.touches,
      " | Freshness: ",
      DoubleToString(
         PFLSZ_FreshnessScore(zone), 1
      ),
      " | Distance: ",
      DoubleToString(zone.distancePoints, 1),
      " points"
   );
}

// =====================================================
// MULTI-TIMEFRAME CONFLUENCE
// =====================================================

void ScanConfluence(
   PFLSZoneRecord &zones[],
   string zoneType,
   int digits
)
{
   Print("---------- ", zoneType, " MTZC ----------");

   bool foundConfluence = false;

   for(int i = 0; i < 8; i++)
   {
      if(!zones[i].valid)
         continue;

      for(int j = i + 1; j < 8; j++)
      {
         if(!zones[j].valid)
            continue;

         if(PFLSZ_ZonesOverlap(zones[i], zones[j]))
         {
            foundConfluence = true;

            Print(
               "Overlap: ",
               TimeframeNames[i],
               " + ",
               TimeframeNames[j],
               " | Range: ",
               DoubleToString(
                  MathMax(
                     zones[i].lower,
                     zones[j].lower
                  ),
                  digits
               ),
               " - ",
               DoubleToString(
                  MathMin(
                     zones[i].upper,
                     zones[j].upper
                  ),
                  digits
               )
            );
         }
      }
   }

   if(!foundConfluence)
      Print("No overlapping zones detected.");
}

// =====================================================
// FIND NEAREST OPPOSING TARGET
// =====================================================

bool PFLS_FindNearestTarget(
   bool isBuy,
   double price,
   PFLSZoneRecord &demandZones[],
   PFLSZoneRecord &supplyZones[],
   PFLSZoneRecord &target
)
{
   PFLSZ_Reset(target);

   if(price <= 0.0)
      return false;

   double bestDistance = 1.0e100;

   for(int i = 0; i < 8; i++)
   {
      PFLSZoneRecord candidate;

      if(isBuy)
      {
         candidate = supplyZones[i];

         if(!candidate.valid ||
            candidate.invalidated ||
            candidate.isDemand)
            continue;

         // Target must be above current price.
         if(candidate.lower <= price)
            continue;

         double distance =
            candidate.lower - price;

         if(distance < bestDistance)
         {
            bestDistance = distance;
            target = candidate;
         }
      }
      else
      {
         candidate = demandZones[i];

         if(!candidate.valid ||
            candidate.invalidated ||
            !candidate.isDemand)
            continue;

         // Target must be below current price.
         if(candidate.upper >= price)
            continue;

         double distance =
            price - candidate.upper;

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
// PROCESS CONFIRMED M5 ENTRY
// =====================================================

void PFLS_ProcessEntry()
{
   if(!PFLS_ZonesReady)
      return;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   if(tick.bid <= 0.0 ||
      tick.ask <= 0.0)
      return;

   double currentPrice =
      (tick.bid + tick.ask) / 2.0;

   bool isBuy = false;

   datetime signalBarTime = 0;

   PFLSZoneRecord entryZone;

   // --------------------------------------------------
   // GET CONFIRMED M5 SIGNAL
   // --------------------------------------------------

   if(!PFLS_ExecutionGetM5Signal(
      PFLS_DemandZones[6],
      PFLS_SupplyZones[6],
      isBuy,
      signalBarTime,
      entryZone
   ))
   {
      return;
   }

   if(signalBarTime <= 0)
      return;

   // --------------------------------------------------
   // VALIDATE PRESERVED ENTRY ZONE
   // --------------------------------------------------

   if(!entryZone.valid ||
      entryZone.invalidated)
   {
      Print(
         "PFLS: Preserved entry zone is invalid. "
         "Signal will be consumed."
      );

      PFLS_ExecutionConsumeSignal(signalBarTime);

      return;
   }

   // --------------------------------------------------
   // FIND OPPOSING TARGET
   // --------------------------------------------------

   PFLSZoneRecord targetZone;

   if(!PFLS_FindNearestTarget(
      isBuy,
      currentPrice,
      PFLS_DemandZones,
      PFLS_SupplyZones,
      targetZone
   ))
   {
      // Keep the pending signal alive.
      // It can be checked again on the next tick,
      // until the next-candle breakout window expires.

      return;
   }

   // --------------------------------------------------
   // SIGNAL INFORMATION
   // --------------------------------------------------

   Print(
      "================================"
   );

   Print(
      "PFLS: M5 ",
      isBuy ? "BUY" : "SELL",
      " breakout confirmed."
   );

   Print(
      "PFLS: Rejection candle: ",
      TimeToString(
         signalBarTime,
         TIME_DATE | TIME_MINUTES
      )
   );

   Print(
      "PFLS: Entry zone: ",
      DoubleToString(entryZone.lower, _Digits),
      " - ",
      DoubleToString(entryZone.upper, _Digits)
   );

   Print(
      "PFLS: Target zone: ",
      DoubleToString(targetZone.lower, _Digits),
      " - ",
      DoubleToString(targetZone.upper, _Digits)
   );

   // --------------------------------------------------
   // EXECUTION DECISION
   // --------------------------------------------------

   if(!PFLS_EnableExecution)
   {
      Print(
         "PFLS: Execution disabled. "
         "Signal recorded; no order submitted."
      );
   }
   else
   {
      Print(
         "PFLS: Passing signal to execution module."
      );

      bool tradeAccepted =
         PFLS_ExecutionTryTrade(
            isBuy,
            entryZone,
            targetZone,
            signalBarTime
         );

      if(tradeAccepted)
      {
         Print(
            "PFLS: Execution module accepted "
            "the trade request."
         );
      }
      else
      {
         Print(
            "PFLS: No accepted trade request. "
            "Signal will not be retried."
         );
      }
   }

   // --------------------------------------------------
   // CONSUME AFTER ONE EXECUTION DECISION
   // --------------------------------------------------

   PFLS_ExecutionConsumeSignal(signalBarTime);

   Print(
      "PFLS: Signal processing completed."
   );

   Print(
      "================================"
   );
}

// =====================================================
// MARKET SCANNER
// Timer-based zone refresh
// =====================================================

void ScanMarket()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
   {
      PFLS_ZonesReady = false;

      Print("PFLS: Waiting for price data.");

      return;
   }

   if(tick.bid <= 0.0 ||
      tick.ask <= 0.0)
   {
      PFLS_ZonesReady = false;

      Print("PFLS: Invalid market prices.");

      return;
   }

   double price =
      (tick.bid + tick.ask) / 2.0;

   int detectedTimeframes = 0;

   PFLS_ZonesReady = false;

   Print("========== PFLS SCAN ==========");

   Print("Symbol: ", _Symbol);

   Print(
      "Price: ",
      DoubleToString(price, _Digits)
   );

   // --------------------------------------------------
   // SCAN ALL EIGHT TIMEFRAMES
   // --------------------------------------------------

   for(int i = 0; i < 8; i++)
   {
      PFLSZ_Reset(PFLS_DemandZones[i]);

      PFLSZ_Reset(PFLS_SupplyZones[i]);

      bool detected = PFLSZ_DetectNearestZones(
         _Symbol,
         Timeframes[i],
         LookbackBars,
         PivotStrength,
         price,
         PFLS_DemandZones[i],
         PFLS_SupplyZones[i]
      );

      if(detected)
         detectedTimeframes++;

      Print(
         "---------- ",
         TimeframeNames[i],
         " ----------"
      );

      if(!detected)
      {
         Print(
            "No valid zones detected on ",
            TimeframeNames[i]
         );
      }

      PrintZone(
         "Demand",
         PFLS_DemandZones[i],
         _Digits
      );

      PrintZone(
         "Supply",
         PFLS_SupplyZones[i],
         _Digits
      );
   }

   // --------------------------------------------------
   // DATA READINESS
   // --------------------------------------------------

   PFLS_ZonesReady =
      detectedTimeframes > 0;

   if(!PFLS_ZonesReady)
   {
      Print(
         "PFLS: No valid zones detected. "
         "Waiting for more market data."
      );

      Print("========== SCAN COMPLETE ==========");

      return;
   }

   // --------------------------------------------------
   // MULTI-TIMEFRAME CONFLUENCE
   // --------------------------------------------------

   ScanConfluence(
      PFLS_DemandZones,
      "DEMAND",
      _Digits
   );

   ScanConfluence(
      PFLS_SupplyZones,
      "SUPPLY",
      _Digits
   );

   Print(
      "PFLS: Valid zone timeframes: ",
      detectedTimeframes,
      " / 8"
   );

   Print("========== SCAN COMPLETE ==========");
}

// =====================================================
// INITIALIZATION
// =====================================================

int OnInit()
{
   if(LookbackBars < 30 ||
      PivotStrength < 1 ||
      ScanIntervalSeconds < 5)
   {
      Print("PFLS: Invalid scanner settings.");

      return INIT_PARAMETERS_INCORRECT;
   }

   for(int i = 0; i < 8; i++)
   {
      PFLSZ_Reset(PFLS_DemandZones[i]);

      PFLSZ_Reset(PFLS_SupplyZones[i]);
   }

   PFLS_ZonesReady = false;

   if(!EventSetTimer(ScanIntervalSeconds))
   {
      Print(
         "PFLS: Unable to start scan timer. Error: ",
         GetLastError()
      );

      return INIT_FAILED;
   }

   Print("================================");

   Print("PFLS ENGINE v1.60 INITIALIZED");

   Print("Instrument: ", _Symbol);

   Print("Timeframes: 8");

   Print("Zone detection: ENABLED");

   Print("Timer scanning: ENABLED");

   Print("Tick-based M5 monitoring: ENABLED");

   Print("Execution module: CONNECTED");

   Print(
      "Execution enabled: ",
      PFLS_EnableExecution ? "YES" : "NO"
   );

   Print(
      "Emergency stop: ",
      PFLS_EmergencyStop ? "ACTIVE" : "INACTIVE"
   );

   Print("================================");

   // Initial scan.
   ScanMarket();

   return INIT_SUCCEEDED;
}

// =====================================================
// TIMER EVENT
// =====================================================

void OnTimer()
{
   ScanMarket();
}

// =====================================================
// TICK EVENT
// =====================================================

void OnTick()
{
   if(!PFLS_ZonesReady)
      return;

   PFLS_ProcessEntry();
}

// =====================================================
// SHUTDOWN
// =====================================================

void OnDeinit(const int reason)
{
   EventKillTimer();

   Print(
      "PFLS Engine stopped. Reason: ",
      reason
   );
}

// =====================================================
// END OF PFLS ENGINE
// VERSION 1.60
// =====================================================
