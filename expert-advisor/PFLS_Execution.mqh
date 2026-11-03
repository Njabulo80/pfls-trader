
#ifndef PFLS_EXECUTION_MQH
#define PFLS_EXECUTION_MQH

#include "PFLS_Zones.mqh"
#include <Trade/Trade.mqh>

// =====================================================
// PFLS TRADER - EXECUTION MODULE
// Version 1.60
// TICK-BASED M5 REJECTION + BREAKOUT
// EXPLICIT PENDING SIGNAL MONITORING
// =====================================================

// -----------------------------------------------------
// EXECUTION SETTINGS
// -----------------------------------------------------

input bool PFLS_EnableExecution = false;
input bool PFLS_EmergencyStop = false;

input double PFLS_FixedLots = 0.01;
input double PFLS_MaxRiskPercent = 3.0;
input double PFLS_MinRewardRisk = 1.2;
input int PFLS_MaxTradesPerDay = 2;

input ulong PFLS_MagicNumber = 751103;
input int PFLS_StopBufferPoints = 20;

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
bool PFLS_PendingBreakoutConfirmed = false;

PFLSZoneRecord PFLS_PendingEntryZone;

// =====================================================
// PRICE NORMALIZATION
// =====================================================

double PFLS_NormalizeTradePrice(double price)
{
   double tickSize = SymbolInfoDouble(
      _Symbol, SYMBOL_TRADE_TICK_SIZE
   );

   int digits = (int)SymbolInfoInteger(
      _Symbol, SYMBOL_DIGITS
   );

   if(tickSize <= 0.0)
      return NormalizeDouble(price, digits);

   return NormalizeDouble(
      MathRound(price / tickSize) * tickSize,
      digits
   );
}

// =====================================================
// RESET PENDING SIGNAL
// =====================================================

void PFLS_ExecutionResetPending()
{
   PFLS_PendingRejectionTime = 0;

   PFLS_PendingRejectionHigh = 0.0;
   PFLS_PendingRejectionLow = 0.0;

   PFLS_PendingBuy = false;
   PFLS_PendingSell = false;

   PFLS_PendingBreakoutConfirmed = false;

   PFLSZ_Reset(PFLS_PendingEntryZone);
}

// =====================================================
// CHECK FOR ACTIVE PENDING SIGNAL
// Used by Engine v1.70.
// =====================================================

bool PFLS_ExecutionHasPendingSignal()
{
   if(PFLS_PendingRejectionTime <= 0)
      return false;

   if(PFLS_PendingBuy == PFLS_PendingSell)
      return false;

   if(PFLS_PendingRejectionHigh <=
      PFLS_PendingRejectionLow)
      return false;

   if(!PFLS_PendingEntryZone.valid ||
      PFLS_PendingEntryZone.invalidated)
      return false;

   return true;
}

// =====================================================
// CONSUME CONFIRMED SIGNAL
// Called by Engine after its decision.
// =====================================================

void PFLS_ExecutionConsumeSignal(datetime signalTime)
{
   if(signalTime <= 0)
      return;

   PFLS_LastProcessedRejectionBar = signalTime;

   PFLS_ExecutionResetPending();

   Print(
      "PFLS: Signal consumed: ",
      TimeToString(signalTime, TIME_DATE | TIME_MINUTES)
   );
}

// =====================================================
// M5 REJECTION VALIDATION
// =====================================================

bool PFLS_ExecutionIsBullishRejection(MqlRates &candle)
{
   double body = MathAbs(candle.close - candle.open);

   double lowerWick =
      MathMin(candle.open, candle.close) - candle.low;

   if(body <= 0.0)
      return false;

   return (
      candle.close > candle.open &&
      lowerWick >= body * 0.5
   );
}

bool PFLS_ExecutionIsBearishRejection(MqlRates &candle)
{
   double body = MathAbs(candle.close - candle.open);

   double upperWick =
      candle.high - MathMax(candle.open, candle.close);

   if(body <= 0.0)
      return false;

   return (
      candle.close < candle.open &&
      upperWick >= body * 0.5
   );
}

// =====================================================
// M5 SIGNAL ENGINE
//
// Detects rejection at a valid M5 zone.
// Requires breakout during immediately following M5 bar.
// =====================================================

