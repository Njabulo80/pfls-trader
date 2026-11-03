
#ifndef PFLS_EXECUTION_MQH
#define PFLS_EXECUTION_MQH

#include <Trade/Trade.mqh>

// ============================================
// PFLS AUTOMATIC EXECUTION MODULE
// Version 1.00 - DEMO DEVELOPMENT
// ============================================

// Execution remains disabled by default.
input bool PFLS_EnableExecution = false;
input bool PFLS_EmergencyStop = false;

// Fixed risk configuration.
input double PFLS_FixedLots = 0.01;
input double PFLS_MaxRiskPercent = 3.0;
input int PFLS_MaxTradesPerDay = 2;

// Unique identifier for PFLS trades.
input ulong PFLS_MagicNumber = 751103;

// Stop-loss safety buffer.
input int PFLS_StopBufferPoints = 20;

// ============================================
// TRADE OBJECT
// ============================================

CTrade PFLS_Trade;

// Prevent duplicate execution on the same candle.
datetime PFLS_LastExecutionBar = 0;

// ============================================
// M5 CANDLE CONFIRMATION
// ============================================

bool PFLS_ExecutionGetM5Signal(
   PFLSZoneRecord &demand,
   PFLSZoneRecord &supply,
   bool &isBuy,
   datetime &signalBarTime
)
{
   isBuy = false;
   signalBarTime = 0;

   MqlRates candle[];

   ArraySetAsSeries(candle, true);

   // Read the last COMPLETED M5 candle.
   if(CopyRates(
      _Symbol,
      PERIOD_M5,
      1,
      1,
      candle
   ) != 1)
   {
      return false;
   }

   signalBarTime = candle[0].time;

   if(signalBarTime <= 0)
      return false;

   // A candle can only be evaluated once.
   static datetime lastCheckedBar = 0;

   if(signalBarTime == lastCheckedBar)
      return false;

   lastCheckedBar = signalBarTime;

   bool overlapsDemand =
      demand.valid &&
      candle[0].low <= demand.upper &&
      candle[0].high >= demand.lower;

   bool overlapsSupply =
      supply.valid &&
      candle[0].high >= supply.lower &&
      candle[0].low <= supply.upper;

   bool bullish =
      candle[0].close > candle[0].open;

   bool bearish =
      candle[0].close < candle[0].open;

   // Reject ambiguous simultaneous signals.
   if(overlapsDemand && overlapsSupply)
      return false;

   // BUY confirmation.
   if(overlapsDemand && bullish)
   {
      isBuy = true;
      return true;
   }

   // SELL confirmation.
   if(overlapsSupply && bearish)
   {
      isBuy = false;
      return true;
   }

   return false;
}

// ============================================
// COUNT TODAY'S PFLS ENTRY DEALS
// Uses broker server time.
// ============================================

int PFLS_ExecutionCountToday()
{
   datetime now = TimeTradeServer();

   if(now <= 0)
      return -1;

   MqlDateTime dateParts;

   if(!TimeToStruct(now, dateParts))
      return -1;

   dateParts.hour = 0;
   dateParts.min = 0;
   dateParts.sec = 0;

   datetime dayStart = StructToTime(dateParts);

   if(!HistorySelect(dayStart, now))
      return -1;

   int count = 0;

   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);

      if(ticket == 0)
         continue;

      if(HistoryDealGetString(
         ticket,
         DEAL_SYMBOL
      ) != _Symbol)
      {
         continue;
      }

      if((ulong)HistoryDealGetInteger(
         ticket,
         DEAL_MAGIC
      ) != PFLS_MagicNumber)
      {
         continue;
      }

      ENUM_DEAL_ENTRY entry =
         (ENUM_DEAL_ENTRY)HistoryDealGetInteger(
            ticket,
            DEAL_ENTRY
         );

      if(entry != DEAL_ENTRY_IN &&
         entry != DEAL_ENTRY_INOUT)
      {
         continue;
      }

      count++;
   }

   return count;
}

// ============================================
// CHECK EXISTING PFLS POSITIONS
// ============================================

bool PFLS_ExecutionHasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      string symbol =
         PositionGetString(POSITION_SYMBOL);

      ulong magic =
         (ulong)PositionGetInteger(POSITION_MAGIC);

      if(symbol == _Symbol &&
         magic == PFLS_MagicNumber)
      {
         return true;
      }
   }

   return false;
}

// ============================================
// VALIDATE FIXED LOT SIZE
// Never increases or changes the requested lot.
// ============================================

