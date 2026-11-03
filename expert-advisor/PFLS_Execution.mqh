
#ifndef PFLS_EXECUTION_MQH
#define PFLS_EXECUTION_MQH

#include "PFLS_Zones.mqh"
#include <Trade/Trade.mqh>

// =====================================================
// PFLS TRADER - EXECUTION MODULE
// Version 1.30
// M5 REJECTION + BREAKOUT CONFIRMATION
// =====================================================

// -----------------------------------------------------
// EXECUTION SETTINGS
// -----------------------------------------------------

input bool PFLS_EnableExecution = false;
input bool PFLS_EmergencyStop = false;

input double PFLS_FixedLots = 0.01;
input double PFLS_MaxRiskPercent = 3.0;
input int PFLS_MaxTradesPerDay = 2;

input ulong PFLS_MagicNumber = 751103;

input int PFLS_StopBufferPoints = 20;

// -----------------------------------------------------
// TRADE OBJECT
// -----------------------------------------------------

CTrade PFLS_Trade;

// -----------------------------------------------------
// SIGNAL TRACKING
// -----------------------------------------------------

datetime PFLS_LastExecutionBar = 0;

datetime PFLS_LastProcessedRejectionBar = 0;

datetime PFLS_PendingRejectionTime = 0;

double PFLS_PendingRejectionHigh = 0.0;
double PFLS_PendingRejectionLow = 0.0;

bool PFLS_PendingBuy = false;
bool PFLS_PendingSell = false;

// =====================================================
// PRICE NORMALIZATION
// =====================================================

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

// =====================================================
// RESET PENDING REJECTION
// =====================================================

void PFLS_ExecutionResetPending()
{
   PFLS_PendingRejectionTime = 0;

   PFLS_PendingRejectionHigh = 0.0;
   PFLS_PendingRejectionLow = 0.0;

   PFLS_PendingBuy = false;
   PFLS_PendingSell = false;
}

// =====================================================
// M5 REJECTION CANDLE VALIDATION
// =====================================================

bool PFLS_ExecutionIsBullishRejection(
   MqlRates &candle
)
{
   double body = MathAbs(
      candle.close - candle.open
   );

   double lowerWick =
      MathMin(candle.open, candle.close)
      - candle.low;

   if(body <= 0.0)
      return false;

   return (
      candle.close > candle.open &&
      lowerWick >= body * 0.5
   );
}

// -----------------------------------------------------

bool PFLS_ExecutionIsBearishRejection(
   MqlRates &candle
)
{
   double body = MathAbs(
      candle.close - candle.open
   );

   double upperWick =
      candle.high -
      MathMax(candle.open, candle.close);

   if(body <= 0.0)
      return false;

   return (
      candle.close < candle.open &&
      upperWick >= body * 0.5
   );
}

