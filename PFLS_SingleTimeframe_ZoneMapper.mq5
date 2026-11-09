
#property strict
#property version   "2.001"
#property description "PFLS 2.00 - Single Timeframe Fresh Zone Mapper"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

// ==========================================================
// PFLS SINGLE-TIMEFRAME ZONE MAPPER 2.001
//
// Scans ONLY the timeframe of the chart where attached.
//
// Supply ranking: S1, S2, S3...
// Demand ranking:  DM1, DM2, DM3...
//
// Fresh-zone rule:
// First subsequent price entry, including a wick,
// marks the zone as interacted with.
//
// Interacted zones are excluded from active display.
//
// Research indicator only. No trade execution.
// ==========================================================


// -------------------- INPUTS -------------------------------

input int InpBarsToScan       = 500;
input int InpSwingStrength    = 2;
input int InpSwingLookback    = 100;
input int InpMaxBaseCandles   = 5;
input int InpExtendBars       = 300;
input int InpScanSeconds      = 15;
input int InpMinimumBodyRatio = 0;

input bool InpShowMidpoint    = true;
input bool InpShowLabels      = true;
input bool InpShowPanel       = true;


// -------------------- GLOBALS ------------------------------

#define PREFIX "PFLS_STZM_"

struct PFLSZone
{
   bool demand;
   bool touched;

   double upper;
   double lower;
   double midpoint;
   double distance;

   int rank;

   datetime originTime;
   datetime baseStartTime;
   datetime baseEndTime;
};

PFLSZone Zones[];

int FreshSupplyCount = 0;
int FreshDemandCount = 0;
int InteractedCount  = 0;

double CurrentPrice = 0.0;


// -------------------- TIMEFRAME NAME -----------------------

string CurrentTFName()
{
   return EnumToString((ENUM_TIMEFRAMES)_Period);
}


// -------------------- SAFE TIMESTAMP -----------------------

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


// -------------------- CLEAR OUR OBJECTS --------------------

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


// -------------------- PIVOT HIGH ---------------------------

bool IsPivotHigh(
   MqlRates &rates[],
   int index,
   int strength,
   int total
)
{
   if(index-strength<0 ||
      index+strength>=total)
      return false;

   double value = rates[index].high;

   for(int k=1; k<=strength; k++)
   {
      if(value<=rates[index-k].high)
         return false;

      if(value<=rates[index+k].high)
         return false;
   }

   return true;
}


// -------------------- PIVOT LOW ----------------------------

bool IsPivotLow(
   MqlRates &rates[],
   int index,
   int strength,
   int total
)
{
   if(index-strength<0 ||
      index+strength>=total)
      return false;

   double value = rates[index].low;

   for(int k=1; k<=strength; k++)
   {
      if(value>=rates[index-k].low)
         return false;

      if(value>=rates[index+k].low)
         return false;
   }

   return true;
}


// -------------------- FIND BROKEN SWING HIGH ---------------

bool FindBrokenSwingHigh(
   MqlRates &rates[],
   int breakIndex,
   int strength,
   int lookback,
   int total
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

      if(rates[breakIndex].close>rates[j].high)
         return true;
   }

   return false;
}


// -------------------- FIND BROKEN SWING LOW ----------------

bool FindBrokenSwingLow(
   MqlRates &rates[],
   int breakIndex,
   int strength,
   int lookback,
   int total
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

      if(rates[breakIndex].close<rates[j].low)
         return true;
   }

   return false;
}


// -------------------- TOUCH / INTERACTION TEST --------------

bool HasPriceEnteredZone(
   MqlRates &rates[],
   int breakIndex,
   double upper,
   double lower
)
{
   for(int i=breakIndex-1; i>=0; i--)
   {
      if(rates[i].high>=lower &&
         rates[i].low<=upper)
      {
         return true;
      }
   }

   return false;
}


// -------------------- ADD ZONE ------------------------------

void AddZone(
   bool demand,
   double upper,
   double lower,
   datetime originTime,
   datetime baseStart,
   datetime baseEnd,
   bool touched
)
{
   if(upper<=lower)
      return;

   for(int i=0; i<ArraySize(Zones); i++)
   {
      if(Zones[i].demand==demand &&
         Zones[i].originTime==originTime)
         return;
   }

   int size = ArraySize(Zones);

   if(ArrayResize(Zones,size+1)!=size+1)
      return;

   Zones[size].demand = demand;
   Zones[size].touched = touched;

   Zones[size].upper = upper;
   Zones[size].lower = lower;
   Zones[size].midpoint = (upper+lower)/2.0;

   Zones[size].originTime = originTime;
   Zones[size].baseStartTime = baseStart;
   Zones[size].baseEndTime = baseEnd;

   Zones[size].distance = 0.0;
   Zones[size].rank = 0;

   if(touched)
      InteractedCount++;
}


