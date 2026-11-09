
#property strict
#property version   "0.10"
#property description "PFLS 2.00 - Multi-Timeframe Supply and Demand Zone Mapper"

// ==========================================================
// PFLS 2.00 - ZONE MAPPER
// Version 0.10 - Initial research build
//
// Scans:
// W1, D1, H4, H1, M30, M15, M5, M1
//
// Features:
// - Origin candle detection
// - Confirmed swing BOS qualification
// - Multi-timeframe zone rectangles
// - Timeframe-specific colours
// - Persistent chart objects
// - Nearest supply and demand information
//
// IMPORTANT:
// Research indicator only.
// Does NOT execute trades.
// ==========================================================

input int InpBarsToScan       = 500;
input int InpSwingStrength    = 2;
input int InpSwingLookback    = 100;
input int InpMaxBaseCandles   = 5;
input int InpExtendBars       = 300;
input int InpScanSeconds      = 15;
input int InpMinimumBodyRatio = 0;

input bool InpShowW1          = true;
input bool InpShowD1          = true;
input bool InpShowH4          = true;
input bool InpShowH1          = true;
input bool InpShowM30         = true;
input bool InpShowM15         = true;
input bool InpShowM5          = true;
input bool InpShowM1          = true;

input bool InpShowPanel       = true;
input bool InpShowMidpoint    = true;
input bool InpShowLabels      = true;

// ----------------------------------------------------------
// GLOBAL SETTINGS
// ----------------------------------------------------------

#define PFLS_TF_COUNT 8

string PREFIX = "PFLS2_ZM_";

ENUM_TIMEFRAMES TF[PFLS_TF_COUNT] =
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

color TFColor[PFLS_TF_COUNT] =
{
   clrMediumPurple,
   clrDodgerBlue,
   clrCyan,
   clrLimeGreen,
   clrYellow,
   clrOrange,
   clrTomato,
   clrHotPink
};

bool TFEnabled[PFLS_TF_COUNT];

struct PFLSZone
{
   bool demand;
   int tfIndex;
   double upper;
   double lower;
   double midpoint;
   datetime originTime;
   double distance;
};

PFLSZone Zones[];

int DemandCount[PFLS_TF_COUNT];
int SupplyCount[PFLS_TF_COUNT];

double NearestSupplyDistance = 1.0e100;
double NearestDemandDistance = 1.0e100;

double NearestSupplyPrice = 0.0;
double NearestDemandPrice = 0.0;

string NearestSupplyTF = "NONE";
string NearestDemandTF = "NONE";

// ----------------------------------------------------------
// TIMEFRAME LABELS
// ----------------------------------------------------------

string TFName(ENUM_TIMEFRAMES timeframe)
{
   switch(timeframe)
   {
      case PERIOD_W1:  return "W1";
      case PERIOD_D1:  return "D1";
      case PERIOD_H4:  return "H4";
      case PERIOD_H1:  return "H1";
      case PERIOD_M30: return "M30";
      case PERIOD_M15: return "M15";
      case PERIOD_M5:  return "M5";
      case PERIOD_M1:  return "M1";
   }

   return "UNKNOWN";
}

// ----------------------------------------------------------
// ENABLED TIMEFRAMES
// ----------------------------------------------------------

void LoadTimeframeSettings()
{
   TFEnabled[0] = InpShowW1;
   TFEnabled[1] = InpShowD1;
   TFEnabled[2] = InpShowH4;
   TFEnabled[3] = InpShowH1;
   TFEnabled[4] = InpShowM30;
   TFEnabled[5] = InpShowM15;
   TFEnabled[6] = InpShowM5;
   TFEnabled[7] = InpShowM1;
}

// ----------------------------------------------------------
// PIVOT HIGH
// ----------------------------------------------------------

bool IsPivotHigh(MqlRates &rates[],
                 int index,
                 int strength,
                 int total)
{
   if(index - strength < 0 ||
      index + strength >= total)
      return false;

   double value = rates[index].high;

   for(int k = 1; k <= strength; k++)
   {
      if(value <= rates[index-k].high)
         return false;

      if(value <= rates[index+k].high)
         return false;
   }

   return true;
}

// ----------------------------------------------------------
// PIVOT LOW
// ----------------------------------------------------------

bool IsPivotLow(MqlRates &rates[],
                int index,
                int strength,
                int total)
{
   if(index - strength < 0 ||
      index + strength >= total)
      return false;

   double value = rates[index].low;

   for(int k = 1; k <= strength; k++)
   {
      if(value >= rates[index-k].low)
         return false;

      if(value >= rates[index+k].low)
         return false;
   }

   return true;
}