bool PFLS_ExecutionValidateVolume()
{
   double minimum = SymbolInfoDouble(
      _Symbol,
      SYMBOL_VOLUME_MIN
   );

   double maximum = SymbolInfoDouble(
      _Symbol,
      SYMBOL_VOLUME_MAX
   );

   double step = SymbolInfoDouble(
      _Symbol,
      SYMBOL_VOLUME_STEP
   );

   if(step <= 0.0 ||
      PFLS_FixedLots < minimum ||
      PFLS_FixedLots > maximum)
   {
      Print("PFLS: Fixed 0.01 lot is not permitted.");
      return false;
   }

   double validVolume =
      MathRound(PFLS_FixedLots / step) * step;

   if(MathAbs(validVolume - PFLS_FixedLots) > 0.0000001)
   {
      Print("PFLS: Fixed lot does not match volume step.");
      return false;
   }

   return true;
}

// ============================================
// CHECK ACCOUNT AND TERMINAL PERMISSIONS
// ============================================

bool PFLS_ExecutionPermissions()
{
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;

   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return false;

   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      return false;

   return true;
}

// ============================================
// AUTOMATIC ORDER VALIDATION AND EXECUTION
// ============================================

bool PFLS_ExecutionTryTrade(
   bool isBuy,
   PFLSZoneRecord &entryZone,
   PFLSZoneRecord &targetZone,
   datetime signalBarTime
)
{
   // ----------------------------------------
   // SAFETY GATES
   // ----------------------------------------

   if(!PFLS_EnableExecution)
   {
      Print("PFLS: Execution disabled.");
      return false;
   }

   if(PFLS_EmergencyStop)
   {
      Print("PFLS: EMERGENCY STOP ACTIVE.");
      return false;
   }

   if(!PFLS_ExecutionPermissions())
   {
      Print("PFLS: Trading permissions unavailable.");
      return false;
   }

   if(signalBarTime <= 0 ||
      signalBarTime == PFLS_LastExecutionBar)
   {
      return false;
   }

   if(PFLS_MaxTradesPerDay < 1 ||
      PFLS_MaxRiskPercent <= 0.0 ||
      PFLS_MaxRiskPercent > 3.0 ||
      PFLS_FixedLots != 0.01 ||
      PFLS_StopBufferPoints < 1)
   {
      Print("PFLS: Unsafe execution configuration.");
      return false;
   }

   // ----------------------------------------
   // VALIDATE ZONES
   // ----------------------------------------

   if(!entryZone.valid ||
      !targetZone.valid ||
      entryZone.invalidated ||
      targetZone.invalidated)
   {
      Print("PFLS: Invalid entry or target zone.");
      return false;
   }

   if(isBuy)
   {
      if(!entryZone.isDemand || targetZone.isDemand)
         return false;
   }
   else
   {
      if(entryZone.isDemand || !targetZone.isDemand)
         return false;
   }

   // ----------------------------------------
   // POSITION LIMIT
   // ----------------------------------------

   if(PFLS_ExecutionHasOpenPosition())
   {
      Print("PFLS: Existing position prevents entry.");
      return false;
   }

   // ----------------------------------------
   // DAILY TRADE LIMIT
   // ----------------------------------------

   int dailyTrades = PFLS_ExecutionCountToday();

   if(dailyTrades < 0)
   {
      Print("PFLS: Cannot verify today's trade count.");
      return false;
   }

   if(dailyTrades >= PFLS_MaxTradesPerDay)
   {
      Print("PFLS: Daily trade limit reached.");
      return false;
   }

   // ----------------------------------------
   // FIXED VOLUME VALIDATION
   // ----------------------------------------

   if(!PFLS_ExecutionValidateVolume())
      return false;

   // ----------------------------------------
   // CURRENT MARKET PRICE
   // ----------------------------------------

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double point = SymbolInfoDouble(
      _Symbol,
      SYMBOL_POINT
   );

   int digits = (int)SymbolInfoInteger(
      _Symbol,
      SYMBOL_DIGITS
   );

   if(point <= 0.0 ||
      tick.bid <= 0.0 ||
      tick.ask <= 0.0)
   {
      return false;
   }

   double entryPrice;
   double stopLoss;
   double takeProfit;

   // ----------------------------------------
   // BUY LEVELS
   // ----------------------------------------

   if(isBuy)
   {
      entryPrice = tick.ask;

      stopLoss =
         entryZone.lower -
         PFLS_StopBufferPoints * point;

      takeProfit = targetZone.lower;

      if(stopLoss >= entryPrice ||
         takeProfit <= entryPrice)
      {
         Print("PFLS: Invalid BUY price structure.");
         return false;
      }
   }

   // ----------------------------------------
   // SELL LEVELS
   // ----------------------------------------

   else
   {
      entryPrice = tick.bid;

      stopLoss =
         entryZone.upper +
         PFLS_StopBufferPoints * point;

      takeProfit = targetZone.upper;

      if(stopLoss <= entryPrice ||
         takeProfit >= entryPrice)
      {
         Print("PFLS: Invalid SELL price structure.");
         return false;
      }
   }

   stopLoss = NormalizeDouble(stopLoss, digits);
   takeProfit = NormalizeDouble(takeProfit, digits);

   // ----------------------------------------
   // BROKER STOP DISTANCE
   // ----------------------------------------

   long stopsLevel = SymbolInfoInteger(
      _Symbol,
      SYMBOL_TRADE_STOPS_LEVEL
   );

   double minimumDistance = stopsLevel * point;

   if(MathAbs(entryPrice - stopLoss) < minimumDistance ||
      MathAbs(takeProfit - entryPrice) < minimumDistance)
   {
      Print("PFLS: Broker minimum stop distance not met.");
      return false;
   }

   // ----------------------------------------
   // ACTUAL CASH RISK CALCULATION
   // ----------------------------------------

   double estimatedLoss = 0.0;

   ENUM_ORDER_TYPE orderType =
      isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if(!OrderCalcProfit(
      orderType,
      _Symbol,
      PFLS_FixedLots,
      entryPrice,
      stopLoss,
      estimatedLoss
   ))
   {
      Print("PFLS: Cannot calculate potential loss.");
      return false;
   }

   estimatedLoss = MathAbs(estimatedLoss);

   double equity = AccountInfoDouble(
      ACCOUNT_EQUITY
   );

   if(equity <= 0.0)
      return false;

   double maximumLoss =
      equity * PFLS_MaxRiskPercent / 100.0;

   if(estimatedLoss > maximumLoss)
   {
      Print(
         "PFLS: Trade rejected. Risk exceeds 3%. ",
         "Estimated loss: ",
         DoubleToString(estimatedLoss, 2),
         " | Maximum: ",
         DoubleToString(maximumLoss, 2)
      );

      return false;
   }

   // ----------------------------------------
   // FREE MARGIN VALIDATION
   // ----------------------------------------

   double requiredMargin = 0.0;

   if(!OrderCalcMargin(
      orderType,
      _Symbol,
      PFLS_FixedLots,
      entryPrice,
      requiredMargin
   ))
   {
      Print("PFLS: Margin calculation failed.");
      return false;
   }

   if(requiredMargin >
      AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      Print("PFLS: Insufficient free margin.");
      return false;
   }

   // ----------------------------------------
   // PREPARE TRADE REQUEST
   // ----------------------------------------

   PFLS_Trade.SetExpertMagicNumber(
      PFLS_MagicNumber
   );

   PFLS_Trade.SetDeviationInPoints(20);

   if(!PFLS_Trade.SetTypeFillingBySymbol(_Symbol))
   {
      Print("PFLS: Could not set symbol filling mode.");
      return false;
   }

   // Prevent immediate duplicate attempts.
   PFLS_LastExecutionBar = signalBarTime;

   bool submitted = false;

   // ----------------------------------------
   // SUBMIT BUY
   // ----------------------------------------

   if(isBuy)
   {
      submitted = PFLS_Trade.Buy(
         PFLS_FixedLots,
         _Symbol,
         0.0,
         stopLoss,
         takeProfit,
         "PFLS Automatic BUY"
      );
   }

   // ----------------------------------------
   // SUBMIT SELL
   // ----------------------------------------

   else
   {
      submitted = PFLS_Trade.Sell(
         PFLS_FixedLots,
         _Symbol,
         0.0,
         stopLoss,
         takeProfit,
         "PFLS Automatic SELL"
      );
   }

   // ----------------------------------------
   // CHECK SERVER RESPONSE
   // ----------------------------------------

   uint resultCode = PFLS_Trade.ResultRetcode();

   if(!submitted ||
      (resultCode != TRADE_RETCODE_DONE &&
       resultCode != TRADE_RETCODE_PLACED &&
       resultCode != TRADE_RETCODE_DONE_PARTIAL))
   {
      Print(
         "PFLS: Order not confirmed. Retcode: ",
         resultCode,
         " | ",
         PFLS_Trade.ResultRetcodeDescription()
      );

      return false;
   }

   Print(
      "PFLS: Order response accepted. ",
      isBuy ? "BUY" : "SELL",
      " | Lots: ",
      DoubleToString(PFLS_FixedLots, 2),
      " | SL: ",
      DoubleToString(stopLoss, digits),
      " | TP: ",
      DoubleToString(takeProfit, digits)
   );

   return true;
}

#endif
