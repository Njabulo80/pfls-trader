
void PFLSZ_CheckZoneHistory(
   MqlRates &rates[],
   int pivotIndex,
   PFLSZoneRecord &zone
)
{
   zone.touches = 0;
   zone.invalidated = false;

   bool wasInsideZone = false;

   // Scan from the pivot candle towards the latest
   // closed candle. MqlRates is a series array.
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

      // Count one touch when price enters the zone
      // after being outside it.
      if(overlaps && !wasInsideZone)
      {
         zone.touches++;
      }

      // Track whether this candle overlaps the zone.
      wasInsideZone = overlaps;
   }
}