// ----------------------------------------------------------
// REMOVE OLD INDICATOR OBJECTS
// ----------------------------------------------------------

void ClearPFLSObjects()
{
   int total = ObjectsTotal(0, 0, -1);

   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);

      if(StringFind(name, PREFIX) == 0)
         ObjectDelete(0, name);
   }
}

// ----------------------------------------------------------
// ADD ZONE TO REGISTRY
// ----------------------------------------------------------

void AddZone(bool demand,
             int tfIndex,
             double upper,
             double lower,
             datetime originTime)
{
   if(upper <= lower)
      return;

   // Prevent duplicate origin zones.
   for(int i = 0; i < ArraySize(Zones); i++)
   {
      if(Zones[i].tfIndex == tfIndex &&
         Zones[i].demand == demand &&
         Zones[i].originTime == originTime)
         return;
   }

   int size = ArraySize(Zones);
   ArrayResize(Zones, size + 1);

   Zones[size].demand = demand;
   Zones[size].tfIndex = tfIndex;
   Zones[size].upper = upper;
   Zones[size].lower = lower;
   Zones[size].midpoint = (upper + lower) / 2.0;
   Zones[size].originTime = originTime;
   Zones[size].distance = 0.0;

   if(demand)
      DemandCount[tfIndex]++;
   else
      SupplyCount[tfIndex]++;
}

// ----------------------------------------------------------
// DETECT ZONES ON ONE TIMEFRAME
// ----------------------------------------------------------

void ScanTimeframe(int tfIndex)
{
   ENUM_TIMEFRAMES timeframe = TF[tfIndex];

   MqlRates rates[];

   ArraySetAsSeries(rates, true);

   int copied = CopyRates(
      _Symbol,
      timeframe,
      0,
      InpBarsToScan,
      rates
   );

   int required = InpSwingStrength * 2 + 10;

   if(copied < required)
      return;

   // Scan completed candles only.
   // Index zero is the currently forming candle.

   for(int s = copied - InpSwingStrength - 2;
       s >= InpSwingStrength + 1;
       s--)
   {
      bool bullishBreak = false;
      bool bearishBreak = false;

      double brokenHigh = 0.0;
      double brokenLow = 0.0;

      int searchEnd = (int)MathMin(
         s + InpSwingLookback,
         copied - InpSwingStrength - 1
      );

      // Find the nearest previously confirmed swing.

      for(int j = s + InpSwingStrength + 1;
          j <= searchEnd;
          j++)
      {
         if(!bullishBreak &&
            IsPivotHigh(
               rates,
               j,
               InpSwingStrength,
               copied
            ))
         {
            if(rates[s].close > rates[j].high)
            {
               bullishBreak = true;
               brokenHigh = rates[j].high;
            }
         }

         if(!bearishBreak &&
            IsPivotLow(
               rates,
               j,
               InpSwingStrength,
               copied
            ))
         {
            if(rates[s].close < rates[j].low)
            {
               bearishBreak = true;
               brokenLow = rates[j].low;
            }
         }

         if(bullishBreak || bearishBreak)
            break;
      }

      // Candle body strength is recorded as a filter.
      double candleRange =
         rates[s].high - rates[s].low;

      if(candleRange <= 0.0)
         continue;

      double bodyRatio =
         MathAbs(rates[s].close-rates[s].open)
         / candleRange * 100.0;

      if(bodyRatio < InpMinimumBodyRatio)
         continue;

      // ---------------------------------------------------
      // DEMAND ZONE
      // Bearish origin followed by bullish BOS
      // ---------------------------------------------------

      if(bullishBreak)
      {
         int origin = s + 1;

         // Primary origin must be bearish.
         if(rates[origin].close < rates[origin].open)
         {
            int baseCount = 0;
            double upper = -1.0e100;
            double lower = 1.0e100;

            for(int b = origin;
                b < origin + InpMaxBaseCandles &&
                b < copied - 1;
                b++)
            {
               // Entire consecutive bearish base.
               if(rates[b].close >= rates[b].open)
                  break;

               double bodyHigh = MathMax(
                  rates[b].open,
                  rates[b].close
               );

               upper = MathMax(upper, bodyHigh);
               lower = MathMin(lower, rates[b].low);

               baseCount++;
            }

            if(baseCount > 0)
            {
               AddZone(
                  true,
                  tfIndex,
                  upper,
                  lower,
                  rates[origin].time
               );
            }
         }
      }

      // ---------------------------------------------------
      // SUPPLY ZONE
      // Bullish origin followed by bearish BOS
      // ---------------------------------------------------

      if(bearishBreak)
      {
         int origin = s + 1;

         // Primary origin must be bullish.
         if(rates[origin].close > rates[origin].open)
         {
            int baseCount = 0;
            double upper = -1.0e100;
            double lower = 1.0e100;

            for(int b = origin;
                b < origin + InpMaxBaseCandles &&
                b < copied - 1;
                b++)
            {
               // Entire consecutive bullish base.
               if(rates[b].close <= rates[b].open)
                  break;

               upper = MathMax(upper, rates[b].high);

               double bodyLow = MathMin(
                  rates[b].open,
                  rates[b].close
               );

               lower = MathMin(lower, bodyLow);

               baseCount++;
            }

            if(baseCount > 0)
            {
               AddZone(
                  false,
                  tfIndex,
                  upper,
                  lower,
                  rates[origin].time
               );
            }
         }
      }
   }
}

