
#ifndef PFLS_EXECUTION_MQH
#define PFLS_EXECUTION_MQH

#include "PFLS_Zones.mqh"
#include <Trade/Trade.mqh>

// ============================================
// PFLS EXECUTION MODULE
// Version 1.10
// DEMO DEVELOPMENT BUILD
// ============================================

// Execution is OFF by default.
input bool PFLS_EnableExecution = false;
input bool PFLS_EmergencyStop = false;

// Fixed trading configuration.
input double PFLS_FixedLots = 0.01;
input double PFLS_MaxRiskPercent = 3.0;
input int PFLS_MaxTradesPerDay = 2;

// Unique EA identifier.
input ulong PFLS_MagicNumber = 751103;

// Stop-loss buffer.
input int PFLS_StopBufferPoints = 20;

// Trade object.
CTrade PFLS_Trade;

// Last attempted execution candle.
datetime PFLS_LastExecutionBar = 0;

// ============================================
// PRICE NORMALIZATION
// ============================================

double PFLS_NormalizeTradePrice(double price)
{
   double tickSize = SymbolInfoDouble(
      _Symbol,
      SYMBOL_TRADE_TICK_SIZE
   );

   int digits = (int)SymbolInfoInteger(
      _Symbol,
      SYMBOL_DIGITS
   );

   if(tickSize <= 0.0)
      return NormalizeDouble(price, digits);

   double normalized =
      MathRound(price / tickSize) * tickSize;

   return NormalizeDouble(normalized, digits);
}

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

   if(signalBarTime <= PFLS_LastExecutionBar)
      return false;

   bool overlapsDemand =
      demand.valid &&
      !demand.invalidated &&
      candle[0].low <= demand.upper &&
      candle[0].high >= demand.lower;

   bool overlapsSupply =
      supply.valid &&
      !supply.invalidated &&
      candle[0].high >= supply.lower &&
      candle[0].low <= supply.upper;

   bool bullish =
      candle[0].close > candle[0].open;

   bool bearish =
      candle[0].close < candle[0].open;

   if(overlapsDemand && overlapsSupply)
      return false;

   if(overlapsDemand && bullish)
   {
      isBuy = true;
      return true;
   }

   if(overlapsSupply && bearish)
   {
      isBuy = false;
      return true;
   }

   return false;
}

// ============================================
// COUNT DISTINCT ENTRY ORDERS TODAY
// Partial fills of one order count as one.
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

   ulong countedOrders[];

   int orderCount = 0;

   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong deal = HistoryDealGetTicket(i);

      if(deal == 0)
         continue;

      if(HistoryDealGetString(
         deal,
         DEAL_SYMBOL
      ) != _Symbol)
      {
         continue;
      }

      if((ulong)HistoryDealGetInteger(
         deal,
         DEAL_MAGIC
      ) != PFLS_MagicNumber)
      {
         continue;
      }

      ENUM_DEAL_ENTRY entry =
         (ENUM_DEAL_ENTRY)HistoryDealGetInteger(
            deal,
            DEAL_ENTRY
         );

      if(entry != DEAL_ENTRY_IN &&
         entry != DEAL_ENTRY_INOUT)
      {
         continue;
      }

      ulong orderTicket =
         (ulong)HistoryDealGetInteger(
            deal,
            DEAL_ORDER
         );

      if(orderTicket == 0)
         continue;

      bool alreadyCounted = false;

      for(int j = 0; j < orderCount; j++)
      {
         if(countedOrders[j] == orderTicket)
         {
            alreadyCounted = true;
            break;
         }
      }

      if(!alreadyCounted)
      {
         ArrayResize(countedOrders, orderCount + 1);
         countedOrders[orderCount] = orderTicket;
         orderCount++;
      }
   }

   return orderCount;
}

// ============================================
// ONE POSITION AT A TIME ON THIS SYMBOL
// Includes manual and other EA positions.
// Prevents netting-account interference.
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

      if(symbol == _Symbol)
         return true;
   }

   return false;
}

// ============================================
// FIXED VOLUME VALIDATION
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
// TRADING PERMISSIONS
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
// DEMO ACCOUNT PROTECTION
// ============================================

