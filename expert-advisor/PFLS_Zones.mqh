
// Inspect a candidate zone for distinct visits
// and invalidation.
void PFLSZ_CheckZoneHistory(
   MqlRates &rates[],
   int pivotIndex,
   PFLSZoneRecord &zone
)
{
   zone.touches = 0;
   zone.invalidated = false;

   bool wasInsideZone = false;

   // Walk forward in time from the pivot candle
   // towards the most recent closed candle.
   for(int j = pivotIndex - 1; j >= 0; j--)
   {
      bool overlaps =
         rates[j].high >= zone.lower &&
         rates[j].low <= zone.upper;

      // Invalidate only when a candle closes
      // beyond the far boundary of the zone.
      if(zone.isDemand && rates[j].close < zone.lower)
      {
         zone.invalidated = true;
         return;
      }

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

      // Remember whether the previous candle
      // was overlapping the zone.
      wasInsideZone = overlaps;
   }
}
