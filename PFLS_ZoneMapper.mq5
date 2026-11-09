
#property strict
#property version   "2.001"
#property description "PFLS 2.00 - Fresh Multi-Timeframe Zone Mapper"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

// ==========================================================
// PFLS TRADER - PRICE FLOW LADDER SEQUENCE
// ZONE MAPPER 2.001
//
// Research-only indicator. No trade execution.
//
// Scans W1, D1, H4, H1, M30, M15, M5, M1.
//
// Features:
// - Origin-candle supply and demand detection
// - Confirmed historical swing BOS
// - Fresh-zone filtering
// - First subsequent price entry marks interaction
// - Only untouched zones are drawn
// - Interacted zones retained in scan registry
// - Timeframe-specific colours
// - Midpoint lines and timeframe labels
//
// Historical registry is rebuilt from available chart
// history. Permanent storage is not yet implemented.
// ==========================================================


// ----------------------------------------------------------
// INPUTS
// ----------------------------------------------------------

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


// ----------------------------------------------------------
// ZONE STRUCTURE
// ----------------------------------------------------------

struct PFLSZone
{
   bool demand;
   bool touched;

   int tfIndex;

   double upper;
   double lower;
   double midpoint;

   datetime originTime;
   datetime baseStartTime;
   datetime baseEndTime;
};

PFLSZone Zones[];

int DemandCount[PFLS_TF_COUNT];
int SupplyCount[PFLS_TF_COUNT];

int FreshDemandCount = 0;
int FreshSupplyCount = 0;
int InteractedCount = 0;

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
// SAFE TIMESTAMP TEXT FOR OBJECT NAMES
// Replaces unsupported LongToString().
// ----------------------------------------------------------

string ZoneTimeKey(datetime value)
{
   string key = TimeToString(
      value,
      TIME_DATE|TIME_MINUTES
   );

   StringReplace(key,".","");
   StringReplace(key,":","");
   StringReplace(key," ","_");

   return key;
}


// ----------------------------------------------------------
// LOAD TIMEFRAME SETTINGS
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
// Series index 0 = current candle.
// Higher index = older candle.
// ----------------------------------------------------------

