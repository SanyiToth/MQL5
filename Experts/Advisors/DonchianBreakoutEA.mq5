//+------------------------------------------------------------------+
//|                                      DonchianBreakoutEA.mq5       |
//|                         Mechanical Donchian breakout strategy      |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Donchian breakout EA with risk-based sizing, ATR SL, TP, break-even and ATR trailing stop."

#include <Trade/Trade.mqh>

CTrade trade;

//--- Strategy settings
input ENUM_TIMEFRAMES InpTimeframe          = PERIOD_D1;
input int             InpDonchianPeriod     = 20;
input bool            InpAllowLong          = true;
input bool            InpAllowShort         = true;

//--- Risk and initial exit settings
input double          InpRiskPercent        = 1.00;
input int             InpATRPeriod          = 14;
input double          InpInitialSL_ATR       = 2.00;
input double          InpTakeProfit_R        = 3.00;

//--- Position management
input bool            InpUseBreakEven       = true;
input double          InpBreakEvenAt_R       = 1.00;
input int             InpBreakEvenOffsetPts = 0;

input bool            InpUseTrailingStop     = true;
input double          InpTrailingStart_R     = 1.50;
input double          InpTrailingATR         = 2.00;

//--- Execution settings
input long            InpMagicNumber         = 50020001;
input int             InpDeviationPoints     = 20;
input bool            InpOnePositionOnly     = true;

