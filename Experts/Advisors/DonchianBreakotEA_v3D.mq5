//+------------------------------------------------------------------+
//|                        DonchianBreakoutEA_v3D.mq5                |
//|   Donchian breakout H4 – szigorúbb szűrés + kisebb DD            |
//+------------------------------------------------------------------+
#property strict
#property version "3.02"

#include <Trade/Trade.mqh>
CTrade trade;

//==================================================================
// STRATEGY SETTINGS
//==================================================================

input ENUM_TIMEFRAMES InpTimeframe      = PERIOD_H4;
input int             InpDonchianPeriod = 16;   // volt 14
input bool            InpAllowLong      = true;
input bool            InpAllowShort     = true;

//==================================================================
// TREND FILTER (SZIGORÚBB)
//==================================================================

input bool InpUseTrendFilter   = true;
input int  InpFastEMAPeriod    = 20;
input int  InpMidEMAPeriod     = 50;
input int  InpSlowEMAPeriod    = 200;

//==================================================================
// VOLATILITY FILTER (RELAXED)
//==================================================================

input int    InpATRPeriod           = 14;
input double InpMinATRMultiplier    = 0.40;
input double InpMinBreakoutRangeATR = 0.80;

//==================================================================
// RISK SETTINGS (DD-CSÖKKENTŐ)
//==================================================================

input double InpRiskPercent   = 1.00;
input double InpInitialSL_ATR = 1.50;  // volt 2.00
input double InpTakeProfit_R  = 2.00;  // volt 3.00

//==================================================================
// POSITION MANAGEMENT
//==================================================================

input bool   InpUseBreakEven       = true;
input double InpBreakEvenAt_R      = 0.80; // volt 1.00
input int    InpBreakEvenOffsetPts = 0;

input bool   InpUseTrailingStop = true;
input double InpTrailingStart_R = 1.00; // volt 1.50
input double InpTrailingATR     = 1.50; // volt 2.00

//==================================================================
// EXECUTION SETTINGS
//==================================================================

input long InpMagicNumber     = 50030003;
input int  InpDeviationPoints = 20;
input bool InpOnePositionOnly = true;

//==================================================================
// DRAWDOWN CONTROL
//==================================================================

input double InpMaxDrawdownPercent   = 25.0;
input double InpRiskScaleOnDrawdown  = 0.30; // volt 0.50
input int    InpMaxConsecutiveLosses = 4;
input int    InpCooldownBars         = 20;   // volt 10

//==================================================================
// INTERNAL STATE
//==================================================================

datetime g_lastBarTime      = 0;
int      g_fastEMAHandle    = INVALID_HANDLE;
int      g_midEMAHandle     = INVALID_HANDLE;
int      g_slowEMAHandle    = INVALID_HANDLE;

double   g_equityPeak       = 0.0;
int      g_consecLosses     = 0;
datetime g_cooldownUntil    = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);

   g_fastEMAHandle = iMA(_Symbol, InpTimeframe, InpFastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_midEMAHandle  = iMA(_Symbol, InpTimeframe, InpMidEMAPeriod,  0, MODE_EMA, PRICE_CLOSE);
   g_slowEMAHandle = iMA(_Symbol, InpTimeframe, InpSlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   g_lastBarTime = iTime(_Symbol, InpTimeframe, 0);

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   g_equityPeak   = eq;
   g_consecLosses = 0;
   g_cooldownUntil = 0;

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
   UpdateEquityPeak();
   ManageOpenPosition();

   if(IsNewBar())
      CheckForEntry();
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest      &req,
                        const MqlTradeResult       &res)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong deal_ticket = trans.deal;
   if(deal_ticket == 0)
      return;

   long entryType = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
   if(entryType != DEAL_ENTRY_OUT)
      return;

   double profit     = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
   double swap       = HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
   double commission = HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);

   double net = profit + swap + commission;

   if(net < 0.0)
   {
      g_consecLosses++;

      if(g_consecLosses >= InpMaxConsecutiveLosses)
      {
         int sec = PeriodSeconds(InpTimeframe);
         g_cooldownUntil = TimeCurrent() + (sec * InpCooldownBars);
      }
   }
   else
   {
      g_consecLosses = 0;
   }
}

//+------------------------------------------------------------------+
void UpdateEquityPeak()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_equityPeak)
      g_equityPeak = eq;
}

//+------------------------------------------------------------------+
double GetCurrentDrawdownPercent()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0.0 || g_equityPeak <= 0.0)
      return 0.0;

   double dd = g_equityPeak - eq;
   if(dd <= 0.0)
      return 0.0;

   return (dd / g_equityPeak) * 100.0;
}

