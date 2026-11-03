
#property strict
#property version "1.50"
#property description "PFLS Trader - Multi-Timeframe Zone and Tick-Based Execution Engine"

// =====================================================
// PFLS TRADER
// PRICE FLOW LADDER SEQUENCE
// MAIN ENGINE
// Version 1.50
// =====================================================

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
   "W1",
   "D1",
   "H4",
   "H1",
   "M30",
   "M15",
   "M5",
   "M1"
};

// =====================================================
// CACHED MULTI-TIMEFRAME ZONES
// Updated by the timer scanner.
// Read by both timer and tick processing.
// =====================================================

PFLSZoneRecord PFLS_CachedDemandZones[8];
PFLSZoneRecord PFLS_CachedSupplyZones[8];

datetime PFLS_LastNoTargetNoticeBar = 0;

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
// PRINT ZONE INFORMATION
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
      label,
      ": ",
      DoubleToString(zone.lower, digits),
      " - ",
      DoubleToString(zone.upper, digits),
      " | State: ",
      PFLS_GetZoneStateName(zone.zoneState),
      " | Touches: ",
      zone.touches,
      " | Freshness: ",
      DoubleToString(PFLSZ_FreshnessScore(zone), 1),
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
   Print(
      "---------- ",
      zoneType,
      " MTZC ----------"
   );

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

   double bestDistance = 1.0e100;

   for(int i = 0; i < 8; i++)
   {
      PFLSZoneRecord candidate;

      // BUY: nearest supply above price.

      if(isBuy)
      {
         candidate = supplyZones[i];

         if(!candidate.valid ||
            candidate.invalidated ||
            candidate.isDemand)
         {
            continue;
         }

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

      // SELL: nearest demand below price.

      else
      {
         candidate = demandZones[i];

         if(!candidate.valid ||
            candidate.invalidated ||
            !candidate.isDemand)
         {
            continue;
         }

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
// PROCESS M5 ENTRY SIGNAL
// =====================================================

void PFLS_ProcessEntry(
   PFLSZoneRecord &demandZones[],
   PFLSZoneRecord &supplyZones[],
   double currentPrice
)
{
   // M5 is index 6.

   PFLSZoneRecord m5Demand = demandZones[6];
   PFLSZoneRecord m5Supply = supplyZones[6];

   bool isBuy = false;

   datetime signalBarTime = 0;

   PFLSZoneRecord entryZone;

   PFLSZ_Reset(entryZone);

   // --------------------------------------------------
   // GET M5 SIGNAL
   // The execution module preserves the original
   // rejection zone and monitors breakout ticks.
   // --------------------------------------------------

   if(!PFLS_ExecutionGetM5Signal(
      m5Demand,
      m5Supply,
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
         "PFLS: Signal rejected. Preserved entry zone invalid."
      );

      PFLS_ExecutionCompleteSignal(signalBarTime);

      return;
   }

   // --------------------------------------------------
   // FIND OPPOSING TARGET
   // --------------------------------------------------

   PFLSZoneRecord targetZone;

   PFLSZ_Reset(targetZone);

   if(!PFLS_FindNearestTarget(
      isBuy,
      currentPrice,
      demandZones,
      supplyZones,
      targetZone
   ))
   {
      if(PFLS_LastNoTargetNoticeBar != signalBarTime)
      {
         Print(
            "PFLS: Breakout detected, but no valid opposing target."
         );

         Print(
            "PFLS: Signal remains pending for target validation."
         );

         PFLS_LastNoTargetNoticeBar = signalBarTime;
      }

      // IMPORTANT:
      // Do not consume the signal.
      // The next tick can check for a valid target again.

      return;
   }

   // --------------------------------------------------
   // REPORT VALIDATED SIGNAL
   // --------------------------------------------------

   Print(
      "================================"
   );

   Print(
      "PFLS: M5 ",
      isBuy ? "BUY" : "SELL",
      " BREAKOUT VALIDATED"
   );

   Print(
      "Signal candle: ",
      TimeToString(
         signalBarTime,
         TIME_DATE | TIME_MINUTES
      )
   );

   Print(
      "Preserved entry zone: ",
      DoubleToString(entryZone.lower, _Digits),
      " - ",
      DoubleToString(entryZone.upper, _Digits)
   );

   Print(
      "Opposing target zone: ",
      DoubleToString(targetZone.lower, _Digits),
      " - ",
      DoubleToString(targetZone.upper, _Digits)
   );

   // --------------------------------------------------
   // EXECUTION SAFETY CHECKS
   // --------------------------------------------------

   PFLS_ExecutionTryTrade(
      isBuy,
      entryZone,
      targetZone,
      signalBarTime
   );

   // --------------------------------------------------
   // COMPLETE SIGNAL
   // Target was validated.
   // The signal must not be processed repeatedly.
   // --------------------------------------------------

   PFLS_ExecutionCompleteSignal(signalBarTime);

   PFLS_LastNoTargetNoticeBar = 0;

   Print(
      "PFLS: Signal processing finished."
   );

   Print(
      "================================"
   );
}

// =====================================================
// MAIN MARKET SCANNER
// Runs on the configured timer interval.
// =====================================================

void ScanMarket()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print(
         "PFLS: Waiting for price data."
      );

      return;
   }

   if(tick.bid <= 0.0 ||
      tick.ask <= 0.0)
   {
      Print(
         "PFLS: Invalid market prices."
      );

      return;
   }

   double price =
      (tick.bid + tick.ask) / 2.0;

   Print(
      "========== PFLS SCAN =========="
   );

   Print(
      "Symbol: ",
      _Symbol
   );

   Print(
      "Price: ",
      DoubleToString(price, _Digits)
   );

   // --------------------------------------------------
   // SCAN ALL EIGHT TIMEFRAMES
   // --------------------------------------------------

   for(int i = 0; i < 8; i++)
   {
      PFLSZ_Reset(PFLS_CachedDemandZones[i]);

      PFLSZ_Reset(PFLS_CachedSupplyZones[i]);

      bool detected = PFLSZ_DetectNearestZones(
         _Symbol,
         Timeframes[i],
         LookbackBars,
         PivotStrength,
         price,
         PFLS_CachedDemandZones[i],
         PFLS_CachedSupplyZones[i]
      );

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
         PFLS_CachedDemandZones[i],
         _Digits
      );

      PrintZone(
         "Supply",
         PFLS_CachedSupplyZones[i],
         _Digits
      );
   }

   // --------------------------------------------------
   // MULTI-TIMEFRAME CONFLUENCE
   // --------------------------------------------------

   ScanConfluence(
      PFLS_CachedDemandZones,
      "DEMAND",
      _Digits
   );

   ScanConfluence(
      PFLS_CachedSupplyZones,
      "SUPPLY",
      _Digits
   );

   // --------------------------------------------------
   // PROCESS SIGNAL USING REFRESHED ZONES
   // --------------------------------------------------

   PFLS_ProcessEntry(
      PFLS_CachedDemandZones,
      PFLS_CachedSupplyZones,
      price
   );

   Print(
      "========== SCAN COMPLETE =========="
   );
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
      Print(
         "PFLS: Invalid scanner settings."
      );

      return INIT_PARAMETERS_INCORRECT;
   }

   // Reset cached zones.

   for(int i = 0; i < 8; i++)
   {
      PFLSZ_Reset(PFLS_CachedDemandZones[i]);

      PFLSZ_Reset(PFLS_CachedSupplyZones[i]);
   }

   PFLS_ExecutionResetPending();

   // Start timer.

   if(!EventSetTimer(ScanIntervalSeconds))
   {
      Print(
         "PFLS: Failed to initialize market scanner timer."
      );

      return INIT_FAILED;
   }

   Print(
      "================================"
   );

   Print(
      "PFLS ENGINE v1.50 INITIALIZED"
   );

   Print(
      "Instrument: ",
      _Symbol
   );

   Print(
      "Timeframes: 8"
   );

   Print(
      "Zone detection: ENABLED"
   );

   Print(
      "Zone state tracking: ENABLED"
   );

   Print(
      "M5 rejection detection: ENABLED"
   );

   Print(
      "Tick-based breakout monitoring: ENABLED"
   );

   Print(
      "Preserved entry zones: ENABLED"
   );

   Print(
      "Target validation: ENABLED"
   );

   Print(
      "Execution module: CONNECTED"
   );

   Print(
      "Execution enabled: ",
      PFLS_EnableExecution ? "YES" : "NO"
   );

   Print(
      "Emergency stop: ",
      PFLS_EmergencyStop ? "ACTIVE" : "INACTIVE"
   );

   Print(
      "================================"
   );

   return INIT_SUCCEEDED;
}

// =====================================================
// TIMER EVENT
// Refreshes the eight-timeframe market structure.
// =====================================================

void OnTimer()
{
   ScanMarket();
}

// =====================================================
// TICK EVENT
// Monitors M5 breakout conditions on incoming ticks.
// =====================================================

void OnTick()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   if(tick.bid <= 0.0 ||
      tick.ask <= 0.0)
   {
      return;
   }

   double currentPrice =
      (tick.bid + tick.ask) / 2.0;

   PFLS_ProcessEntry(
      PFLS_CachedDemandZones,
      PFLS_CachedSupplyZones,
      currentPrice
   );
}

// =====================================================
// SHUTDOWN
// =====================================================

void OnDeinit(const int reason)
{
   EventKillTimer();

   Print(
      "PFLS Engine v1.50 stopped."
   );
}

// =====================================================
// END OF PFLS ENGINE v1.50
// =====================================================
