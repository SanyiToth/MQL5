//+------------------------------------------------------------------+
//|                       DonchianBreakoutEA_v3E.mq5                 |
//| Donchian breakout H4 – DD control + ADX + breakout filters       |
//+------------------------------------------------------------------+
#property strict
#property version   "3.03"
#property description "Donchian breakout EA with dynamic risk reduction and stricter entry filters"

#include <Trade/Trade.mqh>

CTrade trade;

//==================================================================
// STRATEGY SETTINGS
//==================================================================

input ENUM_TIMEFRAMES InpTimeframe      = PERIOD_H4;
input int             InpDonchianPeriod = 16;

input bool InpAllowLong  = true;
input bool InpAllowShort = true;

//==================================================================
// EMA TREND FILTER
//==================================================================

input bool InpUseTrendFilter = true;

input int InpFastEMAPeriod = 20;
input int InpMidEMAPeriod  = 50;
input int InpSlowEMAPeriod = 200;

//==================================================================
// ADX TREND-STRENGTH FILTER
//==================================================================

input bool   InpUseADXFilter = true;
input int    InpADXPeriod    = 14;
input double InpMinADX       = 20.0;

// Long esetén +DI > -DI
// Short esetén -DI > +DI
input bool InpUseDirectionalDI = true;

//==================================================================
// VOLATILITY AND BREAKOUT FILTERS
//==================================================================

input int    InpATRPeriod           = 14;
input double InpMinATRMultiplier    = 0.40;
input double InpMinBreakoutRangeATR = 0.80;

// Túl nagy breakout-gyertyák tiltása
input double InpMaxBreakoutRangeATR = 2.00;

// A záróár legfeljebb ennyi ATR-rel lehet a Donchian-szinten túl
input double InpMaxBreakoutExtensionATR = 0.35;

//==================================================================
// RISK SETTINGS
//==================================================================

input double InpRiskPercent   = 1.00;
input double InpInitialSL_ATR = 1.50;
input double InpTakeProfit_R  = 2.00;

//==================================================================
// DYNAMIC DRAWDOWN CONTROL
//==================================================================

// Eddig a drawdownig teljes kockázat
input double InpRiskReductionStartDD = 2.00;

// Ennél a drawdownnál már nem nyit új pozíciót
input double InpMaxDrawdownPercent = 6.00;

// A legkisebb alkalmazott kockázati szorzó
// Például 0.30 = az eredeti kockázat 30%-a
input double InpMinimumRiskFactor = 0.30;

//==================================================================
// LOSS-STREAK CONTROL
//==================================================================

input int InpMaxConsecutiveLosses = 4;

// Valódi új gyertyák száma, nem naptári idő
input int InpCooldownBars = 20;

//==================================================================
// POSITION MANAGEMENT
//==================================================================

input bool   InpUseBreakEven       = true;
input double InpBreakEvenAt_R      = 0.80;
input int    InpBreakEvenOffsetPts = 0;

input bool   InpUseTrailingStop = true;
input double InpTrailingStart_R = 1.00;
input double InpTrailingATR     = 1.50;

//==================================================================
// EXECUTION SETTINGS
//==================================================================

input long InpMagicNumber     = 50030004;
input int  InpDeviationPoints = 20;

input bool InpOnePositionOnly = true;

//==================================================================
// INTERNAL STATE
//==================================================================

datetime g_lastBarTime = 0;

int g_fastEMAHandle = INVALID_HANDLE;
int g_midEMAHandle  = INVALID_HANDLE;
int g_slowEMAHandle = INVALID_HANDLE;
int g_adxHandle     = INVALID_HANDLE;

double g_equityPeak = 0.0;