//+------------------------------------------------------------------+
bool CanTradeNow()
{
   if(TimeCurrent() < g_cooldownUntil)
      return false;

   double dd = GetCurrentDrawdownPercent();
   if(dd >= InpMaxDrawdownPercent)
      return false;

   return true;
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol, InpTimeframe, 0);
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void CheckForEntry()
{
   if(!CanTradeNow())
      return;

   if(InpOnePositionOnly && HasAnyPositionOnSymbol())
      return;

   if(FindOurPosition() != 0)
      return;

   int needBars = InpDonchianPeriod + InpATRPeriod + InpSlowEMAPeriod + 10;

   MqlRates r[];
   ArraySetAsSeries(r, true);

   if(CopyRates(_Symbol, InpTimeframe, 0, needBars, r) < needBars)
      return;

   double high = r[2].high;
   double low  = r[2].low;

   for(int i = 3; i <= InpDonchianPeriod + 1; i++)
   {
      if(r[i].high > high) high = r[i].high;
      if(r[i].low < low)   low  = r[i].low;
   }

   double close = r[1].close;

   bool longOK  = true;
   bool shortOK = true;

   if(InpUseTrendFilter)
   {
      double f = GetEMA(g_fastEMAHandle, 1);
      double m = GetEMA(g_midEMAHandle, 1);
      double s = GetEMA(g_slowEMAHandle, 1);

      // SZIGORÚBB TRENDFILTER: close > fast EMA / close < fast EMA
      longOK  = (f > m && m > s && close > f);
      shortOK = (f < m && m < s && close < f);
   }

   bool longSignal  = InpAllowLong  && close > high && longOK;
   bool shortSignal = InpAllowShort && close < low  && shortOK;

   if(!longSignal && !shortSignal)
      return;

   double atr = ATR(1, InpATRPeriod);
   if(atr <= 0.0)
      return;

   double breakoutRange = r[1].high - r[1].low;
   if(breakoutRange < atr * InpMinBreakoutRangeATR)
      return;

   double avgRange = 0.0;
   for(int i = 1; i <= InpATRPeriod; i++)
      avgRange += (r[i].high - r[i].low);
   avgRange /= InpATRPeriod;

   if(atr < avgRange * InpMinATRMultiplier)
      return;

   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t))
      return;

   if(longSignal)
      OpenPosition(ORDER_TYPE_BUY, t.ask, atr);
   else
      OpenPosition(ORDER_TYPE_SELL, t.bid, atr);
}

//+------------------------------------------------------------------+
double GetEMA(int h, int shift)
{
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(h, 0, shift, 1, b) != 1)
      return 0.0;
   return b[0];
}

//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE type, double entry, double atr)
{
   bool buy = (type == ORDER_TYPE_BUY);

   double sl = buy ? entry - atr * InpInitialSL_ATR
                   : entry + atr * InpInitialSL_ATR;

   sl = NormalizePrice(sl);

   double tp = buy ? entry + (MathAbs(entry - sl) * InpTakeProfit_R)
                   : entry - (MathAbs(entry - sl) * InpTakeProfit_R);

   tp = NormalizePrice(tp);

   double vol = CalcVolume(type, entry, sl);
   if(vol <= 0.0)
      return;

   if(buy)
      trade.Buy(vol, _Symbol, 0, sl, tp);
   else
      trade.Sell(vol, _Symbol, 0, sl, tp);
}

//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   ulong ticket = FindOurPosition();
   if(ticket == 0)
      return;

   if(!PositionSelectByTicket(ticket))
      return;

   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   = PositionGetDouble(POSITION_SL);
   double tp   = PositionGetDouble(POSITION_TP);

   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t))
      return;

   bool buy = (type == POSITION_TYPE_BUY);
   double price = buy ? t.bid : t.ask;

   double risk   = MathAbs(tp - open) / InpTakeProfit_R;
   double profit = buy ? price - open : open - price;

   if(profit <= 0)
      return;

   double newSL = sl;
   bool mod     = false;

   // Break-even
   if(InpUseBreakEven && profit >= risk * InpBreakEvenAt_R)
   {
      double be = open;
      if(IsBetterStop(buy, be, sl))
      {
         newSL = be;
         mod   = true;
      }
   }

   // Trailing
   if(InpUseTrailingStop && profit >= risk * InpTrailingStart_R)
   {
      double atr = ATR(1, InpATRPeriod);
      double trSL = buy ? price - atr * InpTrailingATR
                        : price + atr * InpTrailingATR;

      if(IsBetterStop(buy, trSL, newSL))
      {
         newSL = trSL;
         mod   = true;
      }
   }

   if(!mod)
      return;

   newSL = NormalizePrice(newSL);
   trade.PositionModify(ticket, newSL, tp);
}

//+------------------------------------------------------------------+
double ATR(int shift, int period)
{
   MqlRates r[];
   ArraySetAsSeries(r, true);

   if(CopyRates(_Symbol, InpTimeframe, 0, shift + period + 2, r) < shift + period + 2)
      return 0.0;

   double sum = 0.0;
   for(int i = shift; i < shift + period; i++)
   {
      double hl = r[i].high - r[i].low;
      double hc = MathAbs(r[i].high - r[i+1].close);
      double lc = MathAbs(r[i].low  - r[i+1].close);
      sum += MathMax(hl, MathMax(hc, lc));
   }
   return sum / period;
}

//+------------------------------------------------------------------+
double CalcVolume(ENUM_ORDER_TYPE type, double entry, double sl)
{
   double bal       = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = bal * InpRiskPercent / 100.0;

   double dd = GetCurrentDrawdownPercent();
   if(dd > 0.0)
      riskMoney *= InpRiskScaleOnDrawdown;

   double profit1lot = 0.0;
   if(!OrderCalcProfit(type, _Symbol, 1.0, entry, sl, profit1lot))
      return 0.0;

   double loss1lot = MathAbs(profit1lot);
   if(loss1lot <= 0.0)
      return 0.0;

   double raw = riskMoney / loss1lot;

   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(raw < minV)
      return 0.0;

   double v = MathMin(raw, maxV);
   v = MathFloor(v / step) * step;

   return NormalizeDouble(v, 2);
}

//+------------------------------------------------------------------+
ulong FindOurPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         return t;
   }
   return 0;
}

//+------------------------------------------------------------------+
bool HasAnyPositionOnSymbol()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool IsBetterStop(bool buy, double proposed, double current)
{
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(current == 0.0)
      return true;

   if(buy)
      return proposed > current + tick;
   else
      return proposed < current - tick;
}

//+------------------------------------------------------------------+
double NormalizePrice(double p)
{
   int d = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(p, d);
}
//+------------------------------------------------------------------+