// =====================================================
// M5 REJECTION + NEXT-CANDLE BREAKOUT
//
// Stage 1:
// Find a completed rejection candle overlapping
// a valid M5 demand or supply zone.
//
// Stage 2:
// During the immediately following M5 candle,
// wait for price to break the rejection high/low.
//
// BUY = Ask breaks above rejection high.
// SELL = Bid breaks below rejection low.
// =====================================================

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

   datetime currentBarOpen = iTime(
      _Symbol,
      PERIOD_M5,
      0
   );

   if(currentBarOpen <= 0)
      return false;

   datetime rejectionTime = candle[0].time;

   int periodSeconds = PeriodSeconds(
      PERIOD_M5
   );

   if(periodSeconds <= 0)
      return false;

   // --------------------------------------------------
   // CHECK EXISTING PENDING REJECTION
   // --------------------------------------------------

   if(PFLS_PendingRejectionTime > 0)
   {
      datetime expectedBreakoutBar =
         PFLS_PendingRejectionTime + periodSeconds;

      // The immediate next candle is still active.
      if(currentBarOpen == expectedBreakoutBar)
      {
         MqlTick tick;

         if(!SymbolInfoTick(_Symbol, tick))
            return false;

         // BUY BREAKOUT
         if(PFLS_PendingBuy &&
            tick.ask > PFLS_PendingRejectionHigh)
         {
            isBuy = true;

            signalBarTime =
               PFLS_PendingRejectionTime;

            PFLS_LastProcessedRejectionBar =
               PFLS_PendingRejectionTime;

            Print(
               "PFLS: BUY breakout confirmed. "
               "Rejection high broken."
            );

            PFLS_ExecutionResetPending();

            return true;
         }

         // SELL BREAKOUT
         if(PFLS_PendingSell &&
            tick.bid < PFLS_PendingRejectionLow)
         {
            isBuy = false;

            signalBarTime =
               PFLS_PendingRejectionTime;

            PFLS_LastProcessedRejectionBar =
               PFLS_PendingRejectionTime;

            Print(
               "PFLS: SELL breakout confirmed. "
               "Rejection low broken."
            );

            PFLS_ExecutionResetPending();

            return true;
         }

         // No breakout yet. Keep waiting.
         return false;
      }

      // The next candle has ended without a breakout.
      if(currentBarOpen > expectedBreakoutBar)
      {
         Print(
            "PFLS: Rejection signal expired. "
            "Next M5 candle did not break the level."
         );

         PFLS_LastProcessedRejectionBar =
            PFLS_PendingRejectionTime;

         PFLS_ExecutionResetPending();
      }
      else
      {
         return false;
      }
   }

   // --------------------------------------------------
   // PREVENT REPEATED REJECTION PROCESSING
   // --------------------------------------------------

   if(rejectionTime <= PFLS_LastProcessedRejectionBar)
      return false;

   if(rejectionTime <= PFLS_LastExecutionBar)
      return false;

   // --------------------------------------------------
   // CHECK ZONE OVERLAP
   // --------------------------------------------------

   bool overlapsDemand =
      demand.valid &&
      !demand.invalidated &&
      demand.isDemand &&
      candle[0].low <= demand.upper &&
      candle[0].high >= demand.lower;

   bool overlapsSupply =
      supply.valid &&
      !supply.invalidated &&
      !supply.isDemand &&
      candle[0].high >= supply.lower &&
      candle[0].low <= supply.upper;

   // Do not accept an ambiguous candle.
   if(overlapsDemand && overlapsSupply)
      return false;

   // --------------------------------------------------
   // IDENTIFY BULLISH REJECTION AT DEMAND
   // --------------------------------------------------

   if(overlapsDemand &&
      PFLS_ExecutionIsBullishRejection(candle[0]))
   {
      PFLS_PendingBuy = true;
      PFLS_PendingSell = false;

      PFLS_PendingRejectionTime =
         rejectionTime;

      PFLS_PendingRejectionHigh =
         candle[0].high;

      PFLS_PendingRejectionLow =
         candle[0].low;

      Print(
         "PFLS: M5 bullish rejection recorded. "
         "Waiting for next-candle high breakout."
      );

      return false;
   }

   // --------------------------------------------------
   // IDENTIFY BEARISH REJECTION AT SUPPLY
   // --------------------------------------------------

   if(overlapsSupply &&
      PFLS_ExecutionIsBearishRejection(candle[0]))
   {
      PFLS_PendingSell = true;
      PFLS_PendingBuy = false;

      PFLS_PendingRejectionTime =
         rejectionTime;

      PFLS_PendingRejectionHigh =
         candle[0].high;

      PFLS_PendingRejectionLow =
         candle[0].low;

      Print(
         "PFLS: M5 bearish rejection recorded. "
         "Waiting for next-candle low breakout."
      );

      return false;
   }

   return false;
}

// =====================================================
// COUNT DISTINCT ENTRY ORDERS TODAY
// Broker server time.
// =====================================================

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

   datetime dayStart =
      StructToTime(dateParts);

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
         ArrayResize(
            countedOrders,
            orderCount + 1
         );

         countedOrders[orderCount] =
            orderTicket;

         orderCount++;
      }
   }

   return orderCount;
}

// =====================================================
// ONE POSITION AT A TIME ON THIS SYMBOL
// =====================================================

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

// =====================================================
// FIXED VOLUME VALIDATION
// =====================================================

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
      Print(
         "PFLS: Fixed 0.01 lot is not permitted."
      );

      return false;
   }

   double validVolume =
      MathRound(PFLS_FixedLots / step) * step;

   if(MathAbs(
      validVolume - PFLS_FixedLots
   ) > 0.0000001)
   {
      Print(
         "PFLS: Fixed lot does not match volume step."
      );

      return false;
   }

   return true;
}