//--- Internal state
datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpDonchianPeriod < 2 ||
      InpATRPeriod < 2 ||
      InpRiskPercent <= 0.0 ||
      InpInitialSL_ATR <= 0.0 ||
      InpTakeProfit_R <= 0.0)
   {
      Print("Invalid input parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();

   g_lastBarTime = iTime(_Symbol, InpTimeframe, 0);

   PrintFormat("DonchianBreakoutEA initialized: symbol=%s timeframe=%s",
               _Symbol, EnumToString(InpTimeframe));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Main tick handler                                                 |
//+------------------------------------------------------------------+
void OnTick()
{
   ManageOpenPosition();

   if(IsNewBar())
      CheckForEntry();
}

//+------------------------------------------------------------------+
//| Detect a newly opened bar                                         |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);

   if(currentBarTime <= 0)
      return false;

   if(currentBarTime != g_lastBarTime)
   {
      g_lastBarTime = currentBarTime;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Evaluate Donchian breakout on the last closed candle              |
//+------------------------------------------------------------------+
void CheckForEntry()
{
   if(InpOnePositionOnly && HasAnyPositionOnSymbol())
      return;

   if(FindOurPosition() != 0)
      return;

   const int requiredBars = MathMax(InpDonchianPeriod + 3,
                                    InpATRPeriod + 3);

   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   if(CopyRates(_Symbol, InpTimeframe, 0, requiredBars, rates) < requiredBars)
   {
      Print("Not enough historical bars for signal calculation.");
      return;
   }

   // Signal candle: rates[1].
   // Donchian channel: preceding closed candles rates[2] ... rates[N+1].
   double channelHigh = rates[2].high;
   double channelLow  = rates[2].low;

   for(int i = 3; i <= InpDonchianPeriod + 1; i++)
   {
      if(rates[i].high > channelHigh)
         channelHigh = rates[i].high;

      if(rates[i].low < channelLow)
         channelLow = rates[i].low;
   }

   const double signalClose = rates[1].close;
   const bool longSignal  = InpAllowLong  && signalClose > channelHigh;
   const bool shortSignal = InpAllowShort && signalClose < channelLow;

   if(!longSignal && !shortSignal)
      return;

   const double atr = CalculateATR(1, InpATRPeriod);
   if(atr <= 0.0)
   {
      Print("ATR calculation failed.");
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("SymbolInfoTick failed.");
      return;
   }

   if(longSignal)
      OpenPosition(ORDER_TYPE_BUY, tick.ask, atr, channelHigh, channelLow);
   else if(shortSignal)
      OpenPosition(ORDER_TYPE_SELL, tick.bid, atr, channelHigh, channelLow);
}

//+------------------------------------------------------------------+
//| Open a market position                                            |
//+------------------------------------------------------------------+
void OpenPosition(const ENUM_ORDER_TYPE orderType,
                  const double entryPrice,
                  const double atr,
                  const double channelHigh,
                  const double channelLow)
{
   const bool isBuy = (orderType == ORDER_TYPE_BUY);
   const double initialRiskDistance = atr * InpInitialSL_ATR;

   double stopLoss = isBuy
                     ? entryPrice - initialRiskDistance
                     : entryPrice + initialRiskDistance;

   stopLoss = AdjustInitialStop(orderType, stopLoss);

   const double actualRiskDistance = MathAbs(entryPrice - stopLoss);
   if(actualRiskDistance <= 0.0)
   {
      Print("Invalid initial stop-loss distance.");
      return;
   }

   double takeProfit = isBuy
                       ? entryPrice + actualRiskDistance * InpTakeProfit_R
                       : entryPrice - actualRiskDistance * InpTakeProfit_R;

   stopLoss   = NormalizePrice(stopLoss);
   takeProfit = NormalizePrice(takeProfit);

   const double volume = CalculateRiskVolume(orderType, entryPrice, stopLoss);
   if(volume <= 0.0)
   {
      Print("Calculated trade volume is invalid.");
      return;
   }

   const string comment = StringFormat("Donchian %d | H=%.5f L=%.5f",
                                       InpDonchianPeriod,
                                       channelHigh,
                                       channelLow);

   bool requestSent = false;

   if(isBuy)
      requestSent = trade.Buy(volume, _Symbol, 0.0, stopLoss, takeProfit, comment);
   else
      requestSent = trade.Sell(volume, _Symbol, 0.0, stopLoss, takeProfit, comment);

   if(!requestSent || !IsTradeRetcodeSuccessful())
   {
      PrintFormat("Entry failed. retcode=%u (%s)",
                  trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
      return;
   }

   PrintFormat("%s opened: volume=%.2f entry=%.5f SL=%.5f TP=%.5f",
               isBuy ? "BUY" : "SELL",
               volume,
               trade.ResultPrice(),
               stopLoss,
               takeProfit);
}

//+------------------------------------------------------------------+
//| Manage break-even and trailing stop                               |
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   const ulong ticket = FindOurPosition();
   if(ticket == 0)
      return;

   if(!PositionSelectByTicket(ticket))
      return;

   const ENUM_POSITION_TYPE positionType =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   const double currentSL = PositionGetDouble(POSITION_SL);
   const double takeProfit = PositionGetDouble(POSITION_TP);

   if(openPrice <= 0.0 || takeProfit <= 0.0)
      return;

   // Since TP is fixed at InpTakeProfit_R, the original 1R distance can
   // be reconstructed even after the stop-loss has been moved.
   const double initialRiskDistance =
      MathAbs(takeProfit - openPrice) / InpTakeProfit_R;

   if(initialRiskDistance <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   const bool isBuy = (positionType == POSITION_TYPE_BUY);
   const double currentPrice = isBuy ? tick.bid : tick.ask;
   const double profitDistance = isBuy
                                 ? currentPrice - openPrice
                                 : openPrice - currentPrice;

   if(profitDistance <= 0.0)
      return;

   double candidateSL = currentSL;
   bool shouldModify = false;

   //--- Break-even
   if(InpUseBreakEven &&
      profitDistance >= initialRiskDistance * InpBreakEvenAt_R)
   {
      const double offset =
         InpBreakEvenOffsetPts * SymbolInfoDouble(_Symbol, SYMBOL_POINT);

      const double breakEvenSL = isBuy
                                 ? openPrice + offset
                                 : openPrice - offset;

      if(IsBetterStop(isBuy, breakEvenSL, candidateSL))
      {
         candidateSL = breakEvenSL;
         shouldModify = true;
      }
   }

   //--- ATR trailing stop
   if(InpUseTrailingStop &&
      profitDistance >= initialRiskDistance * InpTrailingStart_R)
   {
      const double atr = CalculateATR(1, InpATRPeriod);

      if(atr > 0.0)
      {
         const double trailingSL = isBuy
                                   ? currentPrice - atr * InpTrailingATR
                                   : currentPrice + atr * InpTrailingATR;

         if(IsBetterStop(isBuy, trailingSL, candidateSL))
         {
            candidateSL = trailingSL;
            shouldModify = true;
         }
      }
   }

   if(!shouldModify)
      return;

   candidateSL = AdjustManagedStop(isBuy, candidateSL, tick);
   candidateSL = NormalizePrice(candidateSL);

   if(!IsBetterStop(isBuy, candidateSL, currentSL))
      return;

   if(!trade.PositionModify(ticket, candidateSL, takeProfit) ||
      !IsTradeRetcodeSuccessful())
   {
      PrintFormat("Position modification failed. ticket=%I64u retcode=%u (%s)",
                  ticket,
                  trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
      return;
   }

   PrintFormat("Stop-loss moved: ticket=%I64u oldSL=%.5f newSL=%.5f",
               ticket, currentSL, candidateSL);
}

//+------------------------------------------------------------------+
//| Calculate ATR from closed candles                                 |
//+------------------------------------------------------------------+
double CalculateATR(const int shift, const int period)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   const int requiredBars = shift + period + 1;

   if(CopyRates(_Symbol, InpTimeframe, 0, requiredBars, rates) < requiredBars)
      return 0.0;

   double trueRangeSum = 0.0;

   for(int i = shift; i < shift + period; i++)
   {
      const double highLow = rates[i].high - rates[i].low;
      const double highClose =
         MathAbs(rates[i].high - rates[i + 1].close);
      const double lowClose =
         MathAbs(rates[i].low - rates[i + 1].close);

      trueRangeSum += MathMax(highLow, MathMax(highClose, lowClose));
   }

   return trueRangeSum / period;
}

//+------------------------------------------------------------------+
//| Risk-based position sizing using broker profit calculation        |
//+------------------------------------------------------------------+
double CalculateRiskVolume(const ENUM_ORDER_TYPE orderType,
                           const double entryPrice,
                           const double stopLoss)
{
   const double accountBalance =
      AccountInfoDouble(ACCOUNT_BALANCE);

   const double riskMoney =
      accountBalance * InpRiskPercent / 100.0;

   double profitForOneLot = 0.0;

   if(!OrderCalcProfit(orderType,
                       _Symbol,
                       1.0,
                       entryPrice,
                       stopLoss,
                       profitForOneLot))
   {
      PrintFormat("OrderCalcProfit failed. Error=%d", GetLastError());
      return 0.0;
   }

   const double lossForOneLot = MathAbs(profitForOneLot);
   if(lossForOneLot <= 0.0)
      return 0.0;

   const double rawVolume = riskMoney / lossForOneLot;
   return NormalizeVolume(rawVolume);
}

//+------------------------------------------------------------------+
//| Normalize volume to broker limits                                 |
//+------------------------------------------------------------------+
double NormalizeVolume(const double rawVolume)
{
   const double minVolume =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxVolume =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double volumeStep =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minVolume <= 0.0 || maxVolume <= 0.0 || volumeStep <= 0.0)
      return 0.0;

   if(rawVolume < minVolume)
   {
      PrintFormat("Required volume %.4f is below broker minimum %.4f.",
                  rawVolume, minVolume);
      return 0.0;
   }

   double volume = MathMin(rawVolume, maxVolume);
   volume = MathFloor(volume / volumeStep) * volumeStep;

   int volumeDigits = 0;
   double step = volumeStep;

   while(step < 1.0 && volumeDigits < 8)
   {
      step *= 10.0;
      volumeDigits++;
   }

   return NormalizeDouble(volume, volumeDigits);
}

//+------------------------------------------------------------------+
//| Find this EA's open position                                      |
//+------------------------------------------------------------------+
ulong FindOurPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      const string symbol = PositionGetString(POSITION_SYMBOL);
      const long magic = PositionGetInteger(POSITION_MAGIC);

      if(symbol == _Symbol && magic == InpMagicNumber)
         return ticket;
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Check whether any position exists on the current symbol           |
//+------------------------------------------------------------------+
bool HasAnyPositionOnSymbol()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Compare stop-loss values                                          |
//+------------------------------------------------------------------+
bool IsBetterStop(const bool isBuy,
                  const double proposedSL,
                  const double referenceSL)
{
   const double tickSize =
      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(referenceSL == 0.0)
      return true;

   if(isBuy)
      return proposedSL > referenceSL + tickSize * 0.5;

   return proposedSL < referenceSL - tickSize * 0.5;
}

//+------------------------------------------------------------------+
//| Respect minimum stop distance for a new trade                     |
//+------------------------------------------------------------------+
double AdjustInitialStop(const ENUM_ORDER_TYPE orderType,
                         const double proposedSL)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return proposedSL;

   const double minDistance = GetMinimumStopDistance();

   if(orderType == ORDER_TYPE_BUY)
      return MathMin(proposedSL, tick.bid - minDistance);

   return MathMax(proposedSL, tick.ask + minDistance);
}

//+------------------------------------------------------------------+
//| Respect minimum stop distance when modifying a position           |
//+------------------------------------------------------------------+
double AdjustManagedStop(const bool isBuy,
                         const double proposedSL,
                         const MqlTick &tick)
{
   const double minDistance = GetMinimumStopDistance();

   if(isBuy)
      return MathMin(proposedSL, tick.bid - minDistance);

   return MathMax(proposedSL, tick.ask + minDistance);
}

//+------------------------------------------------------------------+
//| Broker minimum stop/freeze distance                               |
//+------------------------------------------------------------------+
double GetMinimumStopDistance()
{
   const double point =
      SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   const long stopsLevel =
      SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   const long freezeLevel =
      SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   const long requiredPoints = MathMax(stopsLevel, freezeLevel);

   return requiredPoints * point;
}

//+------------------------------------------------------------------+
//| Normalize price to the instrument's tick size                     |
//+------------------------------------------------------------------+
double NormalizePrice(const double price)
{
   const double tickSize =
      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   const int digits =
      (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(tickSize <= 0.0)
      return NormalizeDouble(price, digits);

   const double normalized =
      MathRound(price / tickSize) * tickSize;

   return NormalizeDouble(normalized, digits);
}

//+------------------------------------------------------------------+
//| Check trade-server return code                                    |
//+------------------------------------------------------------------+
bool IsTradeRetcodeSuccessful()
{
   const uint retcode = trade.ResultRetcode();

   return retcode == TRADE_RETCODE_DONE ||
          retcode == TRADE_RETCODE_DONE_PARTIAL ||
          retcode == TRADE_RETCODE_PLACED;
}
//+------------------------------------------------------------------+
