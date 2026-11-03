
#property strict
#property version "1.40"
#property description "PFLS Trader - Multi-Timeframe Zone and Execution Engine"

// =====================================================
// PFLS TRADER
// PRICE FLOW LADDER SEQUENCE
// MAIN ENGINE
// Version 1.40
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
      DoubleToString(
         PFLSZ_FreshnessScore(zone),
         1
      ),
      " | Distance: ",
      DoubleToString(
         zone.distancePoints,
         1
      ),
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

         if(PFLSZ_ZonesOverlap(
            zones[i],
            zones[j]
         ))
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

   double bestDistance = DBL_MAX;

   for(int i = 0; i < 8; i++)
   {
      PFLSZoneRecord candidate;

      // ---------------------------------------------
      // BUY: Find nearest valid supply zone above
      // ---------------------------------------------

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

      // ---------------------------------------------
      // SELL: Find nearest valid demand zone below
      // ---------------------------------------------

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
   // M5 is index 6 in our timeframe list.

   PFLSZoneRecord m5Demand =
      demandZones[6];

   PFLSZoneRecord m5Supply =
      supplyZones[6];

   bool isBuy = false;

   datetime signalBarTime = 0;

   // ---------------------------------------------
   // Get completed M5 candle confirmation
   // ---------------------------------------------

   if(!PFLS_ExecutionGetM5Signal(
      m5Demand,
      m5Supply,
      isBuy,
      signalBarTime
   ))
   {
      return;
   }

   // ---------------------------------------------
   // Identify entry zone
   // ---------------------------------------------

   PFLSZoneRecord entryZone;

   if(isBuy)
      entryZone = m5Demand;
   else
      entryZone = m5Supply;

   if(!entryZone.valid ||
      entryZone.invalidated)
   {
      Print(
         "PFLS: Signal rejected. Entry zone invalid."
      );

      return;
   }

   // ---------------------------------------------
   // Find mandatory opposing target
   // ---------------------------------------------

   PFLSZoneRecord targetZone;

   if(!PFLS_FindNearestTarget(
      isBuy,
      currentPrice,
      demandZones,
      supplyZones,
      targetZone
   ))
   {
      Print(
         "PFLS: Signal found, but no valid opposing target."
      );

      return;
   }

   // ---------------------------------------------
   // Report signal
   // ---------------------------------------------

   Print(
      "PFLS: M5 ",
      isBuy ? "BUY" : "SELL",
      " confirmation detected."
   );

   Print(
      "PFLS: Signal candle: ",
      TimeToString(
         signalBarTime,
         TIME_DATE | TIME_MINUTES
      )
   );

   Print(
      "PFLS: Entry zone: ",
      DoubleToString(
         entryZone.lower,
         _Digits
      ),
      " - ",
      DoubleToString(
         entryZone.upper,
         _Digits
      )
   );

   Print(
      "PFLS: Target zone: ",
      DoubleToString(
         targetZone.lower,
         _Digits
      ),
      " - ",
      DoubleToString(
         targetZone.upper,
         _Digits
      )
   );

   Print(
      "PFLS: Passing signal to execution safety checks."
   );

   // ---------------------------------------------
   // Execution module controls whether an order
   // can actually be submitted.
   // Execution remains disabled by default.
   // ---------------------------------------------

   PFLS_ExecutionTryTrade(
      isBuy,
      entryZone,
      targetZone,
      signalBarTime
   );
}

// =====================================================
// MAIN MARKET SCANNER
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

   PFLSZoneRecord demandZones[8];

   PFLSZoneRecord supplyZones[8];

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

   // ---------------------------------------------
   // Scan all eight timeframes
   // ---------------------------------------------

   for(int i = 0; i < 8; i++)
   {
      PFLSZ_Reset(demandZones[i]);

      PFLSZ_Reset(supplyZones[i]);

      // IMPORTANT:
      // The argument order matches PFLS_Zones.mqh v1.20:
      // symbol, timeframe, lookback, strength, price,
      // nearestDemand, nearestSupply.

      bool detected =
         PFLSZ_DetectNearestZones(
            _Symbol,
            Timeframes[i],
            LookbackBars,
            PivotStrength,
            price,
            demandZones[i],
            supplyZones[i]
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
         demandZones[i],
         _Digits
      );

      PrintZone(
         "Supply",
         supplyZones[i],
         _Digits
      );
   }

   // ---------------------------------------------
   // Multi-timeframe confluence
   // ---------------------------------------------

   ScanConfluence(
      demandZones,
      "DEMAND",
      _Digits
   );

   ScanConfluence(
      supplyZones,
      "SUPPLY",
      _Digits
   );

   // ---------------------------------------------
   // M5 entry processing
   // ---------------------------------------------

   PFLS_ProcessEntry(
      demandZones,
      supplyZones,
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

   EventSetTimer(
      ScanIntervalSeconds
   );

   Print(
      "================================"
   );

   Print(
      "PFLS ENGINE v1.40 INITIALIZED"
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
      "M5 confirmation: ENABLED"
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
// =====================================================

void OnTimer()
{
   ScanMarket();
}

// =====================================================
// SHUTDOWN
// =====================================================

void OnDeinit(
   const int reason
)
{
   EventKillTimer();

   Print(
      "PFLS Engine stopped."
   );
}

// =====================================================
// END OF PFLS ENGINE v1.40
// =====================================================