bool IsPivotHigh(
   MqlRates &rates[],
   int index,
   int strength,
   int total
)
{
   if(index-strength < 0 ||
      index+strength >= total)
      return false;

   double value = rates[index].high;

   for(int k=1; k<=strength; k++)
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

bool IsPivotLow(
   MqlRates &rates[],
   int index,
   int strength,
   int total
)
{
   if(index-strength < 0 ||
      index+strength >= total)
      return false;

   double value = rates[index].low;

   for(int k=1; k<=strength; k++)
   {
      if(value >= rates[index-k].low)
         return false;

      if(value >= rates[index+k].low)
         return false;
   }

   return true;
}


// ----------------------------------------------------------
// FIND BROKEN CONFIRMED SWING HIGH
// ----------------------------------------------------------

bool FindBrokenSwingHigh(
   MqlRates &rates[],
   int breakIndex,
   int strength,
   int lookback,
   int total,
   double &swingPrice
)
{
   int searchEnd = (int)MathMin(
      breakIndex+lookback,
      total-strength-1
   );

   for(int j=breakIndex+strength+1;
       j<=searchEnd;
       j++)
   {
      if(!IsPivotHigh(rates,j,strength,total))
         continue;

      if(rates[breakIndex].close > rates[j].high)
      {
         swingPrice = rates[j].high;
         return true;
      }
   }

   return false;
}


// ----------------------------------------------------------
// FIND BROKEN CONFIRMED SWING LOW
// ----------------------------------------------------------

bool FindBrokenSwingLow(
   MqlRates &rates[],
   int breakIndex,
   int strength,
   int lookback,
   int total,
   double &swingPrice
)
{
   int searchEnd = (int)MathMin(
      breakIndex+lookback,
      total-strength-1
   );

   for(int j=breakIndex+strength+1;
       j<=searchEnd;
       j++)
   {
      if(!IsPivotLow(rates,j,strength,total))
         continue;

      if(rates[breakIndex].close < rates[j].low)
      {
         swingPrice = rates[j].low;
         return true;
      }
   }

   return false;
}


// ----------------------------------------------------------
// CLEAR OWN CHART OBJECTS
// ----------------------------------------------------------

void ClearPFLSObjects()
{
   int total = ObjectsTotal(0,0,-1);

   for(int i=total-1; i>=0; i--)
   {
      string name = ObjectName(0,i,0,-1);

      if(StringFind(name,PREFIX)==0)
         ObjectDelete(0,name);
   }
}


// ----------------------------------------------------------
// CHECK WHETHER PRICE ENTERED ZONE AFTER FORMATION
//
// Any candle range overlapping the zone counts as entry.
// This includes a shallow wick entry.
//
// Index 0 is the current forming candle.
// ----------------------------------------------------------

bool HasPriceEnteredZone(
   MqlRates &rates[],
   int breakIndex,
   double upper,
   double lower
)
{
   for(int i=breakIndex-1; i>=0; i--)
   {
      if(rates[i].high >= lower &&
         rates[i].low <= upper)
      {
         return true;
      }
   }

   return false;
}


// ----------------------------------------------------------
// ADD ZONE TO INTERNAL REGISTRY
// ----------------------------------------------------------

void AddZone(
   bool demand,
   int tfIndex,
   double upper,
   double lower,
   datetime originTime,
   datetime baseStartTime,
   datetime baseEndTime,
   bool touched
)
{
   if(upper<=lower)
      return;

   for(int i=0; i<ArraySize(Zones); i++)
   {
      if(Zones[i].tfIndex==tfIndex &&
         Zones[i].demand==demand &&
         Zones[i].originTime==originTime)
      {
         return;
      }
   }

   int size = ArraySize(Zones);

   if(ArrayResize(Zones,size+1)!=size+1)
      return;

   Zones[size].demand = demand;
   Zones[size].touched = touched;
   Zones[size].tfIndex = tfIndex;

   Zones[size].upper = upper;
   Zones[size].lower = lower;
   Zones[size].midpoint = (upper+lower)/2.0;

   Zones[size].originTime = originTime;
   Zones[size].baseStartTime = baseStartTime;
   Zones[size].baseEndTime = baseEndTime;

   if(demand)
      DemandCount[tfIndex]++;
   else
      SupplyCount[tfIndex]++;

   if(touched)
   {
      InteractedCount++;
   }
   else
   {
      if(demand)
         FreshDemandCount++;
      else
         FreshSupplyCount++;
   }
}


// ----------------------------------------------------------
// BUILD DEMAND ZONE
//
// Primary origin: last bearish candle in base.
// Upper: highest body boundary.
// Lower: lowest wick.
// ----------------------------------------------------------

void BuildDemandZone(
   MqlRates &rates[],
   int breakIndex,
   int tfIndex,
   int total
)
{
   int origin = breakIndex+1;

   if(origin>=total)
      return;

   if(rates[origin].close>=rates[origin].open)
      return;

   int baseCount = 0;
   int primaryOrigin = -1;

   double upper = -1.0e100;
   double lower = 1.0e100;

   datetime baseStart = rates[origin].time;
   datetime baseEnd = rates[origin].time;

   for(int b=origin;
       b<origin+InpMaxBaseCandles && b<total-1;
       b++)
   {
      if(rates[b].close>rates[b].open)
         break;

      double bodyHigh = MathMax(
         rates[b].open,
         rates[b].close
      );

      upper = MathMax(upper,bodyHigh);
      lower = MathMin(lower,rates[b].low);

      if(rates[b].close<rates[b].open)
         primaryOrigin = b;

      baseEnd = rates[b].time;
      baseCount++;
   }

   if(baseCount<=0 || primaryOrigin<0)
      return;

   bool touched = HasPriceEnteredZone(
      rates,
      breakIndex,
      upper,
      lower
   );

   AddZone(
      true,
      tfIndex,
      upper,
      lower,
      rates[primaryOrigin].time,
      baseStart,
      baseEnd,
      touched
   );
}


// ----------------------------------------------------------
// BUILD SUPPLY ZONE
//
// Primary origin: last bullish candle in base.
// Upper: highest wick.
// Lower: lowest body boundary.
//
// Mirrored supply boundaries remain experimental.
// ----------------------------------------------------------

void BuildSupplyZone(
   MqlRates &rates[],
   int breakIndex,
   int tfIndex,
   int total
)
{
   int origin = breakIndex+1;

   if(origin>=total)
      return;

   if(rates[origin].close<=rates[origin].open)
      return;

   int baseCount = 0;
   int primaryOrigin = -1;

   double upper = -1.0e100;
   double lower = 1.0e100;

   datetime baseStart = rates[origin].time;
   datetime baseEnd = rates[origin].time;

   for(int b=origin;
       b<origin+InpMaxBaseCandles && b<total-1;
       b++)
   {
      if(rates[b].close<rates[b].open)
         break;

      upper = MathMax(upper,rates[b].high);

      double bodyLow = MathMin(
         rates[b].open,
         rates[b].close
      );

      lower = MathMin(lower,bodyLow);

      if(rates[b].close>rates[b].open)
         primaryOrigin = b;

      baseEnd = rates[b].time;
      baseCount++;
   }

   if(baseCount<=0 || primaryOrigin<0)
      return;

   bool touched = HasPriceEnteredZone(
      rates,
      breakIndex,
      upper,
      lower
   );

   AddZone(
      false,
      tfIndex,
      upper,
      lower,
      rates[primaryOrigin].time,
      baseStart,
      baseEnd,
      touched
   );
}


// ----------------------------------------------------------
// SCAN ONE TIMEFRAME
// ----------------------------------------------------------

void ScanTimeframe(int tfIndex)
{
   ENUM_TIMEFRAMES timeframe = TF[tfIndex];

   MqlRates rates[];

   ArraySetAsSeries(rates,true);

   int copied = CopyRates(
      _Symbol,
      timeframe,
      0,
      InpBarsToScan,
      rates
   );

   int required = InpSwingStrength*2+10;

   if(copied<required)
      return;

   for(int s=copied-InpSwingStrength-2;
       s>=1;
       s--)
   {
      double brokenHigh = 0.0;
      double brokenLow = 0.0;

      bool bullishBreak = FindBrokenSwingHigh(
         rates,
         s,
         InpSwingStrength,
         InpSwingLookback,
         copied,
         brokenHigh
      );

      bool bearishBreak = FindBrokenSwingLow(
         rates,
         s,
         InpSwingStrength,
         InpSwingLookback,
         copied,
         brokenLow
      );

      if(!bullishBreak && !bearishBreak)
         continue;

      double candleRange =
         rates[s].high-rates[s].low;

      if(candleRange<=0.0)
         continue;

      double bodyRatio =
         MathAbs(rates[s].close-rates[s].open)
         /candleRange*100.0;

      if(bodyRatio<InpMinimumBodyRatio)
         continue;

      if(bullishBreak)
      {
         BuildDemandZone(
            rates,
            s,
            tfIndex,
            copied
         );
      }

      if(bearishBreak)
      {
         BuildSupplyZone(
            rates,
            s,
            tfIndex,
            copied
         );
      }
   }
}


// ----------------------------------------------------------
// DRAW ONLY FRESH ZONES
// ----------------------------------------------------------

void DrawZone(PFLSZone &zone)
{
   if(zone.touched)
      return;

   int tfIndex = zone.tfIndex;

   string timeframeName = TFName(TF[tfIndex]);

   string typeName =
      zone.demand ? "DEMAND" : "SUPPLY";

   // CORRECTED TIMESTAMP CONVERSION

   string objectName =
      PREFIX+
      timeframeName+"_"+
      typeName+"_"+
      ZoneTimeKey(zone.originTime);

   int chartSeconds = PeriodSeconds(_Period);

   if(chartSeconds<=0)
      chartSeconds = 60;

   datetime endTime =
      TimeCurrent()+
      (datetime)(chartSeconds*InpExtendBars);

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
   {
      return;
   }

   ObjectSetInteger(
      0,objectName,OBJPROP_COLOR,TFColor[tfIndex]
   );

   ObjectSetInteger(
      0,objectName,OBJPROP_FILL,true
   );

   ObjectSetInteger(
      0,objectName,OBJPROP_BACK,true
   );

   ObjectSetInteger(
      0,objectName,OBJPROP_SELECTABLE,false
   );

   ObjectSetInteger(
      0,objectName,OBJPROP_HIDDEN,true
   );

   ObjectSetInteger(
      0,objectName,OBJPROP_WIDTH,1
   );


   // TIMEFRAME LABEL

   if(InpShowLabels)
   {
      string labelName = objectName+"_LABEL";

      if(ObjectCreate(
         0,
         labelName,
         OBJ_TEXT,
         0,
         endTime,
         zone.midpoint
      ))
      {
         ObjectSetString(
            0,
            labelName,
            OBJPROP_TEXT,
            timeframeName+" "+typeName
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


   // MIDPOINT LINE

   if(InpShowMidpoint)
   {
      string midpointName = objectName+"_MID";

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
// CALCULATE NEAREST FRESH OPPOSING ZONES
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

   if(price<=0.0)
      return;

   for(int i=0; i<ArraySize(Zones); i++)
   {
      PFLSZone zone = Zones[i];

      if(zone.touched)
         continue;

      if(!zone.demand && zone.lower>price)
      {
         double distance = zone.lower-price;

         if(distance<NearestSupplyDistance)
         {
            NearestSupplyDistance = distance;
            NearestSupplyPrice = zone.lower;
            NearestSupplyTF = TFName(TF[zone.tfIndex]);
         }
      }

      if(zone.demand && zone.upper<price)
      {
         double distance = price-zone.upper;

         if(distance<NearestDemandDistance)
         {
            NearestDemandDistance = distance;
            NearestDemandPrice = zone.upper;
            NearestDemandTF = TFName(TF[zone.tfIndex]);
         }
      }
   }
}


// ----------------------------------------------------------
// INFORMATION PANEL
// ----------------------------------------------------------

void DrawPanel()
{
   string name = PREFIX+"PANEL";

   if(!InpShowPanel)
   {
      ObjectDelete(0,name);
      return;
   }

   string panelText =
      "PFLS 2.00 - FRESH ZONE MAPPER\n";

   panelText += "Symbol: "+_Symbol+"\n";

   int enabledCount = 0;

   for(int i=0; i<PFLS_TF_COUNT; i++)
   {
      if(TFEnabled[i])
         enabledCount++;
   }

   panelText +=
      "Timeframes: "+
      IntegerToString(enabledCount)+"/8\n";

   panelText +=
      "Fresh demand: "+
      IntegerToString(FreshDemandCount)+"\n";

   panelText +=
      "Fresh supply: "+
      IntegerToString(FreshSupplyCount)+"\n";

   panelText +=
      "Interacted history: "+
      IntegerToString(InteractedCount)+"\n";

   panelText += "------------------------\n";

   for(int i=0; i<PFLS_TF_COUNT; i++)
   {
      if(!TFEnabled[i])
         continue;

      panelText +=
         TFName(TF[i])+
         " D:"+IntegerToString(DemandCount[i])+
         " S:"+IntegerToString(SupplyCount[i])+
         "\n";
   }

   panelText += "------------------------\n";

   panelText +=
      "NEAREST FRESH SUPPLY: "+
      NearestSupplyTF+"\n";

   if(NearestSupplyPrice>0.0)
   {
      panelText +=
         DoubleToString(NearestSupplyPrice,_Digits)+
         "\n";
   }

   panelText +=
      "NEAREST FRESH DEMAND: "+
      NearestDemandTF+"\n";

   if(NearestDemandPrice>0.0)
   {
      panelText +=
         DoubleToString(NearestDemandPrice,_Digits)+
         "\n";
   }

   panelText += "Research only - no trading";


   if(ObjectFind(0,name)<0)
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
      0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER
   );

   ObjectSetInteger(
      0,name,OBJPROP_XDISTANCE,12
   );

   ObjectSetInteger(
      0,name,OBJPROP_YDISTANCE,20
   );

   ObjectSetInteger(
      0,name,OBJPROP_COLOR,clrWhite
   );

   ObjectSetInteger(
      0,name,OBJPROP_FONTSIZE,9
   );

   ObjectSetString(
      0,name,OBJPROP_FONT,"Consolas"
   );

   ObjectSetString(
      0,name,OBJPROP_TEXT,panelText
   );

   ObjectSetInteger(
      0,name,OBJPROP_SELECTABLE,false
   );

   ObjectSetInteger(
      0,name,OBJPROP_HIDDEN,true
   );
}


// ----------------------------------------------------------
// COMPLETE MULTI-TIMEFRAME SCAN
// ----------------------------------------------------------

void ScanAllTimeframes()
{
   LoadTimeframeSettings();

   ArrayResize(Zones,0);

   ArrayInitialize(DemandCount,0);
   ArrayInitialize(SupplyCount,0);

   FreshDemandCount = 0;
   FreshSupplyCount = 0;
   InteractedCount = 0;

   ClearPFLSObjects();

   for(int i=0; i<PFLS_TF_COUNT; i++)
   {
      if(!TFEnabled[i])
         continue;

      ScanTimeframe(i);
   }

   // Draw only zones never entered by price.

   for(int i=0; i<ArraySize(Zones); i++)
   {
      if(!Zones[i].touched)
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

   Print(
      "PFLS 2.001 Fresh Zone Mapper started on ",
      _Symbol
   );

   EventSetTimer(
      (int)MathMax(1,InpScanSeconds)
   );

   ScanAllTimeframes();

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

   ClearPFLSObjects();

   Print("PFLS 2.001 Fresh Zone Mapper stopped.");
}
