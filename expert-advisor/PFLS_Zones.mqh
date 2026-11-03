
#ifndef PFLS_ZONES_MQH
#define PFLS_ZONES_MQH

// =====================================================
// PFLS TRADER
// PRICE FLOW LADDER SEQUENCE
// ZONE DETECTION MODULE
// Version 1.20
// =====================================================

// -----------------------------------------------------
// ZONE INTERACTION STATES
// -----------------------------------------------------

enum ENUM_PFLS_ZONE_STATE
{
   PFLS_ZONE_APPROACHING,
   PFLS_ZONE_INSIDE,
   PFLS_ZONE_DEPARTED,
   PFLS_ZONE_UNTESTED
};

// -----------------------------------------------------
// ZONE RECORD
// -----------------------------------------------------

struct PFLSZoneRecord
{
   bool valid;
   bool isDemand;

   ENUM_PFLS_ZONE_STATE zoneState;

   double lower;
   double upper;

   ENUM_TIMEFRAMES timeframe;

   datetime formedAt;

   int touches;

   bool invalidated;

   double distancePoints;
};

// -----------------------------------------------------
// RESET ZONE
// -----------------------------------------------------

void PFLSZ_Reset(PFLSZoneRecord &zone)
{
   zone.valid          = false;
   zone.isDemand       = false;
   zone.zoneState      = PFLS_ZONE_UNTESTED;

   zone.lower          = 0.0;
   zone.upper          = 0.0;

   zone.timeframe      = PERIOD_CURRENT;

   zone.formedAt       = 0;

   zone.touches        = 0;

   zone.invalidated    = false;

   zone.distancePoints = 0.0;
}

// -----------------------------------------------------
// CHECK PIVOT LOW
// Uses confirmed closed candles only.
// -----------------------------------------------------

bool PFLSZ_IsPivotLow(
   MqlRates &rates[],
   int index,
   int total,
   int strength
)
{
   if(strength < 1)
      return false;

   if(index < strength)
      return false;

   if(index + strength >= total)
      return false;

   double pivotLow = rates[index].low;

   if(pivotLow <= 0.0)
      return false;

   for(int k = 1; k <= strength; k++)
   {
      if(rates[index-k].low <= pivotLow)
         return false;

      if(rates[index+k].low <= pivotLow)
         return false;
   }

   return true;
}

// -----------------------------------------------------
// CHECK PIVOT HIGH
// -----------------------------------------------------

bool PFLSZ_IsPivotHigh(
   MqlRates &rates[],
   int index,
   int total,
   int strength
)
{
   if(strength < 1)
      return false;

   if(index < strength)
      return false;

   if(index + strength >= total)
      return false;

   double pivotHigh = rates[index].high;

   if(pivotHigh <= 0.0)
      return false;

   for(int k = 1; k <= strength; k++)
   {
      if(rates[index-k].high >= pivotHigh)
         return false;

      if(rates[index+k].high >= pivotHigh)
         return false;
   }

   return true;
}

// -----------------------------------------------------
// CHECK ZONE HISTORY
//
// Counts separate visits to a zone.
// Invalidates demand after a closed candle closes
// below its lower boundary.
// Invalidates supply after a closed candle closes
// above its upper boundary.
//
// rates[] is expected to be a series array:
// index 0 = most recent completed candle.
// -----------------------------------------------------

void PFLSZ_CheckZoneHistory(
   MqlRates &rates[],
   int pivotIndex,
   PFLSZoneRecord &zone
)
{
   zone.touches     = 0;
   zone.invalidated = false;

   int total = ArraySize(rates);

   if(total <= 0)
      return;

   if(pivotIndex <= 0 || pivotIndex >= total)
      return;

   bool wasInside = false;

   // Examine candles newer than the pivot candle.
   for(int i = pivotIndex - 1; i >= 0; i--)
   {
      bool overlaps =
         rates[i].high >= zone.lower &&
         rates[i].low  <= zone.upper;

      // Count a new interaction only when price
      // enters after being outside the zone.
      if(overlaps && !wasInside)
         zone.touches++;

      wasInside = overlaps;

      // Demand invalidation.
      if(zone.isDemand &&
         rates[i].close < zone.lower)
      {
         zone.invalidated = true;
         return;
      }

      // Supply invalidation.
      if(!zone.isDemand &&
         rates[i].close > zone.upper)
      {
         zone.invalidated = true;
         return;
      }
   }
}

// -----------------------------------------------------
// UPDATE ZONE STATE
// -----------------------------------------------------

void PFLSZ_UpdateZoneState(
   PFLSZoneRecord &zone,
   double currentPrice
)
{
   if(!zone.valid ||
      zone.invalidated ||
      currentPrice <= 0.0)
   {
      zone.zoneState = PFLS_ZONE_UNTESTED;
      return;
   }

   // Price is currently inside the zone.
   if(currentPrice >= zone.lower &&
      currentPrice <= zone.upper)
   {
      zone.zoneState = PFLS_ZONE_INSIDE;
      return;
   }

   // Zone has never been visited.
   if(zone.touches <= 0)
   {
      zone.zoneState = PFLS_ZONE_UNTESTED;
      return;
   }

   // Demand zone.
   if(zone.isDemand)
   {
      if(currentPrice < zone.lower)
         zone.zoneState = PFLS_ZONE_APPROACHING;
      else
         zone.zoneState = PFLS_ZONE_DEPARTED;

      return;
   }

   // Supply zone.
   if(!zone.isDemand)
   {
      if(currentPrice > zone.upper)
         zone.zoneState = PFLS_ZONE_APPROACHING;
      else
         zone.zoneState = PFLS_ZONE_DEPARTED;

      return;
   }
}