bool PFLS_ExecutionDemoCheck()
{
   ENUM_ACCOUNT_TRADE_MODE mode =
      (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(
         ACCOUNT_TRADE_MODE
      );

   if(mode != ACCOUNT_TRADE_MODE_DEMO)
   {
      Print("PFLS: Execution restricted to demo accounts.");
      return false;
   }

   return true;
}

// ============================================
// VERIFY CURRENT PRICE IS STILL IN ENTRY ZONE
// Prevents late entries after price has departed.
// ============================================

bool PFLS_ExecutionPriceInsideZone(
   PFLSZoneRecord &zone,
   MqlTick &tick
)
{
   double midpoint = (tick.bid + tick.ask) / 2.0;

   if(midpoint < zone.lower || midpoint > zone.upper)
   {
      Print("PFLS: Entry rejected. Price has left the zone.");
      return false;
   }

   return true;
}

// ============================================
// MAIN EXECUTION FUNCTION
// ============================================

bool PFLS_ExecutionTryTrade(
   bool isBuy,
   PFLSZoneRecord &entryZone,
   PFLSZoneRecord &targetZone,
   datetime signalBarTime
)
{
   // ----------------------------------------
   // EXECUTION SWITCH
   // ----------------------------------------

   if(!PFLS_EnableExecution)
      return false;

   // ----------------------------------------
   // EMERGENCY STOP
   // ----------------------------------------

   if(PFLS_EmergencyStop)
   {
      Print("PFLS: EMERGENCY STOP ACTIVE.");
      return false;
   }

   // ----------------------------------------
   // DEMO ACCOUNT PROTECTION
   // ----------------------------------------

   if(!PFLS_ExecutionDemoCheck())
      return false;

   // ----------------------------------------
   // TRADING PERMISSIONS
   // ----------------------------------------

   if(!PFLS_ExecutionPermissions())
      return false;

   // ----------------------------------------
   // CONFIGURATION VALIDATION
   // ----------------------------------------

   if(signalBarTime <= 0 ||
      signalBarTime <= PFLS_LastExecutionBar)
   {
      return false;
   }

   if(PFLS_FixedLots != 0.01 ||
      PFLS_MaxRiskPercent <= 0.0 ||
      PFLS_MaxRiskPercent > 3.0 ||
      PFLS_MaxTradesPerDay < 1 ||
      PFLS_MaxTradesPerDay > 2 ||
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
      Print("PFLS: Existing position blocks new entry.");
      return false;
   }

   // ----------------------------------------
   // DAILY TRADE LIMIT
   // ----------------------------------------

   int dailyTrades = PFLS_ExecutionCountToday();

   if(dailyTrades < 0)
   {
      Print("PFLS: Unable to verify daily trade count.");
      return false;
   }

   if(dailyTrades >= PFLS_MaxTradesPerDay)
   {
      Print("PFLS: Daily trade limit reached.");
      return false;
   }

   // ----------------------------------------
   // FIXED VOLUME
   // ----------------------------------------

   if(!PFLS_ExecutionValidateVolume())
      return false;

   // ----------------------------------------
   // CURRENT PRICE
   // ----------------------------------------

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   if(tick.bid <= 0.0 || tick.ask <= 0.0)
      return false;

   double point = SymbolInfoDouble(
      _Symbol,
      SYMBOL_POINT
   );

   if(point <= 0.0)
      return false;

   // Price must still be inside the entry zone.
   if(!PFLS_ExecutionPriceInsideZone(entryZone, tick))
      return false;

   double entryPrice = isBuy ? tick.ask : tick.bid;

   double stopLoss;
   double takeProfit;

   // ----------------------------------------
   // BUY LEVELS
   // ----------------------------------------

   if(isBuy)
   {
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

   // ----------------------------------------
   // NORMALIZE TO SYMBOL TICK SIZE
   // ----------------------------------------

   stopLoss = PFLS_NormalizeTradePrice(stopLoss);
   takeProfit = PFLS_NormalizeTradePrice(takeProfit);

   if(isBuy && (stopLoss >= entryPrice ||
                takeProfit <= entryPrice))
      return false;

   if(!isBuy && (stopLoss <= entryPrice ||
                 takeProfit >= entryPrice))
      return false;

   // ----------------------------------------
   // BROKER STOP DISTANCE
   // ----------------------------------------

   long stopsLevel = SymbolInfoInteger(
      _Symbol,
      SYMBOL_TRADE_STOPS_LEVEL
   );

   long freezeLevel = SymbolInfoInteger(
      _Symbol,
      SYMBOL_TRADE_FREEZE_LEVEL
   );

   long requiredLevel = (long)MathMax(
      stopsLevel,
      freezeLevel
   );

   double minimumDistance = requiredLevel * point;

   if(MathAbs(entryPrice - stopLoss) < minimumDistance ||
      MathAbs(takeProfit - entryPrice) < minimumDistance)
   {
      Print("PFLS: Broker stop/freeze distance not met.");
      return false;
   }

   // ----------------------------------------
   // CASH RISK CALCULATION
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
      Print("PFLS: Risk calculation failed.");
      return false;
   }

   estimatedLoss = MathAbs(estimatedLoss);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(equity <= 0.0)
      return false;

   double maximumLoss =
      equity * PFLS_MaxRiskPercent / 100.0;

   if(estimatedLoss > maximumLoss)
   {
      Print("PFLS: Estimated loss exceeds 3% risk limit.");
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
   // PREPARE ORDER
   // ----------------------------------------

   PFLS_Trade.SetExpertMagicNumber(PFLS_MagicNumber);

   PFLS_Trade.SetDeviationInPoints(20);

   if(!PFLS_Trade.SetTypeFillingBySymbol(_Symbol))
   {
      Print("PFLS: Filling mode unavailable.");
      return false;
   }

   // Mark candle before sending to prevent
   // repeated submissions after a rejection.
   PFLS_LastExecutionBar = signalBarTime;

   bool submitted = false;

   // ----------------------------------------
   // BUY ORDER
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
   // SELL ORDER
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
   // SERVER RESPONSE
   // ----------------------------------------

   uint resultCode = PFLS_Trade.ResultRetcode();

   if(!submitted ||
      (resultCode != TRADE_RETCODE_DONE &&
       resultCode != TRADE_RETCODE_PLACED &&
       resultCode != TRADE_RETCODE_DONE_PARTIAL))
   {
      Print(
         "PFLS: Order not confirmed. ",
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
      DoubleToString(stopLoss, _Digits),
      " | TP: ",
      DoubleToString(takeProfit, _Digits)
   );

   return true;
}

#endif