bool PFLS_ExecutionGetM5Signal(
   PFLSZoneRecord &demand,
   PFLSZoneRecord &supply,
   bool &isBuy,
   datetime &signalBarTime,
   PFLSZoneRecord &entryZone
)
{
   isBuy = false;
   signalBarTime = 0;

   PFLSZ_Reset(entryZone);

   datetime currentBarOpen = iTime(
      _Symbol, PERIOD_M5, 0
   );

   if(currentBarOpen <= 0)
      return false;

   int periodSeconds = PeriodSeconds(PERIOD_M5);

   if(periodSeconds <= 0)
      return false;

   // --------------------------------------------------
   // EXISTING PENDING REJECTION
   // --------------------------------------------------

   if(PFLS_PendingRejectionTime > 0)
   {
      datetime expectedBreakoutBar =
         PFLS_PendingRejectionTime + periodSeconds;

      // Expire after the immediate next M5 candle.
      if(currentBarOpen > expectedBreakoutBar)
      {
         Print("PFLS: Pending M5 rejection expired.");

         PFLS_LastProcessedRejectionBar =
            PFLS_PendingRejectionTime;

         PFLS_ExecutionResetPending();

         return false;
      }

      // Wait until the exact next M5 candle.
      if(currentBarOpen != expectedBreakoutBar)
         return false;

      MqlTick tick;

      if(!SymbolInfoTick(_Symbol, tick))
         return false;

      if(tick.bid <= 0.0 || tick.ask <= 0.0)
         return false;

      // ------------------------------------------------
      // BREAKOUT CONFIRMATION
      // ------------------------------------------------

      if(!PFLS_PendingBreakoutConfirmed)
      {
         if(PFLS_PendingBuy &&
            tick.ask > PFLS_PendingRejectionHigh)
         {
            PFLS_PendingBreakoutConfirmed = true;

            Print("PFLS: BUY breakout confirmed.");
         }
         else if(PFLS_PendingSell &&
                 tick.bid < PFLS_PendingRejectionLow)
         {
            PFLS_PendingBreakoutConfirmed = true;

            Print("PFLS: SELL breakout confirmed.");
         }
      }

      if(!PFLS_PendingBreakoutConfirmed)
         return false;

      isBuy = PFLS_PendingBuy;

      signalBarTime = PFLS_PendingRejectionTime;

      entryZone = PFLS_PendingEntryZone;

      return true;
   }

   // --------------------------------------------------
   // MOST RECENT COMPLETED M5 CANDLE
   // --------------------------------------------------

   MqlRates candle[];

   ArraySetAsSeries(candle, true);

   if(CopyRates(
      _Symbol,
      PERIOD_M5,
      1,
      1,
      candle
   ) != 1)
      return false;

   datetime rejectionTime = candle[0].time;

   if(rejectionTime <= PFLS_LastProcessedRejectionBar ||
      rejectionTime <= PFLS_LastExecutionBar)
      return false;

   // --------------------------------------------------
   // ZONE OVERLAP
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

   if(overlapsDemand && overlapsSupply)
      return false;

   // --------------------------------------------------
   // BULLISH REJECTION
   // --------------------------------------------------

   if(overlapsDemand &&
      PFLS_ExecutionIsBullishRejection(candle[0]))
   {
      PFLS_PendingBuy = true;
      PFLS_PendingSell = false;

      PFLS_PendingRejectionTime = rejectionTime;

      PFLS_PendingRejectionHigh = candle[0].high;
      PFLS_PendingRejectionLow = candle[0].low;

      PFLS_PendingEntryZone = demand;

      PFLS_PendingBreakoutConfirmed = false;

      Print(
         "PFLS: Bullish M5 rejection recorded. "
         "Monitoring next-candle breakout."
      );

      return false;
   }

   // --------------------------------------------------
   // BEARISH REJECTION
   // --------------------------------------------------

   if(overlapsSupply &&
      PFLS_ExecutionIsBearishRejection(candle[0]))
   {
      PFLS_PendingSell = true;
      PFLS_PendingBuy = false;

      PFLS_PendingRejectionTime = rejectionTime;

      PFLS_PendingRejectionHigh = candle[0].high;
      PFLS_PendingRejectionLow = candle[0].low;

      PFLS_PendingEntryZone = supply;

      PFLS_PendingBreakoutConfirmed = false;

      Print(
         "PFLS: Bearish M5 rejection recorded. "
         "Monitoring next-candle breakout."
      );

      return false;
   }

   return false;
}