// -------------------- BUILD DEMAND -------------------------
//
// Primary origin: last bearish candle in the base.
// Upper boundary: highest body boundary.
// Lower boundary: lowest wick across the base.
// ------------------------------------------------------------

void BuildDemandZone(
   MqlRates &rates[],
   int breakIndex,
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
      upper,
      lower,
      rates[primaryOrigin].time,
      baseStart,
      baseEnd,
      touched
   );
}


// -------------------- BUILD SUPPLY -------------------------
//
// Primary origin: last bullish candle in the base.
// Upper boundary: highest wick across the base.
// Lower boundary: lowest body boundary.
//
// Mirrored supply boundaries remain experimental.
// ------------------------------------------------------------

void BuildSupplyZone(
   MqlRates &rates[],
   int breakIndex,
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
      upper,
      lower,
      rates[primaryOrigin].time,
      baseStart,
      baseEnd,
      touched
   );
}


// -------------------- SCAN CURRENT TIMEFRAME ----------------

void ScanCurrentTimeframe()
{
   ArrayResize(Zones,0);

   FreshSupplyCount = 0;
   FreshDemandCount = 0;
   InteractedCount = 0;

   MqlRates rates[];

   ArraySetAsSeries(rates,true);

   int copied = CopyRates(
      _Symbol,
      (ENUM_TIMEFRAMES)_Period,
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
      bool bullishBreak = FindBrokenSwingHigh(
         rates,
         s,
         InpSwingStrength,
         InpSwingLookback,
         copied
      );

      bool bearishBreak = FindBrokenSwingLow(
         rates,
         s,
         InpSwingStrength,
         InpSwingLookback,
         copied
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
         BuildDemandZone(rates,s,copied);

      if(bearishBreak)
         BuildSupplyZone(rates,s,copied);
   }

   CurrentPrice = SymbolInfoDouble(
      _Symbol,
      SYMBOL_BID
   );

   if(CurrentPrice<=0.0)
      return;

   RankZones();
}


// -------------------- RANK FRESH ZONES ---------------------
//
// Supply ranks independently above price.
// Demand ranks independently below price.
//
// Equal distances are resolved by registry order.
// ------------------------------------------------------------

void RankZones()
{
   FreshSupplyCount = 0;
   FreshDemandCount = 0;

   for(int i=0; i<ArraySize(Zones); i++)
   {
      Zones[i].rank = 0;
      Zones[i].distance = 0.0;

      if(Zones[i].touched)
         continue;

      if(!Zones[i].demand &&
         Zones[i].lower>CurrentPrice)
      {
         Zones[i].distance =
            Zones[i].lower-CurrentPrice;

         FreshSupplyCount++;
      }

      if(Zones[i].demand &&
         Zones[i].upper<CurrentPrice)
      {
         Zones[i].distance =
            CurrentPrice-Zones[i].upper;

         FreshDemandCount++;
      }
   }

   for(int i=0; i<ArraySize(Zones); i++)
   {
      if(Zones[i].touched)
         continue;

      bool isRankable = false;

      if(!Zones[i].demand &&
         Zones[i].lower>CurrentPrice)
         isRankable = true;

      if(Zones[i].demand &&
         Zones[i].upper<CurrentPrice)
         isRankable = true;

      if(!isRankable)
         continue;

      int rank = 1;

      for(int j=0; j<ArraySize(Zones); j++)
      {
         if(i==j || Zones[j].touched)
            continue;

         if(Zones[i].demand!=Zones[j].demand)
            continue;

         bool otherRankable = false;

         if(!Zones[j].demand &&
            Zones[j].lower>CurrentPrice)
            otherRankable = true;

         if(Zones[j].demand &&
            Zones[j].upper<CurrentPrice)
            otherRankable = true;

         if(!otherRankable)
            continue;

         if(Zones[j].distance<Zones[i].distance)
            rank++;

         else if(
            Zones[j].distance==Zones[i].distance &&
            j<i
         )
         {
            rank++;
         }
      }

      Zones[i].rank = rank;
   }
}


// -------------------- ZONE RANK LABEL -----------------------

string ZoneRankLabel(PFLSZone &zone)
{
   if(zone.demand)
      return "DM"+IntegerToString(zone.rank);

   return "S"+IntegerToString(zone.rank);
}


// -------------------- DRAW ZONE -----------------------------

void DrawZone(PFLSZone &zone)
{
   if(zone.touched)
      return;

   string rankLabel = ZoneRankLabel(zone);

   string typeName =
      zone.demand ? "DEMAND" : "SUPPLY";

   string objectName =
      PREFIX+
      typeName+"_"+
      ZoneTimeKey(zone.originTime);

   int chartSeconds = PeriodSeconds(_Period);

   if(chartSeconds<=0)
      chartSeconds = 60;

   datetime endTime =
      TimeCurrent()+
      (datetime)(chartSeconds*InpExtendBars);

   color zoneColor =
      zone.demand ? clrLimeGreen : clrTomato;

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
      0,objectName,OBJPROP_COLOR,zoneColor
   );

   ObjectSetInteger(
      0,objectName,OBJPROP_FILL,true
   );

   ObjectSetInteger(
      0,objectName,OBJPROP_BACK,true
   );

   ObjectSetInteger(
      0,objectName,OBJPROP_WIDTH,1
   );

   ObjectSetInteger(
      0,objectName,OBJPROP_SELECTABLE,false
   );

   ObjectSetInteger(
      0,objectName,OBJPROP_HIDDEN,true
   );


   // RANK AND TIMEFRAME LABEL

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
         string labelText =
            rankLabel+
            " | "+
            CurrentTFName();

         ObjectSetString(
            0,
            labelName,
            OBJPROP_TEXT,
            labelText
         );

         ObjectSetInteger(
            0,
            labelName,
            OBJPROP_COLOR,
            zoneColor
         );

         ObjectSetInteger(
            0,
            labelName,
            OBJPROP_FONTSIZE,
            9
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
      string midName = objectName+"_MID";

      if(ObjectCreate(
         0,
         midName,
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
            midName,
            OBJPROP_COLOR,
            zoneColor
         );

         ObjectSetInteger(
            0,
            midName,
            OBJPROP_STYLE,
            STYLE_DOT
         );

         ObjectSetInteger(
            0,
            midName,
            OBJPROP_RAY_RIGHT,
            false
         );

         ObjectSetInteger(
            0,
            midName,
            OBJPROP_BACK,
            true
         );

         ObjectSetInteger(
            0,
            midName,
            OBJPROP_SELECTABLE,
            false
         );

         ObjectSetInteger(
            0,
            midName,
            OBJPROP_HIDDEN,
            true
         );
      }
   }
}


