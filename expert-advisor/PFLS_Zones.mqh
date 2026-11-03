
#ifndef PFLS_ZONES_MQH
#define PFLS_ZONES_MQH

// =====================================================
// PFLS TRADER
// PRICE FLOW LADDER SEQUENCE
// ZONE DETECTION MODULE
// Version 1.40
//
// Added:
// - Confirmed market structure detection
// - Higher High / Higher Low detection
// - Lower High / Lower Low detection
// - Bullish / Bearish / Neutral directional bias
// =====================================================

// -----------------------------------------------------
// ZONE STATE
// -----------------------------------------------------

enum ENUM_PFLS_ZONE_STATE
{
   PFLS_ZONE_APPROACHING,
   PFLS_ZONE_INSIDE,
   PFLS_ZONE_DEPARTED,
   PFLS_ZONE_UNTESTED
};

// -----------------------------------------------------
// MARKET STRUCTURE BIAS
// -----------------------------------------------------

enum ENUM_PFLS_MARKET_BIAS
{
   PFLS_BIAS_BEARISH = -1,
   PFLS_BIAS_NEUTRAL = 0,
   PFLS_BIAS_BULLISH = 1
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

// =====================================================
// RESET ZONE
// =====================================================

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

// =====================================================
// PIVOT LOW
// rates[] must be a series array.
// Index 0 is the latest completed candle.
// =====================================================

bool PFLSZ_IsPivotLow(
   MqlRates &rates[],
   int index,
   int total,
   int strength
)
{
   if(strength < 1 ||
      index < strength ||
      index + strength >= total)
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

// =====================================================
// PIVOT HIGH
// =====================================================

bool PFLSZ_IsPivotHigh(
   MqlRates &rates[],
   int index,
   int total,
   int strength
)
{
   if(strength < 1 ||
      index < strength ||
      index + strength >= total)
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

// =====================================================
// MARKET STRUCTURE DETECTOR
//
// Compares the two most recent confirmed swing highs
// and the two most recent confirmed swing lows.
//
// BULLISH:
// Latest high > previous high
// AND
// Latest low > previous low
//
// BEARISH:
// Latest high < previous high
// AND
// Latest low < previous low
//
// Otherwise NEUTRAL.
//
// This is a structural classification, not a prediction.
// =====================================================

ENUM_PFLS_MARKET_BIAS PFLSZ_DetectMarketStructure(
   string symbol,
   ENUM_TIMEFRAMES timeframe,
   int lookback,
   int strength
)
{
   if(lookback < 30 || strength < 1)
      return PFLS_BIAS_NEUTRAL;

   MqlRates rates[];

   ArraySetAsSeries(rates, true);

   int copied = CopyRates(
      symbol,
      timeframe,
      1,
      lookback,
      rates
   );

   if(copied < strength * 2 + 10)
      return PFLS_BIAS_NEUTRAL;

   // --------------------------------------------------
   // SWING HIGH STORAGE
   // --------------------------------------------------

   double latestHigh = 0.0;
   double previousHigh = 0.0;

   int highCount = 0;

   // --------------------------------------------------
   // SWING LOW STORAGE
   // --------------------------------------------------

   double latestLow = 0.0;
   double previousLow = 0.0;

   int lowCount = 0;

   // --------------------------------------------------
   // SCAN CONFIRMED SWINGS
   //
   // Series indexing:
   // Smaller index = more recent candle.
   //
   // Therefore the first two detected pivots of each
   // type are the latest and previous confirmed swings.
   // --------------------------------------------------

   for(int i = strength;
       i < copied - strength;
       i++)
   {
      if(highCount < 2 &&
         PFLSZ_IsPivotHigh(
            rates,
            i,
            copied,
            strength
         ))
      {
         if(highCount == 0)
            latestHigh = rates[i].high;
         else
            previousHigh = rates[i].high;

         highCount++;
      }

      if(lowCount < 2 &&
         PFLSZ_IsPivotLow(
            rates,
            i,
            copied,
            strength
         ))
      {
         if(lowCount == 0)
            latestLow = rates[i].low;
         else
            previousLow = rates[i].low;

         lowCount++;
      }

      if(highCount >= 2 && lowCount >= 2)
         break;
   }

   // --------------------------------------------------
   // REQUIRE TWO CONFIRMED SWINGS OF EACH TYPE
   // --------------------------------------------------

   if(highCount < 2 || lowCount < 2)
      return PFLS_BIAS_NEUTRAL;

   // --------------------------------------------------
   // BULLISH STRUCTURE
   // --------------------------------------------------

   bool higherHighs =
      latestHigh > previousHigh;

   bool higherLows =
      latestLow > previousLow;

   if(higherHighs && higherLows)
      return PFLS_BIAS_BULLISH;

   // --------------------------------------------------
   // BEARISH STRUCTURE
   // --------------------------------------------------

   bool lowerHighs =
      latestHigh < previousHigh;

   bool lowerLows =
      latestLow < previousLow;

   if(lowerHighs && lowerLows)
      return PFLS_BIAS_BEARISH;

   // --------------------------------------------------
   // MIXED OR UNCLEAR STRUCTURE
   // --------------------------------------------------

   return PFLS_BIAS_NEUTRAL;
}

// =====================================================
// CHECK ZONE HISTORY
// Counts separate visits and checks invalidation.
// =====================================================

void PFLSZ_CheckZoneHistory(
   MqlRates &rates[],
   int pivotIndex,
   PFLSZoneRecord &zone
)
{
   zone.touches = 0;
   zone.invalidated = false;

   int total = ArraySize(rates);

   if(total <= 0 ||
      pivotIndex <= 0 ||
      pivotIndex >= total)
      return;

   bool wasInside = false;

   for(int i = pivotIndex - 1; i >= 0; i--)
   {
      bool overlaps =
         rates[i].high >= zone.lower &&
         rates[i].low <= zone.upper;

      if(overlaps && !wasInside)
         zone.touches++;

      wasInside = overlaps;

      if(zone.isDemand &&
         rates[i].close < zone.lower)
      {
         zone.invalidated = true;
         return;
      }

      if(!zone.isDemand &&
         rates[i].close > zone.upper)
      {
         zone.invalidated = true;
         return;
      }
   }
}

// =====================================================
// UPDATE ZONE STATE
// =====================================================

void PFLSZ_UpdateZoneState(
   PFLSZoneRecord &zone,
   double currentPrice,
   double previousPrice
)
{
   if(!zone.valid ||
      zone.invalidated ||
      currentPrice <= 0.0)
   {
      zone.zoneState = PFLS_ZONE_UNTESTED;
      return;
   }

   if(currentPrice >= zone.lower &&
      currentPrice <= zone.upper)
   {
      zone.zoneState = PFLS_ZONE_INSIDE;
      return;
   }

   if(zone.touches <= 0)
   {
      zone.zoneState = PFLS_ZONE_UNTESTED;
      return;
   }

   if(zone.isDemand)
   {
      if(currentPrice > zone.upper)
      {
         if(previousPrice > 0.0 &&
            currentPrice < previousPrice)
            zone.zoneState = PFLS_ZONE_APPROACHING;
         else
            zone.zoneState = PFLS_ZONE_DEPARTED;

         return;
      }

      zone.zoneState = PFLS_ZONE_DEPARTED;
      return;
   }

   if(currentPrice < zone.lower)
   {
      if(previousPrice > 0.0 &&
         currentPrice > previousPrice)
         zone.zoneState = PFLS_ZONE_APPROACHING;
      else
         zone.zoneState = PFLS_ZONE_DEPARTED;

      return;
   }

   zone.zoneState = PFLS_ZONE_DEPARTED;
}

// =====================================================
// DETECT NEAREST VALID DEMAND AND SUPPLY
// =====================================================

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

   if(lookback < 20 ||
      strength < 1 ||
      currentPrice <= 0.0)
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

   double previousPrice = rates[0].close;

   for(int i = strength;
       i < copied - strength;
       i++)
   {
      // ----------------------------------------------
      // DEMAND ZONE
      // ----------------------------------------------

      if(PFLSZ_IsPivotLow(
         rates, i, copied, strength
      ))
      {
         PFLSZoneRecord candidate;

         PFLSZ_Reset(candidate);

         candidate.valid = true;
         candidate.isDemand = true;

         candidate.lower = rates[i].low;

         candidate.upper = MathMax(
            rates[i].open,
            rates[i].close
         );

         candidate.timeframe = timeframe;
         candidate.formedAt = rates[i].time;

         if(candidate.upper > candidate.lower)
         {
            PFLSZ_CheckZoneHistory(
               rates, i, candidate
            );

            if(!candidate.invalidated)
            {
               bool relevant =
                  candidate.upper < currentPrice ||
                  (
                     currentPrice >= candidate.lower &&
                     currentPrice <= candidate.upper
                  );

               if(relevant)
               {
                  candidate.distancePoints =
                     MathAbs(
                        currentPrice - candidate.upper
                     ) / pointSize;

                  PFLSZ_UpdateZoneState(
                     candidate,
                     currentPrice,
                     previousPrice
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

      // ----------------------------------------------
      // SUPPLY ZONE
      // ----------------------------------------------

      if(PFLSZ_IsPivotHigh(
         rates, i, copied, strength
      ))
      {
         PFLSZoneRecord candidate;

         PFLSZ_Reset(candidate);

         candidate.valid = true;
         candidate.isDemand = false;

         candidate.lower = MathMin(
            rates[i].open,
            rates[i].close
         );

         candidate.upper = rates[i].high;

         candidate.timeframe = timeframe;
         candidate.formedAt = rates[i].time;

         if(candidate.upper > candidate.lower)
         {
            PFLSZ_CheckZoneHistory(
               rates, i, candidate
            );

            if(!candidate.invalidated)
            {
               bool relevant =
                  candidate.lower > currentPrice ||
                  (
                     currentPrice >= candidate.lower &&
                     currentPrice <= candidate.upper
                  );

               if(relevant)
               {
                  candidate.distancePoints =
                     MathAbs(
                        candidate.lower - currentPrice
                     ) / pointSize;

                  PFLSZ_UpdateZoneState(
                     candidate,
                     currentPrice,
                     previousPrice
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

// =====================================================
// ZONE OVERLAP
// =====================================================

bool PFLSZ_ZonesOverlap(
   PFLSZoneRecord &zoneA,
   PFLSZoneRecord &zoneB
)
{
   if(!zoneA.valid ||
      !zoneB.valid ||
      zoneA.invalidated ||
      zoneB.invalidated)
      return false;

   if(zoneA.isDemand != zoneB.isDemand)
      return false;

   return (
      zoneA.lower <= zoneB.upper &&
      zoneA.upper >= zoneB.lower
   );
}

// =====================================================
// FRESHNESS SCORE
// Heuristic only. Not a probability.
// =====================================================

double PFLSZ_FreshnessScore(
   PFLSZoneRecord &zone
)
{
   if(!zone.valid || zone.invalidated)
      return 0.0;

   double score = 100.0 - zone.touches * 15.0;

   if(score < 0.0)
      score = 0.0;

   return score;
}

// =====================================================
// END OF PFLS ZONES MODULE
// VERSION 1.40
// =====================================================

#endif