int g_consecutiveLosses    = 0;
int g_cooldownBarsRemaining = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_fastEMAHandle = iMA(
      _Symbol,
      InpTimeframe,
      InpFastEMAPeriod,
      0,
      MODE_EMA,
      PRICE_CLOSE
   );

   g_midEMAHandle = iMA(
      _Symbol,
      InpTimeframe,
      InpMidEMAPeriod,
      0,
      MODE_EMA,
      PRICE_CLOSE
   );

   g_slowEMAHandle = iMA(
      _Symbol,
      InpTimeframe,
      InpSlowEMAPeriod,
      0,
      MODE_EMA,
      PRICE_CLOSE
   );

   g_adxHandle = iADX(
      _Symbol,
      InpTimeframe,
      InpADXPeriod
   );

   if(g_fastEMAHandle == INVALID_HANDLE ||
      g_midEMAHandle  == INVALID_HANDLE ||
      g_slowEMAHandle == INVALID_HANDLE ||
      g_adxHandle     == INVALID_HANDLE)
   {
      Print("Hiba: valamelyik indikátorhandle nem jött létre.");
      return INIT_FAILED;
   }

   g_lastBarTime = iTime(_Symbol, InpTimeframe, 0);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   g_equityPeak = MathMax(equity, balance);

   g_consecutiveLosses     = 0;
   g_cooldownBarsRemaining = 0;

   Print(
      "DonchianBreakoutEA_v3E inicializálva. Equity peak: ",
      DoubleToString(g_equityPeak, 2)
   );

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_fastEMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_fastEMAHandle);

   if(g_midEMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_midEMAHandle);

   if(g_slowEMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_slowEMAHandle);

   if(g_adxHandle != INVALID_HANDLE)
      IndicatorRelease(g_adxHandle);
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdateEquityPeak();
   ManageOpenPosition();

   if(!IsNewBar())
      return;

   if(g_cooldownBarsRemaining > 0)
   {
      g_cooldownBarsRemaining--;

      Print(
         "Cooldown aktív. Hátralévő gyertyák: ",
         g_cooldownBarsRemaining
      );

      return;
   }

   CheckForEntry();
}

//+------------------------------------------------------------------+
//| Trade transaction                                                |
//+------------------------------------------------------------------+
void OnTradeTransaction(
   const MqlTradeTransaction &trans,
   const MqlTradeRequest     &request,
   const MqlTradeResult      &result
)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(trans.deal == 0)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   string symbol = HistoryDealGetString(
      trans.deal,
      DEAL_SYMBOL
   );

   long magic = HistoryDealGetInteger(
      trans.deal,
      DEAL_MAGIC
   );

   if(symbol != _Symbol || magic != InpMagicNumber)
      return;

   long entryType = HistoryDealGetInteger(
      trans.deal,
      DEAL_ENTRY
   );

   if(entryType != DEAL_ENTRY_OUT &&
      entryType != DEAL_ENTRY_OUT_BY)
   {
      return;
   }

   double profit = HistoryDealGetDouble(
      trans.deal,
      DEAL_PROFIT
   );

   double swap = HistoryDealGetDouble(
      trans.deal,
      DEAL_SWAP
   );

   double commission = HistoryDealGetDouble(
      trans.deal,
      DEAL_COMMISSION
   );

   double netResult = profit + swap + commission;

   if(netResult < 0.0)
   {
      g_consecutiveLosses++;

      Print(
         "Vesztes ügylet. Nettó eredmény: ",
         DoubleToString(netResult, 2),
         ". Egymást követő veszteségek: ",
         g_consecutiveLosses
      );

      if(g_consecutiveLosses >= InpMaxConsecutiveLosses)
      {
         g_cooldownBarsRemaining = InpCooldownBars;
         g_consecutiveLosses     = 0;

         Print(
            "Cooldown elindítva ",
            InpCooldownBars,
            " gyertyára."
         );
      }
   }
   else
   {
      g_consecutiveLosses = 0;

      Print(
         "Nem vesztes ügylet. Nettó eredmény: ",
         DoubleToString(netResult, 2),
         ". A veszteségsorozat nullázva."
      );
   }
}

//+------------------------------------------------------------------+
//| Equity peak update                                               |
//+------------------------------------------------------------------+
void UpdateEquityPeak()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(equity > g_equityPeak)
      g_equityPeak = equity;
}

//+------------------------------------------------------------------+
//| Current drawdown percentage                                      |
//+------------------------------------------------------------------+
double GetCurrentDrawdownPercent()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(equity <= 0.0 || g_equityPeak <= 0.0)
      return 0.0;

   double drawdownMoney = g_equityPeak - equity;

   if(drawdownMoney <= 0.0)
      return 0.0;

   return drawdownMoney / g_equityPeak * 100.0;
}