// =====================================================
// TRADING PERMISSIONS
// =====================================================

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

// =====================================================
// MAIN EXECUTION FUNCTION
// =====================================================

bool PFLS_ExecutionTryTrade(
   bool isBuy,
   PFLSZoneRecord &entryZone,
   PFLSZoneRecord &targetZone,
   datetime signalBarTime
)
{
   // --------------------------------------------------
   // EXECUTION SWITCH
   // --------------------------------------------------

   if(!PFLS_EnableExecution)
      return false;

   // --------------------------------------------------
   // EMERGENCY STOP
   // --------------------------------------------------

   if(PFLS_EmergencyStop)
   {
      Print(
         "PFLS: EMERGENCY STOP ACTIVE."
      );

      return false;
   }

   // --------------------------------------------------
   // PERMISSIONS
   // --------------------------------------------------

   if(!PFLS_ExecutionPermissions())
   {
      Print(
         "PFLS: Trading permissions unavailable."
      );

      return false;
   }

   // --------------------------------------------------
   // CONFIGURATION VALIDATION
   // --------------------------------------------------

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
      Print(
         "PFLS: Unsafe execution configuration."
      );

      return false;
   }

   // --------------------------------------------------
   // VALIDATE ZONES
   // --------------------------------------------------

   if(!entryZone.valid ||
      !targetZone.valid ||
      entryZone.invalidated ||
      targetZone.invalidated)
   {
      Print(
         "PFLS: Invalid entry or target zone."
      );

      return false;
   }

   if(isBuy)
   {
      if(!entryZone.isDemand ||
         targetZone.isDemand)
      {
         return false;
      }
   }
   else
   {
      if(entryZone.isDemand ||
         !targetZone.isDemand)
      {
         return false;
      }
   }

   // --------------------------------------------------
   // POSITION LIMIT
   // --------------------------------------------------

   if(PFLS_ExecutionHasOpenPosition())
   {
      Print(
         "PFLS: Existing position blocks new entry."
      );

      return false;
   }

   // --------------------------------------------------
   // DAILY TRADE LIMIT
   // --------------------------------------------------

   int dailyTrades =
      PFLS_ExecutionCountToday();

   if(dailyTrades < 0)
   {
      Print(
         "PFLS: Unable to verify daily trade count."
      );

      return false;
   }

   if(dailyTrades >= PFLS_MaxTradesPerDay)
   {
      Print(
         "PFLS: Daily trade limit reached."
      );

      return false;
   }

   // --------------------------------------------------
   // VOLUME VALIDATION
   // --------------------------------------------------

   if(!PFLS_ExecutionValidateVolume())
      return false;

   // --------------------------------------------------
   // CURRENT MARKET PRICE
   // --------------------------------------------------

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   if(tick.bid <= 0.0 ||
      tick.ask <= 0.0)
   {
      return false;
   }

   double point = SymbolInfoDouble(
      _Symbol,
      SYMBOL_POINT
   );

   if(point <= 0.0)
      return false;

   double entryPrice =
      isBuy ? tick.ask : tick.bid;

   double stopLoss = 0.0;
   double takeProfit = 0.0;

   // --------------------------------------------------
   // BUY PRICE STRUCTURE
   // --------------------------------------------------

   if(isBuy)
   {
      stopLoss =
         entryZone.lower -
         PFLS_StopBufferPoints * point;

      takeProfit = targetZone.lower;

      if(stopLoss >= entryPrice ||
         takeProfit <= entryPrice)
      {
         Print(
            "PFLS: Invalid BUY price structure."
         );

         return false;
      }
   }

   // --------------------------------------------------
   // SELL PRICE STRUCTURE
   // --------------------------------------------------

   else
   {
      stopLoss =
         entryZone.upper +
         PFLS_StopBufferPoints * point;

      takeProfit = targetZone.upper;

      if(stopLoss <= entryPrice ||
         takeProfit >= entryPrice)
      {
         Print(
            "PFLS: Invalid SELL price structure."
         );

         return false;
      }
   }

   // --------------------------------------------------
   // NORMALIZE LEVELS
   // --------------------------------------------------

   stopLoss =
      PFLS_NormalizeTradePrice(stopLoss);

   takeProfit =
      PFLS_NormalizeTradePrice(takeProfit);

   if(isBuy &&
      (stopLoss >= entryPrice ||
       takeProfit <= entryPrice))
   {
      return false;
   }

   if(!isBuy &&
      (stopLoss <= entryPrice ||
       takeProfit >= entryPrice))
   {
      return false;
   }

   // --------------------------------------------------
   // BROKER STOP DISTANCE
   // --------------------------------------------------

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

   double minimumDistance =
      requiredLevel * point;

   if(MathAbs(
      entryPrice - stopLoss
   ) < minimumDistance ||
      MathAbs(
      takeProfit - entryPrice
   ) < minimumDistance)
   {
      Print(
         "PFLS: Broker stop/freeze distance not met."
      );

      return false;
   }

   // --------------------------------------------------
   // CASH RISK CALCULATION
   // --------------------------------------------------

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
      Print(
         "PFLS: Risk calculation failed."
      );

      return false;
   }

   estimatedLoss = MathAbs(estimatedLoss);

   double equity =
      AccountInfoDouble(ACCOUNT_EQUITY);

   if(equity <= 0.0)
      return false;

   double maximumLoss =
      equity * PFLS_MaxRiskPercent / 100.0;

   if(estimatedLoss > maximumLoss)
   {
      Print(
         "PFLS: Estimated loss exceeds risk limit."
      );

      return false;
   }

   // --------------------------------------------------
   // FREE MARGIN VALIDATION
   // --------------------------------------------------

   double requiredMargin = 0.0;

   if(!OrderCalcMargin(
      orderType,
      _Symbol,
      PFLS_FixedLots,
      entryPrice,
      requiredMargin
   ))
   {
      Print(
         "PFLS: Margin calculation failed."
      );

      return false;
   }

   if(requiredMargin >
      AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      Print(
         "PFLS: Insufficient free margin."
      );

      return false;
   }

   // --------------------------------------------------
   // PREPARE TRADE
   // --------------------------------------------------

   PFLS_Trade.SetExpertMagicNumber(
      PFLS_MagicNumber
   );

   PFLS_Trade.SetDeviationInPoints(20);

   if(!PFLS_Trade.SetTypeFillingBySymbol(_Symbol))
   {
      Print(
         "PFLS: Filling mode unavailable."
      );

      return false;
   }

   // --------------------------------------------------
   // SUBMIT ORDER
   // --------------------------------------------------

   // Record the signal before sending so a rejected
   // order cannot repeatedly trigger on the same setup.

   PFLS_LastExecutionBar = signalBarTime;

   bool submitted = false;

   if(isBuy)
   {
      submitted = PFLS_Trade.Buy(
         PFLS_FixedLots,
         _Symbol,
         0.0,
         stopLoss,
         takeProfit,
         "PFLS M5 BUY Breakout"
      );
   }
   else
   {
      submitted = PFLS_Trade.Sell(
         PFLS_FixedLots,
         _Symbol,
         0.0,
         stopLoss,
         takeProfit,
         "PFLS M5 SELL Breakout"
      );
   }

   // --------------------------------------------------
   // VERIFY SERVER RESPONSE
   // --------------------------------------------------

   uint resultCode =
      PFLS_Trade.ResultRetcode();

   bool accepted =
      resultCode == TRADE_RETCODE_DONE ||
      resultCode == TRADE_RETCODE_PLACED ||
      resultCode == TRADE_RETCODE_DONE_PARTIAL;

   if(!submitted || !accepted)
   {
      Print(
         "PFLS: Order not confirmed. Code: ",
         resultCode,
         " | ",
         PFLS_Trade.ResultRetcodeDescription()
      );

      return false;
   }

   Print(
      "PFLS: Order accepted by trade server."
   );

   Print(
      "Direction: ",
      isBuy ? "BUY" : "SELL"
   );

   Print(
      "Lots: ",
      DoubleToString(PFLS_FixedLots, 2)
   );

   Print(
      "Stop Loss: ",
      DoubleToString(stopLoss, _Digits)
   );

   Print(
      "Take Profit: ",
      DoubleToString(takeProfit, _Digits)
   );

   return true;
}

// =====================================================
// END OF PFLS EXECUTION MODULE
// VERSION 1.30
// =====================================================

#endif // PFLS_EXECUTION_MQH
