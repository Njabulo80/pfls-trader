
#property strict
#property version "1.10"
#property description "PFLS Trader - Multi-Timeframe Zone Scanner"
#property description "Read-only development build. No orders."

#include "PFLS_Zones.mqh"

// ============================================
// PFLS ENGINE SETTINGS
// ============================================

input int LookbackBars = 250;
input int PivotStrength = 2;
input int ScanIntervalSeconds = 30;

// ============================================
// TIMEFRAME CONFIGURATION
// ============================================

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

// ============================================
// PRINT ZONE INFORMATION
// ============================================

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
      " | Touches: ",
      zone.touches,
      " | Freshness score: ",
      DoubleToString(PFLSZ_FreshnessScore(zone), 1),
      " | Formed: ",
      TimeToString(zone.formedAt, TIME_DATE | TIME_MINUTES)
   );
}

// ============================================
// MULTI-TIMEFRAME CONFLUENCE
// ============================================

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
               "Overlap detected: ",
               TimeframeNames[i],
               " + ",
               TimeframeNames[j],
               " | Range: ",
               DoubleToString(
                  MathMax(zones[i].lower, zones[j].lower),
                  digits
               ),
               " - ",
               DoubleToString(
                  MathMin(zones[i].upper, zones[j].upper),
                  digits
               )
            );
         }
      }
   }

   if(!foundConfluence)
      Print("No overlapping zones detected.");
}

// ============================================
// MAIN MARKET SCANNER
// ============================================

void ScanMarket()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("PFLS: Waiting for price data.");
      return;
   }

   double price = (tick.bid + tick.ask) / 2.0;

   PFLSZoneRecord demandZones[8];
   PFLSZoneRecord supplyZones[8];

   Print("========== PFLS SCAN ==========");
   Print("Symbol: ", _Symbol);
   Print("Price: ", DoubleToString(price, _Digits));
   Print("Mode: READ ONLY");

   for(int i = 0; i < 8; i++)
   {
      PFLSZ_DetectNearestZones(
         _Symbol,
         Timeframes[i],
         price,
         LookbackBars,
         PivotStrength,
         demandZones[i],
         supplyZones[i]
      );

      Print("---------- ", TimeframeNames[i], " ----------");

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

   // Compare zones across timeframes.
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

   Print("========== SCAN COMPLETE ==========");
}

// ============================================
// EXPERT ADVISOR INITIALIZATION
// ============================================

int OnInit()
{
   if(LookbackBars < 30 ||
      PivotStrength < 1 ||
      ScanIntervalSeconds < 5)
   {
      Print("PFLS: Invalid scanner settings.");
      return INIT_PARAMETERS_INCORRECT;
   }

   EventSetTimer(ScanIntervalSeconds);

   Print("================================");
   Print("PFLS ENGINE v1.10 INITIALIZED");
   Print("Instrument: ", _Symbol);
   Print("Timeframes: 8");
   Print("Mode: READ ONLY - NO TRADES");
   Print("================================");

   return INIT_SUCCEEDED;
}

// ============================================
// TIMER EVENT
// ============================================

void OnTimer()
{
   ScanMarket();
}

// ============================================
// SHUTDOWN
// ============================================

void OnDeinit(const int reason)
{
   EventKillTimer();

   Print("PFLS Engine stopped.");
}
