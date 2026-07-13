//+------------------------------------------------------------------+
//|                               DonchianBreakoutEA_v3B.mq5         |
//|        Donchian breakout – kiegyensúlyozott H4 verzió (V3-B)     |
//+------------------------------------------------------------------+
#property strict
#property version "3.00"

#include <Trade/Trade.mqh>

CTrade trade;

//==================================================================
// STRATÉGIA BEÁLLÍTÁSOK (V3-B: H4, Donchian 12–16 középérték)
//==================================================================

input ENUM_TIMEFRAMES InpTimeframe      = PERIOD_H4;
input int             InpDonchianPeriod = 14;
input bool            InpAllowLong      = true;
input bool            InpAllowShort     = true;

//==================================================================
// TREND SZŰRŐ (KIEGYENSÚLYOZOTT, ENYHÉN LAZÍTOTT)
//==================================================================

input bool InpUseTrendFilter   = true;
input int  InpFastEMAPeriod    = 20;
input int  InpMidEMAPeriod     = 50;
input int  InpSlowEMAPeriod    = 200;

//==================================================================
// VOLATILITÁS & BREAKOUT MINŐSÉG (ATR – ENYHÉN LAZÍTOTT)
//==================================================================

input int    InpATRPeriod           = 14;
input double InpMinATRMultiplier    = 0.3;   // v2: 0.5 → lazább
input double InpMinBreakoutRangeATR = 0.8;   // v2: 1.0 → lazább

//==================================================================
// KOCKÁZAT ÉS KEZDETI KILÉPÉS
//==================================================================

input double InpRiskPercent   = 1.00;
input double InpInitialSL_ATR = 2.00;
input double InpTakeProfit_R  = 3.00;

//==================================================================
// POZÍCIÓ MENEDZSMENT
//==================================================================

input bool   InpUseBreakEven       = true;
input double InpBreakEvenAt_R      = 1.00;
input int    InpBreakEvenOffsetPts = 0;

input bool   InpUseTrailingStop = true;
input double InpTrailingStart_R = 1.50;
input double InpTrailingATR     = 2.00;

//==================================================================
// VÉGREHAJTÁSI BEÁLLÍTÁSOK
//==================================================================

input long InpMagicNumber     = 50030003;
input int  InpDeviationPoints = 20;
input bool InpOnePositionOnly = true;

//==================================================================
// BELSŐ ÁLLAPOT
//==================================================================

