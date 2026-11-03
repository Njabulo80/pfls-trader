
#ifndef PFLS_ZONES_MQH
#define PFLS_ZONES_MQH

// ============================================
// PFLS TRADER - ZONE DETECTION MODULE
// ============================================

struct PFLSZoneRecord
{
   bool valid;
   bool isDemand;

   double lower;
   double upper;

   ENUM_TIMEFRAMES timeframe;
   datetime formedAt;

   int touches;
   bool invalidated;
   double distancePoints;
};

// ============================================
// RESET ZONE RECORD
// ============================================

void PFLSZ_Reset(PFLSZoneRecord &zone)
{
   zone.valid = false;
   zone.isDemand = false;

   zone.lower = 0.0;
   zone.upper = 0.0;

   zone.timeframe = PERIOD_CURRENT;
   zone.formedAt = 0;

   zone.touches = 0;
   zone.invalidated = false;
   zone.distancePoints = 0.0;
}

// ============================================
// CHECK PIVOT LOW
// ============================================

bool PFLSZ_IsPivotLow(
   MqlRates &rates[],
   int index,
   int total,
   int strength
)
{
   if(index < strength || index + strength >= total)
      return false;

   double pivot = rates[index].low;

   for(int k = 1; k <= strength; k++)
   {
      if(rates[index-k].low <= pivot)
         return false;

      if(rates[index+k].low <= pivot)
         return false;
   }

   return true;
}

// ============================================
// CHECK PIVOT HIGH
// ============================================

bool PFLSZ_IsPivotHigh(
   MqlRates &rates[],
   int index,
   int total,
   int strength
)
{
   if(index < strength || index + strength >= total)
      return false;

   double pivot = rates[index].high;

   for(int k = 1; k <= strength; k++)
   {
      if(rates[index-k].high >= pivot)
         return false;

      if(rates[index+k].high >= pivot)
         return false;
   }

   return true;
}

// ============================================
// CHECK ZONE HISTORY
// Count distinct visits and detect invalidation.
// ============================================

void PFLSZ_CheckZoneHistory(
   MqlRates &rates[],
   int pivotIndex,
   PFLSZoneRecord &zone
)
{
   zone.touches = 0;
   zone.invalidated = false;

   bool wasInsideZone = false;

   // Scan from the pivot candle towards the
   // most recent closed candle.
   for(int j = pivotIndex - 1; j >= 0; j--)
   {
      bool overlaps =
         rates[j].high >= zone.lower &&
         rates[j].low <= zone.upper;

      // Demand invalidation:
      // candle closes below the lower boundary.
      if(zone.isDemand && rates[j].close < zone.lower)
      {
         zone.invalidated = true;
         return;
      }

      // Supply invalidation:
      // candle closes above the upper boundary.
      if(!zone.isDemand && rates[j].close > zone.upper)
      {
         zone.invalidated = true;
         return;
      }

      // Count a touch only when price enters
      // after previously being outside.
      if(overlaps && !wasInsideZone)
      {
         zone.touches++;
      }

      wasInsideZone = overlaps;
   }
}

// ============================================
// DETECT NEAREST DEMAND AND SUPPLY ZONES
// ============================================

bool PFLSZ_DetectNearestZones(
   string symbol,
   ENUM_TIMEFRAMES timeframe,
   double currentPrice,
   int lookback,
   int strength,
   PFLSZoneRecord &demand,
   PFLSZoneRecord &supply
)
{
   PFLSZ_Reset(demand);
   PFLSZ_Reset(supply);

   if(lookback < 20 || strength < 1 || currentPrice <= 0.0)
      return false;

   // Get and validate the instrument point size.
   double pointSize = SymbolInfoDouble(
      symbol,
      SYMBOL_POINT
   );

   if(pointSize <= 0.0)
   {
      Print("PFLS: Invalid symbol point size.");
      return false;
   }

   MqlRates rates[];

   ArraySetAsSeries(rates, true);

   int copied = CopyRates(
      symbol,
      timeframe,
      1,
      lookback,
      rates
   );

   if(copied < (strength * 2 + 5))
   {
      Print("PFLS: Insufficient historical price data.");
      return false;
   }

   double nearestDemandDistance = DBL_MAX;
   double nearestSupplyDistance = DBL_MAX;

   // ==========================================
   // SCAN HISTORICAL CANDLES
   // ==========================================

   for(int i = strength; i < copied - strength; i++)
   {
      // ----------------------------------------
      // DEMAND ZONE
      // ----------------------------------------

      if(PFLSZ_IsPivotLow(rates, i, copied, strength))
      {
         PFLSZoneRecord candidate;
         PFLSZ_Reset(candidate);

         candidate.isDemand = true;

         candidate.lower = rates[i].low;

         candidate.upper = MathMax(
            rates[i].open,
            rates[i].close
         );

         candidate.timeframe = timeframe;
         candidate.formedAt = rates[i].time;

         PFLSZ_CheckZoneHistory(
            rates,
            i,
            candidate
         );

         candidate.valid =
            !candidate.invalidated &&
            candidate.upper < currentPrice;

         if(candidate.valid)
         {
            candidate.distancePoints =
               (currentPrice - candidate.upper) / pointSize;

            if(candidate.distancePoints < nearestDemandDistance)
            {
               nearestDemandDistance = candidate.distancePoints;
               demand = candidate;
            }
         }
      }

      // ----------------------------------------
      // SUPPLY ZONE
      // ----------------------------------------

      if(PFLSZ_IsPivotHigh(rates, i, copied, strength))
      {
         PFLSZoneRecord candidate;
         PFLSZ_Reset(candidate);

         candidate.isDemand = false;

         candidate.lower = MathMin(
            rates[i].open,
            rates[i].close
         );

         candidate.upper = rates[i].high;

         candidate.timeframe = timeframe;
         candidate.formedAt = rates[i].time;

         PFLSZ_CheckZoneHistory(
            rates,
            i,
            candidate
         );

         candidate.valid =
            !candidate.invalidated &&
            candidate.lower > currentPrice;

         if(candidate.valid)
         {
            candidate.distancePoints =
               (candidate.lower - currentPrice) / pointSize;

            if(candidate.distancePoints < nearestSupplyDistance)
            {
               nearestSupplyDistance = candidate.distancePoints;
               supply = candidate;
            }
         }
      }
   }

   return demand.valid || supply.valid;
}

// ============================================
// MULTI-TIMEFRAME ZONE OVERLAP
// MTZC BUILDING BLOCK
// ============================================

bool PFLSZ_ZonesOverlap(
   PFLSZoneRecord &first,
   PFLSZoneRecord &second
)
{
   if(!first.valid || !second.valid)
      return false;

   if(first.isDemand != second.isDemand)
      return false;

   return (
      first.lower <= second.upper &&
      second.lower <= first.upper
   );
}

// ============================================
// ZONE FRESHNESS HEURISTIC
// Not a probability of trade success.
// ============================================

double PFLSZ_FreshnessScore(PFLSZoneRecord &zone)
{
   if(!zone.valid || zone.invalidated)
      return 0.0;

   double score = 100.0 - (zone.touches * 15.0);

   if(score < 0.0)
      score = 0.0;

   return score;
}

#endif