// -------------------- INFORMATION PANEL --------------------

void DrawPanel()
{
   string name = PREFIX+"PANEL";

   if(!InpShowPanel)
   {
      ObjectDelete(0,name);
      return;
   }

   string panelText =
      "PFLS SINGLE-TIMEFRAME ZONE MAPPER\n";

   panelText +=
      "Symbol: "+_Symbol+"\n";

   panelText +=
      "Chart timeframe: "+CurrentTFName()+"\n";

   panelText +=
      "Fresh supply: "+
      IntegerToString(FreshSupplyCount)+"\n";

   panelText +=
      "Fresh demand: "+
      IntegerToString(FreshDemandCount)+"\n";

   panelText +=
      "Interacted history: "+
      IntegerToString(InteractedCount)+"\n";

   panelText += "----------------------------\n";

   panelText +=
      "Supply ranking: S1, S2, S3...\n";

   panelText +=
      "Demand ranking: DM1, DM2, DM3...\n";

   panelText += "----------------------------\n";

   panelText +=
      "Current price: "+
      DoubleToString(CurrentPrice,_Digits)+"\n";

   panelText +=
      "Analysis: CURRENT TF ONLY\n";

   panelText +=
      "Research only - no trade execution";


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


// -------------------- COMPLETE SCAN -------------------------

void RunPFLSScan()
{
   ClearPFLSObjects();

   ScanCurrentTimeframe();

   for(int i=0; i<ArraySize(Zones); i++)
   {
      if(!Zones[i].touched)
         DrawZone(Zones[i]);
   }

   DrawPanel();

   ChartRedraw();
}


// -------------------- INITIALISATION ------------------------

int OnInit()
{
   Print(
      "PFLS Single-Timeframe Zone Mapper 2.001 started. ",
      "Chart timeframe: ",
      CurrentTFName()
   );

   EventSetTimer(
      (int)MathMax(1,InpScanSeconds)
   );

   RunPFLSScan();

   return INIT_SUCCEEDED;
}


// -------------------- TIMER ---------------------------------

void OnTimer()
{
   RunPFLSScan();
}


// -------------------- CALCULATION ---------------------------

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


// -------------------- SHUTDOWN ------------------------------

void OnDeinit(const int reason)
{
   EventKillTimer();

   ClearPFLSObjects();

   Print(
      "PFLS Single-Timeframe Zone Mapper stopped."
   );
}