datetime g_lastBarTime   = 0;
int      g_fastEMAHandle = INVALID_HANDLE;
int      g_midEMAHandle  = INVALID_HANDLE;
int      g_slowEMAHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpDonchianPeriod < 2 ||
      InpATRPeriod < 2 ||
      InpFastEMAPeriod < 2 ||
      InpMidEMAPeriod < 2 ||
      InpSlowEMAPeriod < 2 ||
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

   g_fastEMAHandle = iMA(_Symbol, InpTimeframe, InpFastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_midEMAHandle  = iMA(_Symbol, InpTimeframe, InpMidEMAPeriod,  0, MODE_EMA, PRICE_CLOSE);
   g_slowEMAHandle = iMA(_Symbol, InpTimeframe, InpSlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(g_fastEMAHandle == INVALID_HANDLE ||
      g_midEMAHandle  == INVALID_HANDLE ||
      g_slowEMAHandle == INVALID_HANDLE)
   {
      PrintFormat("EMA handle creation failed. Error=%d", GetLastError());
      return INIT_FAILED;
   }

   g_lastBarTime = iTime(_Symbol, InpTimeframe, 0);

   PrintFormat(
      "DonchianBreakoutEA_v3B initialized: symbol=%s timeframe=%s Donchian=%d FastEMA=%d MidEMA=%d SlowEMA=%d",
      _Symbol,
      EnumToString(InpTimeframe),
      InpDonchianPeriod,
      InpFastEMAPeriod,
      InpMidEMAPeriod,
      InpSlowEMAPeriod
   );

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_fastEMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_fastEMAHandle);
   if(g_midEMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_midEMAHandle);
   if(g_slowEMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_slowEMAHandle);

   g_fastEMAHandle = INVALID_HANDLE;
   g_midEMAHandle  = INVALID_HANDLE;
   g_slowEMAHandle = INVALID_HANDLE;
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
//| Detect new candle                                                 |
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
//| Check Donchian breakout signal                                    |
//+------------------------------------------------------------------+
void CheckForEntry()
{
   if(InpOnePositionOnly && HasAnyPositionOnSymbol())
      return;

   if(FindOurPosition() != 0)
      return;

   int requiredBars = MathMax(
      InpDonchianPeriod + 5,
      MathMax(InpATRPeriod + 5, InpSlowEMAPeriod + 5)
   );

   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   if(CopyRates(_Symbol, InpTimeframe, 0, requiredBars, rates) < requiredBars)
   {
      Print("Not enough historical bars.");
      return;
   }

   // Donchian channel (use previous bars, avoid current forming bar)
   double channelHigh = rates[2].high;
   double channelLow  = rates[2].low;

   for(int i = 3; i <= InpDonchianPeriod + 1; i++)
   {
      if(rates[i].high > channelHigh)
         channelHigh = rates[i].high;
      if(rates[i].low < channelLow)
         channelLow = rates[i].low;
   }

   double signalClose = rates[1].close;

   // Kiegyensúlyozott trend filter (enyhébb, de még irányt tart)
   bool longTrendAllowed  = true;
   bool shortTrendAllowed = true;

   if(InpUseTrendFilter)
   {
      double fastEMA = GetEMAValue(g_fastEMAHandle, 1);
      double midEMA  = GetEMAValue(g_midEMAHandle,  1);
      double slowEMA = GetEMAValue(g_slowEMAHandle, 1);

      if(fastEMA <= 0.0 || midEMA <= 0.0 || slowEMA <= 0.0)
      {
         Print("EMA values unavailable.");
         return;
      }

      // V2: szigorú alignment (fast > mid > slow)
      // V3-B: lazított – elég, ha fastEMA a slow fölött van és az ár a fast fölött
      longTrendAllowed =
         (signalClose > fastEMA) &&
         (fastEMA > slowEMA);

      shortTrendAllowed =
         (signalClose < fastEMA) &&
         (fastEMA < slowEMA);

      // opcionális: midEMA csak "soft" megerősítés, nem kötelező
      // ha nagyon akarod szigorítani, visszateheted a midEMA feltételt
   }

   bool longSignal =
      InpAllowLong &&
      signalClose > channelHigh &&
      longTrendAllowed;

   bool shortSignal =
      InpAllowShort &&
      signalClose < channelLow &&
      shortTrendAllowed;

   if(!longSignal && !shortSignal)
      return;

   // Volatility filter (ATR – lazább küszöbök)
   double atr = CalculateATR(1, InpATRPeriod);
   if(atr <= 0.0)
   {
      Print("ATR calculation failed.");
      return;
   }

   // Breakout candle quality vs ATR
   double breakoutRange =
      rates[1].high - rates[1].low;

   if(breakoutRange < atr * InpMinBreakoutRangeATR)
   {
      PrintFormat("Breakout candle too small: range=%.5f ATR=%.5f", breakoutRange, atr);
      return;
   }

   // Average range vs ATR (dead market szűrés lazítva)
   double avgRange = 0.0;
   int rangeBars = MathMin(InpATRPeriod, requiredBars - 2);
   for(int i = 1; i <= rangeBars; i++)
      avgRange += (rates[i].high - rates[i].low);
   avgRange /= (double)rangeBars;

   if(atr < avgRange * InpMinATRMultiplier)
   {
      PrintFormat("ATR too low vs avg range: ATR=%.5f AvgRange=%.5f", atr, avgRange);
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("SymbolInfoTick failed.");
      return;
   }

   if(longSignal)
   {
      OpenPosition(
         ORDER_TYPE_BUY,
         tick.ask,
         atr
      );
   }
   else if(shortSignal)
   {
      OpenPosition(
         ORDER_TYPE_SELL,
         tick.bid,
         atr
      );
   }
}

//+------------------------------------------------------------------+
//| Get EMA value                                                     |
//+------------------------------------------------------------------+
double GetEMAValue(const int handle, const int shift)
{
   if(handle == INVALID_HANDLE)
      return 0.0;

   double emaBuffer[];
   ArraySetAsSeries(emaBuffer, true);

   ResetLastError();

   if(CopyBuffer(handle, 0, shift, 1, emaBuffer) != 1)
   {
      PrintFormat("EMA CopyBuffer failed. Error=%d", GetLastError());
      return 0.0;
   }

   return emaBuffer[0];
}

//+------------------------------------------------------------------+
//| Open position                                                     |
//+------------------------------------------------------------------+
void OpenPosition(
   const ENUM_ORDER_TYPE orderType,
   const double entryPrice,
   const double atr
)
{
   bool isBuy = (orderType == ORDER_TYPE_BUY);

   double initialRiskDistance = atr * InpInitialSL_ATR;

   double stopLoss = isBuy
      ? entryPrice - initialRiskDistance
      : entryPrice + initialRiskDistance;

   stopLoss = AdjustInitialStop(orderType, stopLoss);

   double actualRiskDistance = MathAbs(entryPrice - stopLoss);
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

   double volume = CalculateRiskVolume(orderType, entryPrice, stopLoss);
   if(volume <= 0.0)
   {
      Print("Calculated volume is invalid.");
      return;
   }

   string comment = StringFormat(
      "Donchian_v3B %d FastEMA %d MidEMA %d SlowEMA %d",
      InpDonchianPeriod,
      InpFastEMAPeriod,
      InpMidEMAPeriod,
      InpSlowEMAPeriod
   );

   bool requestSent = false;

   if(isBuy)
   {
      requestSent = trade.Buy(
         volume,
         _Symbol,
         0.0,
         stopLoss,
         takeProfit,
         comment
      );
   }
   else
   {
      requestSent = trade.Sell(
         volume,
         _Symbol,
         0.0,
         stopLoss,
         takeProfit,
         comment
      );
   }

   if(!requestSent || !IsTradeRetcodeSuccessful())
   {
      PrintFormat(
         "Entry failed. Retcode=%u, description=%s",
         trade.ResultRetcode(),
         trade.ResultRetcodeDescription()
      );
      return;
   }

   PrintFormat(
      "%s opened: volume=%.2f entry=%.5f SL=%.5f TP=%.5f",
      isBuy ? "BUY" : "SELL",
      volume,
      trade.ResultPrice(),
      stopLoss,
      takeProfit
   );
}

//+------------------------------------------------------------------+
//| Manage open position                                              |
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   ulong ticket = FindOurPosition();
   if(ticket == 0)
      return;

   if(!PositionSelectByTicket(ticket))
      return;

   ENUM_POSITION_TYPE positionType =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL  = PositionGetDouble(POSITION_SL);
   double takeProfit = PositionGetDouble(POSITION_TP);

   if(openPrice <= 0.0 || takeProfit <= 0.0)
      return;

   double initialRiskDistance =
      MathAbs(takeProfit - openPrice) / InpTakeProfit_R;

   if(initialRiskDistance <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   bool isBuy = (positionType == POSITION_TYPE_BUY);

   double currentPrice = isBuy ? tick.bid : tick.ask;

   double profitDistance = isBuy
      ? currentPrice - openPrice
      : openPrice - currentPrice;

   if(profitDistance <= 0.0)
      return;

   double candidateSL = currentSL;
   bool shouldModify  = false;

   // Break-even
   if(InpUseBreakEven &&
      profitDistance >= initialRiskDistance * InpBreakEvenAt_R)
   {
      double offset =
         InpBreakEvenOffsetPts *
         SymbolInfoDouble(_Symbol, SYMBOL_POINT);

      double breakEvenSL = isBuy
         ? openPrice + offset
         : openPrice - offset;

      if(IsBetterStop(isBuy, breakEvenSL, candidateSL))
      {
         candidateSL = breakEvenSL;
         shouldModify = true;
      }
   }

   // ATR trailing stop
   if(InpUseTrailingStop &&
      profitDistance >= initialRiskDistance * InpTrailingStart_R)
   {
      double atr = CalculateATR(1, InpATRPeriod);
      if(atr > 0.0)
      {
         double trailingSL = isBuy
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
      PrintFormat(
         "Position modification failed. Ticket=%I64u Retcode=%u Description=%s",
         ticket,
         trade.ResultRetcode(),
         trade.ResultRetcodeDescription()
      );
      return;
   }

   PrintFormat(
      "Stop-loss moved: ticket=%I64u oldSL=%.5f newSL=%.5f",
      ticket,
      currentSL,
      candidateSL
   );
}

//+------------------------------------------------------------------+
//| Calculate ATR                                                     |
//+------------------------------------------------------------------+
double CalculateATR(const int shift, const int period)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   int requiredBars = shift + period + 1;

   if(CopyRates(_Symbol, InpTimeframe, 0, requiredBars, rates) < requiredBars)
      return 0.0;

   double trueRangeSum = 0.0;

   for(int i = shift; i < shift + period; i++)
   {
      double highLow   = rates[i].high - rates[i].low;
      double highClose = MathAbs(rates[i].high - rates[i + 1].close);
      double lowClose  = MathAbs(rates[i].low  - rates[i + 1].close);

      trueRangeSum += MathMax(highLow, MathMax(highClose, lowClose));
   }

   return trueRangeSum / period;
}

//+------------------------------------------------------------------+
//| Calculate position size                                           |
//+------------------------------------------------------------------+
double CalculateRiskVolume(
   const ENUM_ORDER_TYPE orderType,
   const double entryPrice,
   const double stopLoss
)
{
   double accountBalance =
      AccountInfoDouble(ACCOUNT_BALANCE);

   double riskMoney =
      accountBalance * InpRiskPercent / 100.0;

   double profitForOneLot = 0.0;

   if(!OrderCalcProfit(
      orderType,
      _Symbol,
      1.0,
      entryPrice,
      stopLoss,
      profitForOneLot
   ))
   {
      PrintFormat(
         "OrderCalcProfit failed. Error=%d",
         GetLastError()
      );
      return 0.0;
   }

   double lossForOneLot = MathAbs(profitForOneLot);
   if(lossForOneLot <= 0.0)
      return 0.0;

   double rawVolume = riskMoney / lossForOneLot;

   return NormalizeVolume(rawVolume);
}

//+------------------------------------------------------------------+
//| Normalize volume                                                  |
//+------------------------------------------------------------------+
double NormalizeVolume(const double rawVolume)
{
   double minVolume =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVolume =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volumeStep =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minVolume <= 0.0 ||
      maxVolume <= 0.0 ||
      volumeStep <= 0.0)
      return 0.0;

   if(rawVolume < minVolume)
   {
      PrintFormat(
         "Required volume %.4f is below broker minimum %.4f.",
         rawVolume,
         minVolume
      );
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
//| Find EA position                                                  |
//+------------------------------------------------------------------+
ulong FindOurPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long   magic  = PositionGetInteger(POSITION_MAGIC);

      if(symbol == _Symbol && magic == InpMagicNumber)
         return ticket;
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Check for any position on current symbol                          |
//+------------------------------------------------------------------+
bool HasAnyPositionOnSymbol()
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

//+------------------------------------------------------------------+
//| Check whether proposed stop is better                             |
//+------------------------------------------------------------------+
bool IsBetterStop(
   const bool isBuy,
   const double proposedSL,
   const double referenceSL
)
{
   double tickSize =
      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(referenceSL == 0.0)
      return true;

   if(isBuy)
      return proposedSL > referenceSL + tickSize * 0.5;

   return proposedSL < referenceSL - tickSize * 0.5;
}

//+------------------------------------------------------------------+
//| Adjust initial stop                                               |
//+------------------------------------------------------------------+
double AdjustInitialStop(
   const ENUM_ORDER_TYPE orderType,
   const double proposedSL
)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return proposedSL;

   double minDistance = GetMinimumStopDistance();

   if(orderType == ORDER_TYPE_BUY)
      return MathMin(proposedSL, tick.bid - minDistance);

   return MathMax(proposedSL, tick.ask + minDistance);
}

//+------------------------------------------------------------------+
//| Adjust managed stop                                               |
//+------------------------------------------------------------------+
double AdjustManagedStop(
   const bool isBuy,
   const double proposedSL,
   const MqlTick &tick
)
{
   double minDistance = GetMinimumStopDistance();

   if(isBuy)
      return MathMin(proposedSL, tick.bid - minDistance);

   return MathMax(proposedSL, tick.ask + minDistance);
}

//+------------------------------------------------------------------+
//| Minimum stop distance                                             |
//+------------------------------------------------------------------+
double GetMinimumStopDistance()
{
   double point =
      SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   long stopsLevel =
      SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel =
      SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   long requiredPoints = MathMax(stopsLevel, freezeLevel);

   return requiredPoints * point;
}

//+------------------------------------------------------------------+
//| Normalize price                                                   |
//+------------------------------------------------------------------+
double NormalizePrice(const double price)
{
   double tickSize =
      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int digits =
      (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(tickSize <= 0.0)
      return NormalizeDouble(price, digits);

   double normalized =
      MathRound(price / tickSize) * tickSize;

   return NormalizeDouble(normalized, digits);
}

//+------------------------------------------------------------------+
//| Check trade result                                                |
//+------------------------------------------------------------------+
bool IsTradeRetcodeSuccessful()
{
   uint retcode = trade.ResultRetcode();

   return
      retcode == TRADE_RETCODE_DONE ||
      retcode == TRADE_RETCODE_DONE_PARTIAL ||
      retcode == TRADE_RETCODE_PLACED;
}
//+------------------------------------------------------------------+