// ----------------------------------------------------------
// DRAW RECTANGLE
// ----------------------------------------------------------

void DrawZone(PFLSZone &zone)
{
   int tfIndex = zone.tfIndex;

   string timeframeName = TFName(TF[tfIndex]);

   string typeName =
      zone.demand ? "DEMAND" : "SUPPLY";

   string objectName =
      PREFIX +
      timeframeName + "_" +
      typeName + "_" +
      IntegerToString((long)zone.originTime);

   datetime endTime =
      TimeCurrent() +
      (datetime)(
         PeriodSeconds(TF[tfIndex]) *
         InpExtendBars
      );

   if(!ObjectCreate(
      0,
      objectName,
      OBJ_RECTANGLE,
      0,
      zone.originTime,
      zone.upper,
      endTime,
      zone.lower
   ))
      return;

   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_COLOR,
      TFColor[tfIndex]
   );

   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_FILL,
      true
   );

   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_BACK,
      true
   );

   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_SELECTABLE,
      false
   );

   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_HIDDEN,
      true
   );

   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_WIDTH,
      1
   );

   if(InpShowLabels)
   {
      string labelName = objectName + "_LABEL";

      if(ObjectCreate(
         0,
         labelName,
         OBJ_TEXT,
         0,
         endTime,
         zone.midpoint
      ))
      {
         string label =
            timeframeName + " " + typeName;

         ObjectSetString(
            0,
            labelName,
            OBJPROP_TEXT,
            label
         );

         ObjectSetInteger(
            0,
            labelName,
            OBJPROP_COLOR,
            TFColor[tfIndex]
         );

         ObjectSetInteger(
            0,
            labelName,
            OBJPROP_FONTSIZE,
            8
         );

         ObjectSetInteger(
            0,
            labelName,
            OBJPROP_SELECTABLE,
            false
         );

         ObjectSetInteger(
            0,
            labelName,
            OBJPROP_HIDDEN,
            true
         );
      }
   }

   if(InpShowMidpoint)
   {
      string midpointName =
         objectName + "_MID";

      if(ObjectCreate(
         0,
         midpointName,
         OBJ_TREND,
         0,
         zone.originTime,
         zone.midpoint,
         endTime,
         zone.midpoint
      ))
      {
         ObjectSetInteger(
            0,
            midpointName,
            OBJPROP_COLOR,
            TFColor[tfIndex]
         );

         ObjectSetInteger(
            0,
            midpointName,
            OBJPROP_STYLE,
            STYLE_DOT
         );

         ObjectSetInteger(
            0,
            midpointName,
            OBJPROP_RAY_RIGHT,
            false
         );

         ObjectSetInteger(
            0,
            midpointName,
            OBJPROP_BACK,
            true
         );

         ObjectSetInteger(
            0,
            midpointName,
            OBJPROP_SELECTABLE,
            false
         );

         ObjectSetInteger(
            0,
            midpointName,
            OBJPROP_HIDDEN,
            true
         );
      }
   }
}

// ----------------------------------------------------------
// FIND NEAREST SUPPLY AND DEMAND
// ----------------------------------------------------------

void CalculateNearestZones()
{
   NearestSupplyDistance = 1.0e100;
   NearestDemandDistance = 1.0e100;

   NearestSupplyPrice = 0.0;
   NearestDemandPrice = 0.0;

   NearestSupplyTF = "NONE";
   NearestDemandTF = "NONE";

   double price = SymbolInfoDouble(
      _Symbol,
      SYMBOL_BID
   );

   for(int i = 0; i < ArraySize(Zones); i++)
   {
      PFLSZone zone = Zones[i];

      if(!zone.demand && zone.lower > price)
      {
         double distance = zone.lower - price;

         if(distance < NearestSupplyDistance)
         {
            NearestSupplyDistance = distance;
            NearestSupplyPrice = zone.lower;
            NearestSupplyTF =
               TFName(TF[zone.tfIndex]);
         }
      }

      if(zone.demand && zone.upper < price)
      {
         double distance = price - zone.upper;

         if(distance < NearestDemandDistance)
         {
            NearestDemandDistance = distance;
            NearestDemandPrice = zone.upper;
            NearestDemandTF =
               TFName(TF[zone.tfIndex]);
         }
      }
   }
}