// -----------------------------------------------------
// DETECT NEAREST VALID DEMAND AND SUPPLY ZONES
//
// CopyRates starts at position 1.
// Therefore the currently forming candle is excluded.
//
// Only confirmed pivots are considered.
// -----------------------------------------------------

bool PFLSZ_DetectNearestZones(
   string symbol,
   ENUM_TIMEFRAMES timeframe,
   int lookback,
   int strength,
   double currentPrice,
   PFLSZoneRecord &nearestDemand,
   PFLSZoneRecord &nearestSupply
)
{
   PFLSZ_Reset(nearestDemand);
   PFLSZ_Reset(nearestSupply);

   if(lookback < 20)
      return false;

   if(strength < 1)
      return false;

   if(currentPrice <= 0.0)
      return false;

   double pointSize =
      SymbolInfoDouble(symbol, SYMBOL_POINT);

   if(pointSize <= 0.0)
      return false;

   MqlRates rates[];

   ArraySetAsSeries(rates, true);

   int copied = CopyRates(
      symbol,
      timeframe,
      1,
      lookback,
      rates
   );

   if(copied < strength * 2 + 5)
      return false;

   // --------------------------------------------------
   // SCAN CONFIRMED PIVOTS
   // --------------------------------------------------

   for(int i = strength;
       i < copied - strength;
       i++)
   {
      // ==============================================
      // DEMAND ZONE
      // ==============================================

      if(PFLSZ_IsPivotLow(
         rates,
         i,
         copied,
         strength
      ))
      {
         PFLSZoneRecord candidate;

         PFLSZ_Reset(candidate);

         candidate.valid     = true;
         candidate.isDemand  = true;

         candidate.lower     = rates[i].low;

         candidate.upper     =
            MathMax(
               rates[i].open,
               rates[i].close
            );

         candidate.timeframe = timeframe;

         candidate.formedAt  = rates[i].time;

         if(candidate.upper > candidate.lower)
         {
            PFLSZ_CheckZoneHistory(
               rates,
               i,
               candidate
            );

            if(!candidate.invalidated)
            {
               bool priceRelevant =
                  candidate.upper < currentPrice ||
                  (
                     currentPrice >= candidate.lower &&
                     currentPrice <= candidate.upper
                  );

               if(priceRelevant)
               {
                  candidate.distancePoints =
                     MathAbs(
                        currentPrice - candidate.upper
                     ) / pointSize;

                  PFLSZ_UpdateZoneState(
                     candidate,
                     currentPrice
                  );

                  if(!nearestDemand.valid ||
                     candidate.distancePoints <
                     nearestDemand.distancePoints)
                  {
                     nearestDemand = candidate;
                  }
               }
            }
         }
      }

      // ==============================================
      // SUPPLY ZONE
      // ==============================================

      if(PFLSZ_IsPivotHigh(
         rates,
         i,
         copied,
         strength
      ))
      {
         PFLSZoneRecord candidate;

         PFLSZ_Reset(candidate);

         candidate.valid     = true;
         candidate.isDemand  = false;

         candidate.lower     =
            MathMin(
               rates[i].open,
               rates[i].close
            );

         candidate.upper     = rates[i].high;

         candidate.timeframe = timeframe;

         candidate.formedAt  = rates[i].time;

         if(candidate.upper > candidate.lower)
         {
            PFLSZ_CheckZoneHistory(
               rates,
               i,
               candidate
            );

            if(!candidate.invalidated)
            {
               bool priceRelevant =
                  candidate.lower > currentPrice ||
                  (
                     currentPrice >= candidate.lower &&
                     currentPrice <= candidate.upper
                  );

               if(priceRelevant)
               {
                  candidate.distancePoints =
                     MathAbs(
                        candidate.lower - currentPrice
                     ) / pointSize;

                  PFLSZ_UpdateZoneState(
                     candidate,
                     currentPrice
                  );

                  if(!nearestSupply.valid ||
                     candidate.distancePoints <
                     nearestSupply.distancePoints)
                  {
                     nearestSupply = candidate;
                  }
               }
            }
         }
      }
   }

   return (
      nearestDemand.valid ||
      nearestSupply.valid
   );
}

// -----------------------------------------------------
// CHECK ZONE OVERLAP
// -----------------------------------------------------

bool PFLSZ_ZonesOverlap(
   PFLSZoneRecord &zoneA,
   PFLSZoneRecord &zoneB
)
{
   if(!zoneA.valid || !zoneB.valid)
      return false;

   if(zoneA.invalidated || zoneB.invalidated)
      return false;

   if(zoneA.isDemand != zoneB.isDemand)
      return false;

   return (
      zoneA.lower <= zoneB.upper &&
      zoneA.upper >= zoneB.lower
   );
}

// -----------------------------------------------------
// FRESHNESS SCORE
//
// This is a heuristic ranking score.
// It is NOT a probability of winning.
// -----------------------------------------------------

double PFLSZ_FreshnessScore(
   PFLSZoneRecord &zone
)
{
   if(!zone.valid || zone.invalidated)
      return 0.0;

   double score = 100.0;

   score -= zone.touches * 15.0;

   if(score < 0.0)
      score = 0.0;

   return score;
}

// =====================================================
// END OF PFLS ZONES MODULE
// VERSION 1.20
// =====================================================

#endif // PFLS_ZONES_MQH