//+------------------------------------------------------------------+
//| Dynamic risk factor                                              |
//+------------------------------------------------------------------+
double GetRiskFactor()
{
   double drawdown = GetCurrentDrawdownPercent();

   if(drawdown <= InpRiskReductionStartDD)
      return 1.0;

   if(drawdown >= InpMaxDrawdownPercent)
      return 0.0;

   double range =
      InpMaxDrawdownPercent -
      InpRiskReductionStartDD;

   if(range <= 0.0)
      return InpMinimumRiskFactor;

   double progress =
      (drawdown - InpRiskReductionStartDD) /
      range;

   progress = MathMax(
      0.0,
      MathMin(progress, 1.0)
   );

   double factor =
      1.0 -
      progress *
      (1.0 - InpMinimumRiskFactor);

   return MathMax(
      factor,
      InpMinimumRiskFactor
   );
}

//+------------------------------------------------------------------+
//| Permission to open a new trade                                   |
//+------------------------------------------------------------------+
bool CanTradeNow()
{
   if(g_cooldownBarsRemaining > 0)
      return false;

   double drawdown = GetCurrentDrawdownPercent();

   if(drawdown >= InpMaxDrawdownPercent)
   {
      Print(
         "Új belépés tiltva. Drawdown: ",
         DoubleToString(drawdown, 2),
         "%"
      );

      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| New bar detection                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(
      _Symbol,
      InpTimeframe,
      0
   );

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
//| Entry evaluation                                                 |
//+------------------------------------------------------------------+
void CheckForEntry()
{
   if(!CanTradeNow())
      return;

   if(InpOnePositionOnly && HasAnyPositionOnSymbol())
      return;

   if(FindOurPosition() != 0)
      return;

   int longestPeriod = MathMax(
      InpSlowEMAPeriod,
      MathMax(
         InpDonchianPeriod,
         MathMax(InpATRPeriod, InpADXPeriod)
      )
   );

   int requiredBars = longestPeriod + 20;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   int copied = CopyRates(
      _Symbol,
      InpTimeframe,
      0,
      requiredBars,
      rates
   );

   if(copied < requiredBars)
      return;

   // Donchian-csatorna a breakout gyertyát megelőző gyertyákból
   double donchianHigh = rates[2].high;
   double donchianLow  = rates[2].low;

   for(int i = 3; i <= InpDonchianPeriod + 1; i++)
   {
      if(rates[i].high > donchianHigh)
         donchianHigh = rates[i].high;

      if(rates[i].low < donchianLow)
         donchianLow = rates[i].low;
   }

   double closePrice = rates[1].close;

   bool longTrendOK  = true;
   bool shortTrendOK = true;

   //===============================================================
   // EMA trend filter
   //===============================================================

   if(InpUseTrendFilter)
   {
      double fastEMA = GetIndicatorValue(
         g_fastEMAHandle,
         0,
         1
      );

      double midEMA = GetIndicatorValue(
         g_midEMAHandle,
         0,
         1
      );

      double slowEMA = GetIndicatorValue(
         g_slowEMAHandle,
         0,
         1
      );

      if(fastEMA <= 0.0 ||
         midEMA  <= 0.0 ||
         slowEMA <= 0.0)
      {
         return;
      }

      longTrendOK =
         fastEMA > midEMA &&
         midEMA > slowEMA &&
         closePrice > fastEMA;

      shortTrendOK =
         fastEMA < midEMA &&
         midEMA < slowEMA &&
         closePrice < fastEMA;
   }

   //===============================================================
   // ADX and DI filter
   //===============================================================

   if(InpUseADXFilter)
   {
      double adxValue = GetIndicatorValue(
         g_adxHandle,
         0,
         1
      );

      double plusDI = GetIndicatorValue(
         g_adxHandle,
         1,
         1
      );

      double minusDI = GetIndicatorValue(
         g_adxHandle,
         2,
         1
      );

      if(adxValue <= 0.0)
         return;

      bool adxStrengthOK = adxValue >= InpMinADX;

      longTrendOK =
         longTrendOK &&
         adxStrengthOK;

      shortTrendOK =
         shortTrendOK &&
         adxStrengthOK;

      if(InpUseDirectionalDI)
      {
         longTrendOK =
            longTrendOK &&
            plusDI > minusDI;

         shortTrendOK =
            shortTrendOK &&
            minusDI > plusDI;
      }
   }

   bool longSignal =
      InpAllowLong &&
      closePrice > donchianHigh &&
      longTrendOK;

   bool shortSignal =
      InpAllowShort &&
      closePrice < donchianLow &&
      shortTrendOK;

   if(!longSignal && !shortSignal)
      return;

   double atr = CalculateATR(
      1,
      InpATRPeriod
   );

   if(atr <= 0.0)
      return;

   //===============================================================
   // Breakout candle size filter
   //===============================================================

   double breakoutRange =
      rates[1].high -
      rates[1].low;

   if(breakoutRange <
      atr * InpMinBreakoutRangeATR)
   {
      return;
   }

   if(InpMaxBreakoutRangeATR > 0.0 &&
      breakoutRange >
      atr * InpMaxBreakoutRangeATR)
   {
      return;
   }

   //===============================================================
   // Average range / minimum volatility filter
   //===============================================================

   double averageRange = 0.0;

   for(int i = 1; i <= InpATRPeriod; i++)
   {
      averageRange +=
         rates[i].high -
         rates[i].low;
   }

   averageRange /= InpATRPeriod;

   if(atr <
      averageRange * InpMinATRMultiplier)
   {
      return;
   }

   //===============================================================
   // Maximum breakout extension
   //===============================================================

   if(longSignal)
   {
      double longExtension =
         closePrice -
         donchianHigh;

      if(longExtension >
         atr * InpMaxBreakoutExtensionATR)
      {
         longSignal = false;
      }
   }

   if(shortSignal)
   {
      double shortExtension =
         donchianLow -
         closePrice;

      if(shortExtension >
         atr * InpMaxBreakoutExtensionATR)
      {
         shortSignal = false;
      }
   }

   if(!longSignal && !shortSignal)
      return;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

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
//| Read indicator buffer                                            |
//+------------------------------------------------------------------+
double GetIndicatorValue(
   int handle,
   int bufferNumber,
   int shift
)
{
   if(handle == INVALID_HANDLE)
      return 0.0;

   double values[];
   ArraySetAsSeries(values, true);

   int copied = CopyBuffer(
      handle,
      bufferNumber,
      shift,
      1,
      values
   );

   if(copied != 1)
      return 0.0;

   return values[0];
}

//+------------------------------------------------------------------+
//| Open a position                                                  |
//+------------------------------------------------------------------+
void OpenPosition(
   ENUM_ORDER_TYPE orderType,
   double entryPrice,
   double atr
)
{
   bool isBuy =
      orderType == ORDER_TYPE_BUY;

   double stopLoss =
      isBuy
      ? entryPrice - atr * InpInitialSL_ATR
      : entryPrice + atr * InpInitialSL_ATR;

   stopLoss = NormalizePrice(stopLoss);

   double initialRisk =
      MathAbs(entryPrice - stopLoss);

   if(initialRisk <= 0.0)
      return;

   double takeProfit =
      isBuy
      ? entryPrice + initialRisk * InpTakeProfit_R
      : entryPrice - initialRisk * InpTakeProfit_R;

   takeProfit = NormalizePrice(takeProfit);

   double volume = CalculateVolume(
      orderType,
      entryPrice,
      stopLoss
   );

   if(volume <= 0.0)
      return;

   bool result = false;

   if(isBuy)
   {
      result = trade.Buy(
         volume,
         _Symbol,
         0.0,
         stopLoss,
         takeProfit,
         "Donchian v3E BUY"
      );
   }
   else
   {
      result = trade.Sell(
         volume,
         _Symbol,
         0.0,
         stopLoss,
         takeProfit,
         "Donchian v3E SELL"
      );
   }

   if(!result)
   {
      Print(
         "Pozíciónyitási hiba. Retcode: ",
         trade.ResultRetcode(),
         " - ",
         trade.ResultRetcodeDescription()
      );
   }
   else
   {
      Print(
         "Pozíció megnyitva. Volume: ",
         DoubleToString(volume, 2),
         ", SL: ",
         DoubleToString(stopLoss, _Digits),
         ", TP: ",
         DoubleToString(takeProfit, _Digits),
         ", DD: ",
         DoubleToString(GetCurrentDrawdownPercent(), 2),
         "%, risk factor: ",
         DoubleToString(GetRiskFactor(), 2)
      );
   }
}

//+------------------------------------------------------------------+
//| Manage existing position                                         |
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   ulong ticket = FindOurPosition();

   if(ticket == 0)
      return;

   if(!PositionSelectByTicket(ticket))
      return;

   ENUM_POSITION_TYPE positionType =
      (ENUM_POSITION_TYPE)PositionGetInteger(
         POSITION_TYPE
      );

   double openPrice =
      PositionGetDouble(POSITION_PRICE_OPEN);

   double currentStop =
      PositionGetDouble(POSITION_SL);

   double takeProfit =
      PositionGetDouble(POSITION_TP);

   if(openPrice <= 0.0)
      return;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   bool isBuy =
      positionType == POSITION_TYPE_BUY;

   double currentPrice =
      isBuy
      ? tick.bid
      : tick.ask;

   double initialRisk = 0.0;

   if(takeProfit > 0.0 &&
      InpTakeProfit_R > 0.0)
   {
      initialRisk =
         MathAbs(takeProfit - openPrice) /
         InpTakeProfit_R;
   }

   if(initialRisk <= 0.0)
      return;

   double openProfitDistance =
      isBuy
      ? currentPrice - openPrice
      : openPrice - currentPrice;

   if(openProfitDistance <= 0.0)
      return;

   double newStop = currentStop;
   bool shouldModify = false;

   //===============================================================
   // Break-even
   //===============================================================

   if(InpUseBreakEven &&
      openProfitDistance >=
      initialRisk * InpBreakEvenAt_R)
   {
      double offset =
         InpBreakEvenOffsetPts * _Point;

      double breakEvenStop =
         isBuy
         ? openPrice + offset
         : openPrice - offset;

      if(IsBetterStop(
         isBuy,
         breakEvenStop,
         newStop
      ))
      {
         newStop     = breakEvenStop;
         shouldModify = true;
      }
   }

   //===============================================================
   // ATR trailing stop
   //===============================================================

   if(InpUseTrailingStop &&
      openProfitDistance >=
      initialRisk * InpTrailingStart_R)
   {
      double atr = CalculateATR(
         1,
         InpATRPeriod
      );

      if(atr > 0.0)
      {
         double trailingStop =
            isBuy
            ? currentPrice -
              atr * InpTrailingATR
            : currentPrice +
              atr * InpTrailingATR;

         if(IsBetterStop(
            isBuy,
            trailingStop,
            newStop
         ))
         {
            newStop      = trailingStop;
            shouldModify = true;
         }
      }
   }

   if(!shouldModify)
      return;

   newStop = NormalizePrice(newStop);

   if(!IsStopValidForBroker(
      isBuy,
      newStop,
      currentPrice
   ))
   {
      return;
   }

   if(!trade.PositionModify(
      ticket,
      newStop,
      takeProfit
   ))
   {
      Print(
         "Stop módosítási hiba. Retcode: ",
         trade.ResultRetcode(),
         " - ",
         trade.ResultRetcodeDescription()
      );
   }
}

//+------------------------------------------------------------------+
//| Manual ATR calculation                                           |
//+------------------------------------------------------------------+
double CalculateATR(
   int shift,
   int period
)
{
   if(period <= 0)
      return 0.0;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   int requiredBars =
      shift + period + 2;

   int copied = CopyRates(
      _Symbol,
      InpTimeframe,
      0,
      requiredBars,
      rates
   );

   if(copied < requiredBars)
      return 0.0;

   double sumTrueRange = 0.0;

   for(int i = shift;
       i < shift + period;
       i++)
   {
      double highLow =
         rates[i].high -
         rates[i].low;

      double highClose =
         MathAbs(
            rates[i].high -
            rates[i + 1].close
         );

      double lowClose =
         MathAbs(
            rates[i].low -
            rates[i + 1].close
         );

      double trueRange =
         MathMax(
            highLow,
            MathMax(highClose, lowClose)
         );

      sumTrueRange += trueRange;
   }

   return sumTrueRange / period;
}

//+------------------------------------------------------------------+
//| Position size calculation                                        |
//+------------------------------------------------------------------+
double CalculateVolume(
   ENUM_ORDER_TYPE orderType,
   double entryPrice,
   double stopLoss
)
{
   double balance =
      AccountInfoDouble(ACCOUNT_BALANCE);

   if(balance <= 0.0)
      return 0.0;

   double riskFactor = GetRiskFactor();

   if(riskFactor <= 0.0)
      return 0.0;

   double riskMoney =
      balance *
      InpRiskPercent /
      100.0;

   riskMoney *= riskFactor;

   double oneLotProfit = 0.0;

   if(!OrderCalcProfit(
      orderType,
      _Symbol,
      1.0,
      entryPrice,
      stopLoss,
      oneLotProfit
   ))
   {
      Print(
         "OrderCalcProfit hiba: ",
         GetLastError()
      );

      return 0.0;
   }

   double oneLotLoss =
      MathAbs(oneLotProfit);

   if(oneLotLoss <= 0.0)
      return 0.0;

   double rawVolume =
      riskMoney /
      oneLotLoss;

   return NormalizeVolume(rawVolume);
}

//+------------------------------------------------------------------+
//| Normalize trading volume                                         |
//+------------------------------------------------------------------+
double NormalizeVolume(double rawVolume)
{
   double minimumVolume =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MIN
      );

   double maximumVolume =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MAX
      );

   double volumeStep =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );

   if(minimumVolume <= 0.0 ||
      maximumVolume <= 0.0 ||
      volumeStep <= 0.0)
   {
      return 0.0;
   }

   if(rawVolume < minimumVolume)
      return 0.0;

   double volume =
      MathMin(
         rawVolume,
         maximumVolume
      );

   volume =
      MathFloor(volume / volumeStep) *
      volumeStep;

   int volumeDigits =
      GetVolumeDigits(volumeStep);

   volume =
      NormalizeDouble(
         volume,
         volumeDigits
      );

   if(volume < minimumVolume)
      return 0.0;

   return volume;
}

