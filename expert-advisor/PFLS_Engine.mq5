
#property strict
#property version "1.00"
#property description "PFLS Trader - Multi-Timeframe Zone Scanner"
#property description "Read-only development build. No orders."

input int LookbackBars = 250;
input int PivotStrength = 2;
input int ScanIntervalSeconds = 30;

struct PFLSZone
{
   bool found;
   double low;
   double high;
   datetime candleTime;
};

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

bool IsPivotLow(MqlRates &rates[], int index, int total)
{
   if(index - PivotStrength < 0 ||
      index + PivotStrength >= total)
      return false;

   for(int k = 1; k <= PivotStrength; k++)
   {
      if(rates[index].low >= rates[index-k].low)
         return false;

      if(rates[index].low >= rates[index+k].low)
         return false;
   }

   return true;
}

bool IsPivotHigh(MqlRates &rates[], int index, int total)
{
   if(index - PivotStrength < 0 ||
      index + PivotStrength >= total)
      return false;

   for(int k = 1; k <= PivotStrength; k++)
   {
      if(rates[index].high <= rates[index-k].high)
         return false;

      if(rates[index].high <= rates[index+k].high)
         return false;
   }

   return true;
}

void FindZones(
   ENUM_TIMEFRAMES timeframe,
   double price,
   PFLSZone &demand,
   PFLSZone &supply
)
{
   demand.found = false;
   supply.found = false;

   double demandDistance = DBL_MAX;
   double supplyDistance = DBL_MAX;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   int copied = CopyRates(
      _Symbol,
      timeframe,
      1,
      LookbackBars,
      rates
   );

   if(copied < (PivotStrength * 2 + 10))
      return;

   for(int i = PivotStrength;
       i < copied - PivotStrength;
       i++)
   {
      if(IsPivotLow(rates, i, copied))
      {
         double low = rates[i].low;
         double high = MathMax(
            rates[i].open,
            rates[i].close
         );

         if(high <= price)
         {
            double distance = price - high;

            if(distance < demandDistance)
            {
               demandDistance = distance;
               demand.found = true;
               demand.low = low;
               demand.high = high;
               demand.candleTime = rates[i].time;
            }
         }
      }

      if(IsPivotHigh(rates, i, copied))
      {
         double low = MathMin(
            rates[i].open,
            rates[i].close
         );

         double high = rates[i].high;

         if(low >= price)
         {
            double distance = low - price;

            if(distance < supplyDistance)
            {
               supplyDistance = distance;
               supply.found = true;
               supply.low = low;
               supply.high = high;
               supply.candleTime = rates[i].time;
            }
         }
      }
   }
}

void ScanMarket()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("PFLS: Waiting for price data.");
      return;
   }

   double price = (tick.bid + tick.ask) / 2.0;

   Print("========== PFLS SCAN ==========");
   Print("Symbol: ", _Symbol);
   Print("Price: ", DoubleToString(price, _Digits));

   for(int i = 0; i < 8; i++)
   {
      PFLSZone demand;
      PFLSZone supply;

      FindZones(
         Timeframes[i],
         price,
         demand,
         supply
      );

      string message = TimeframeNames[i] + " | ";

      if(demand.found)
      {
         message += "Demand: " +
            DoubleToString(demand.low, _Digits) +
            " - " +
            DoubleToString(demand.high, _Digits);
      }
      else
      {
         message += "Demand: unavailable";
      }

      message += " | ";

      if(supply.found)
      {
         message += "Supply: " +
            DoubleToString(supply.low, _Digits) +
            " - " +
            DoubleToString(supply.high, _Digits);
      }
      else
      {
         message += "Supply: unavailable";
      }

      Print(message);
   }

   Print("========== SCAN COMPLETE ==========");
}

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

   Print("PFLS Engine v1.00 initialized.");
   Print("Instrument: ", _Symbol);
   Print("Mode: READ ONLY - NO TRADES");

   return INIT_SUCCEEDED;
}

void OnTimer()
{
   ScanMarket();
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("PFLS Engine stopped.");
}