// =====================================================
// COUNT DISTINCT ENTRY ORDERS TODAY
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
         deal, DEAL_SYMBOL
      ) != _Symbol)
         continue;

      if((ulong)HistoryDealGetInteger(
         deal, DEAL_MAGIC
      ) != PFLS_MagicNumber)
         continue;

      ENUM_DEAL_ENTRY entry =
         (ENUM_DEAL_ENTRY)HistoryDealGetInteger(
            deal, DEAL_ENTRY
         );

      if(entry != DEAL_ENTRY_IN &&
         entry != DEAL_ENTRY_INOUT)
         continue;

      ulong orderTicket =
         (ulong)HistoryDealGetInteger(
            deal, DEAL_ORDER
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

      if(PositionGetString(POSITION_SYMBOL) == _Symbol)
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
      _Symbol, SYMBOL_VOLUME_MIN
   );

   double maximum = SymbolInfoDouble(
      _Symbol, SYMBOL_VOLUME_MAX
   );

   double step = SymbolInfoDouble(
      _Symbol, SYMBOL_VOLUME_STEP
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
   if(!PFLS_EnableExecution)
      return false;

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
      signalBarTime <= PFLS_LastExecutionBar)
      return false;

   if(PFLS_FixedLots != 0.01 ||
      PFLS_MaxRiskPercent <= 0.0 ||
      PFLS_MaxRiskPercent > 3.0 ||
      PFLS_MinRewardRisk < 1.0 ||
      PFLS_MinRewardRisk > 5.0 ||
      PFLS_MaxTradesPerDay < 1 ||
      PFLS_MaxTradesPerDay > 2 ||
      PFLS_StopBufferPoints < 1)
   {
      Print("PFLS: Unsafe execution configuration.");
      return false;
   }

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

   if(PFLS_ExecutionHasOpenPosition())
   {
      Print("PFLS: Existing position blocks new entry.");
      return false;
   }

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

   if(!PFLS_ExecutionValidateVolume())
      return false;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   if(tick.bid <= 0.0 || tick.ask <= 0.0)
      return false;

   double point = SymbolInfoDouble(
      _Symbol, SYMBOL_POINT
   );

   if(point <= 0.0)
      return false;

   double entryPrice = isBuy ? tick.ask : tick.bid;

   double stopLoss = 0.0;
   double takeProfit = 0.0;

   if(isBuy)
   {
      stopLoss =
         entryZone.lower - PFLS_StopBufferPoints * point;

      takeProfit = targetZone.lower;

      if(stopLoss >= entryPrice ||
         takeProfit <= entryPrice)
      {
         Print("PFLS: Invalid BUY price structure.");
         return false;
      }
   }
   else
   {
      stopLoss =
         entryZone.upper + PFLS_StopBufferPoints * point;

      takeProfit = targetZone.upper;

      if(stopLoss <= entryPrice ||
         takeProfit >= entryPrice)
      {
         Print("PFLS: Invalid SELL price structure.");
         return false;
      }
   }

   stopLoss = PFLS_NormalizeTradePrice(stopLoss);
   takeProfit = PFLS_NormalizeTradePrice(takeProfit);

   if(isBuy &&
      (stopLoss >= entryPrice || takeProfit <= entryPrice))
      return false;

   if(!isBuy &&
      (stopLoss <= entryPrice || takeProfit >= entryPrice))
      return false;

   long stopsLevel = SymbolInfoInteger(
      _Symbol, SYMBOL_TRADE_STOPS_LEVEL
   );

   long freezeLevel = SymbolInfoInteger(
      _Symbol, SYMBOL_TRADE_FREEZE_LEVEL
   );

   long requiredLevel = (long)MathMax(
      stopsLevel, freezeLevel
   );

   double minimumDistance = requiredLevel * point;

   if(MathAbs(entryPrice - stopLoss) < minimumDistance ||
      MathAbs(takeProfit - entryPrice) < minimumDistance)
   {
      Print("PFLS: Broker stop/freeze distance not met.");
      return false;
   }

   // --------------------------------------------------
   // ESTIMATED RISK AND REWARD
   // --------------------------------------------------

   ENUM_ORDER_TYPE orderType =
      isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   double estimatedLoss = 0.0;
   double estimatedReward = 0.0;

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

   if(!OrderCalcProfit(
      orderType,
      _Symbol,
      PFLS_FixedLots,
      entryPrice,
      takeProfit,
      estimatedReward
   ))
   {
      Print("PFLS: Reward calculation failed.");
      return false;
   }

   estimatedLoss = MathAbs(estimatedLoss);

   if(estimatedLoss <= 0.0 ||
      estimatedReward <= 0.0)
   {
      Print("PFLS: Invalid calculated risk or reward.");
      return false;
   }

   double rewardRisk =
      estimatedReward / estimatedLoss;

   if(rewardRisk < PFLS_MinRewardRisk)
   {
      Print(
         "PFLS: Reward-to-risk below minimum. Ratio: ",
         DoubleToString(rewardRisk, 2)
      );

      return false;
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(equity <= 0.0)
      return false;

   double maximumLoss =
      equity * PFLS_MaxRiskPercent / 100.0;

   if(estimatedLoss > maximumLoss)
   {
      Print("PFLS: Estimated loss exceeds risk limit.");
      return false;
   }

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

   // --------------------------------------------------
   // SUBMIT ORDER
   // --------------------------------------------------

   PFLS_Trade.SetExpertMagicNumber(PFLS_MagicNumber);
   PFLS_Trade.SetDeviationInPoints(20);

   if(!PFLS_Trade.SetTypeFillingBySymbol(_Symbol))
   {
      Print("PFLS: Filling mode unavailable.");
      return false;
   }

   // Prevent duplicate submissions for this signal.
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

   uint resultCode = PFLS_Trade.ResultRetcode();

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
      "PFLS: Trade request accepted. Direction: ",
      isBuy ? "BUY" : "SELL",
      " | Lots: ",
      DoubleToString(PFLS_FixedLots, 2),
      " | Estimated R:R: ",
      DoubleToString(rewardRisk, 2),
      " | SL: ",
      DoubleToString(stopLoss, _Digits),
      " | TP: ",
      DoubleToString(takeProfit, _Digits)
   );

   return true;
}

#endif