//+------------------------------------------------------------------+
//| Determine volume decimal places                                  |
//+------------------------------------------------------------------+
int GetVolumeDigits(double volumeStep)
{
   int digits = 0;
   double value = volumeStep;

   while(digits < 8 &&
         MathAbs(
            value -
            MathRound(value)
         ) > 0.00000001)
   {
      value *= 10.0;
      digits++;
   }

   return digits;
}

//+------------------------------------------------------------------+
//| Find position belonging to this EA                               |
//+------------------------------------------------------------------+
ulong FindOurPosition()
{
   for(int i = PositionsTotal() - 1;
       i >= 0;
       i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      string symbol =
         PositionGetString(POSITION_SYMBOL);

      long magic =
         PositionGetInteger(POSITION_MAGIC);

      if(symbol == _Symbol &&
         magic == InpMagicNumber)
      {
         return ticket;
      }
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Check any open position on current symbol                        |
//+------------------------------------------------------------------+
bool HasAnyPositionOnSymbol()
{
   for(int i = PositionsTotal() - 1;
       i >= 0;
       i--)
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

//+------------------------------------------------------------------+
//| Check whether proposed stop is better                            |
//+------------------------------------------------------------------+
bool IsBetterStop(
   bool isBuy,
   double proposedStop,
   double currentStop
)
{
   double tickSize =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_SIZE
      );

   if(tickSize <= 0.0)
      tickSize = _Point;

   if(currentStop == 0.0)
      return true;

   if(isBuy)
   {
      return proposedStop >
             currentStop +
             tickSize;
   }

   return proposedStop <
          currentStop -
          tickSize;
}

//+------------------------------------------------------------------+
//| Broker stop-distance validation                                  |
//+------------------------------------------------------------------+
bool IsStopValidForBroker(
   bool isBuy,
   double proposedStop,
   double currentPrice
)
{
   long stopsLevelPoints =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   double minimumDistance =
      stopsLevelPoints *
      _Point;

   if(minimumDistance <= 0.0)
      return true;

   if(isBuy)
   {
      return proposedStop <=
             currentPrice -
             minimumDistance;
   }

   return proposedStop >=
          currentPrice +
          minimumDistance;
}

//+------------------------------------------------------------------+
//| Price normalization                                              |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   double tickSize =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_SIZE
      );

   if(tickSize > 0.0)
   {
      price =
         MathRound(price / tickSize) *
         tickSize;
   }

   int digits =
      (int)SymbolInfoInteger(
         _Symbol,
         SYMBOL_DIGITS
      );

   return NormalizeDouble(
      price,
      digits
   );
}
//+------------------------------------------------------------------+