// ----------------------------------------------------------
// INFORMATION PANEL
// ----------------------------------------------------------

void DrawPanel()
{
   if(!InpShowPanel)
      return;

   string name = PREFIX + "PANEL";

   string text =
      "PFLS 2.00 - ZONE MAPPER\n";

   text += "Symbol: " + _Symbol + "\n";

   text += "Timeframes: ";

   int enabledCount = 0;

   for(int i = 0; i < PFLS_TF_COUNT; i++)
   {
      if(TFEnabled[i])
         enabledCount++;
   }

   text += IntegerToString(enabledCount) + "/8\n";

   text += "Zones detected: " +
      IntegerToString(ArraySize(Zones)) + "\n";

   text += "------------------------\n";

   for(int i = 0; i < PFLS_TF_COUNT; i++)
   {
      if(!TFEnabled[i])
         continue;

      text += TFName(TF[i]) +
         "  D:" + IntegerToString(DemandCount[i]) +
         "  S:" + IntegerToString(SupplyCount[i]) +
         "\n";
   }

   text += "------------------------\n";

   text += "NEAREST SUPPLY: " +
      NearestSupplyTF + "\n";

   if(NearestSupplyPrice > 0.0)
      text += DoubleToString(
         NearestSupplyPrice,
         _Digits
      ) + "\n";

   text += "NEAREST DEMAND: " +
      NearestDemandTF + "\n";

   if(NearestDemandPrice > 0.0)
      text += DoubleToString(
         NearestDemandPrice,
         _Digits
      ) + "\n";

   text += "Research mode - no trading";

   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(
         0,
         name,
         OBJ_LABEL,
         0,
         0,
         0
      );
   }

   ObjectSetInteger(
      0,
      name,
      OBJPROP_CORNER,
      CORNER_LEFT_UPPER
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_XDISTANCE,
      12
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_YDISTANCE,
      20
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_COLOR,
      clrWhite
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_FONTSIZE,
      9
   );

   ObjectSetString(
      0,
      name,
      OBJPROP_FONT,
      "Consolas"
   );

   ObjectSetString(
      0,
      name,
      OBJPROP_TEXT,
      text
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_SELECTABLE,
      false
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_HIDDEN,
      true
   );
}

// ----------------------------------------------------------
// COMPLETE SCAN
// ----------------------------------------------------------

void ScanAllTimeframes()
{
   LoadTimeframeSettings();

   ArrayResize(Zones, 0);

   ArrayInitialize(DemandCount, 0);
   ArrayInitialize(SupplyCount, 0);

   ClearPFLSObjects();

   for(int i = 0; i < PFLS_TF_COUNT; i++)
   {
      if(!TFEnabled[i])
         continue;

      ScanTimeframe(i);
   }

   for(int i = 0; i < ArraySize(Zones); i++)
   {
      DrawZone(Zones[i]);
   }

   CalculateNearestZones();

   DrawPanel();

   ChartRedraw();
}

// ----------------------------------------------------------
// INITIALISATION
// ----------------------------------------------------------

int OnInit()
{
   LoadTimeframeSettings();

   Print("PFLS 2.00 Zone Mapper v0.10 starting.");

   ScanAllTimeframes();

   EventSetTimer(
      (int)MathMax(1, InpScanSeconds)
   );

   return INIT_SUCCEEDED;
}

// ----------------------------------------------------------
// TIMER
// ----------------------------------------------------------

void OnTimer()
{
   ScanAllTimeframes();
}

// ----------------------------------------------------------
// CHART CALCULATION
// ----------------------------------------------------------

int OnCalculate(
   const int rates_total,
   const int prev_calculated,
   const datetime &time[],
   const double &open[],
   const double &high[],
   const double &low[],
   const double &close[],
   const long &tick_volume[],
   const long &volume[],
   const int &spread[]
)
{
   return rates_total;
}

// ----------------------------------------------------------
// SHUTDOWN
// ----------------------------------------------------------

void OnDeinit(const int reason)
{
   EventKillTimer();

   // Do not delete chart objects here.
   // They are redrawn after timeframe changes.

   Print("PFLS 2.00 Zone Mapper stopped.");
}
