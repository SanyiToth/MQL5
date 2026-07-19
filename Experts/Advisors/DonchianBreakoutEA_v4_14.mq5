//+------------------------------------------------------------------+
//|                 DonchianBreakoutEA_v4_14.mq5                     |
//|   Donchian breakout H4 – restart-safe, perzisztens DD/MFE/MAE    |
//|   v4.14: MFE-retrace exit fix (mukodik profit<=0 eseten is) +    |
//|          strongTrendLong/Short duplikacio megszuntetve           |
//+------------------------------------------------------------------+
#property strict
#property version "4.14"

#include <Trade/Trade.mqh>
CTrade trade;

//==================================================================
// STRATEGY SETTINGS
//==================================================================

input ENUM_TIMEFRAMES InpTimeframe = PERIOD_H4;
input int InpDonchianPeriod = 16;
input bool InpAllowLong = true;
input bool InpAllowShort = true;

//==================================================================
// TREND FILTER (EMA)
//==================================================================

input bool InpUseTrendFilter = true;
input int InpFastEMAPeriod = 20;
input int InpMidEMAPeriod = 50;
input int InpSlowEMAPeriod = 200;

//==================================================================
// TREND STRENGTH FILTER (EMA DISTANCE + ATR)
//==================================================================

input bool InpUseTrendStrength = true;
input double InpMinFastMidDistATR = 0.5;
input double InpMinMidSlowDistATR = 1.0;

//==================================================================
// VOLATILITY FILTER (ATR / RANGE)
//==================================================================

input int InpATRPeriod = 14;
input double InpMinATRMultiplier = 0.40;
input double InpMinBreakoutRangeATR = 0.80;

input bool InpUseVolatilityFilter = true;
input double InpLowVolThreshold = 0.7;
input double InpHighVolThreshold = 1.8;

//==================================================================
// MARKET STRUCTURE FILTER (HH/HL, LH/LL)
//==================================================================

input bool InpUseMarketStructure = true;

//==================================================================
// RISK SETTINGS
//==================================================================

input double InpRiskPercent = 1.00;
input double InpInitialSL_ATR = 1.50;
input double InpTakeProfit_R = 2.00;

//==================================================================
// POSITION MANAGEMENT
//==================================================================

input bool InpUseBreakEven = true;
input double InpBreakEvenAt_R = 0.80;
input int InpBreakEvenOffsetPts = 0;

input bool InpUseTrailingStop = true;
input double InpTrailingStart_R = 1.00;
input double InpTrailingATR = 1.50;

//==================================================================
// MFE / MAE EXIT
//==================================================================

input bool InpUseMFEExit = true;
input double InpMFETriggerATR = 1.5;
input double InpMFERetraceATR = 0.5;

input bool InpUseMAEExit = true;
input double InpMAEThresholdATR = 1.2;

//==================================================================
// EXECUTION SETTINGS
//==================================================================

input long InpMagicNumber = 50040004;
input int InpDeviationPoints = 20;
input bool InpOnePositionOnly = true;

//==================================================================
// DRAWDOWN CONTROL
//==================================================================

input double InpMaxDrawdownPercent = 25.0;
input double InpRiskScaleOnDrawdown = 0.30;
input int InpMaxConsecutiveLosses = 4;
input int InpCooldownBars = 20;

// FIX: manual persistent state reset
input bool InpResetPersistentState = false;

//==================================================================
// INTERNAL STATE
//==================================================================

datetime g_lastBarTime = 0;
bool g_pendingEntry = false;
ENUM_ORDER_TYPE g_pendingType = ORDER_TYPE_BUY;
double g_pendingATR = 0.0;
int g_fastEMAHandle = INVALID_HANDLE;
int g_midEMAHandle = INVALID_HANDLE;
int g_slowEMAHandle = INVALID_HANDLE;

double g_equityPeak = 0.0;
int g_consecLosses = 0;
datetime g_cooldownUntil = 0;
bool g_ddLocked = false;

// FIX: real MFE/MAE tracking per position (persistent)
double g_mfe = 0.0;
double g_mae = 0.0;
double g_entryATR = 0.0;
ulong g_posTicket = 0;

string g_gvPrefix = "";

//+------------------------------------------------------------------+
int OnInit() {
  trade.SetExpertMagicNumber(InpMagicNumber);
  trade.SetDeviationInPoints(InpDeviationPoints);

  g_fastEMAHandle =
      iMA(_Symbol, InpTimeframe, InpFastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
  g_midEMAHandle =
      iMA(_Symbol, InpTimeframe, InpMidEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
  g_slowEMAHandle =
      iMA(_Symbol, InpTimeframe, InpSlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

  g_lastBarTime = iTime(_Symbol, InpTimeframe, 0);

  long login = AccountInfoInteger(ACCOUNT_LOGIN);
  g_gvPrefix = "DonchianEA_" + IntegerToString(login) + "_" + _Symbol + "_" +
               IntegerToString(InpMagicNumber) + "_" +
               EnumToString(InpTimeframe);

  string gvEq = g_gvPrefix + "_equityPeak";
  string gvLoss = g_gvPrefix + "_consecLosses";
  string gvCd = g_gvPrefix + "_cooldownUntil";
  string gvLock = g_gvPrefix + "_ddLock";
  string gvMfe = g_gvPrefix + "_mfe";
  string gvMae = g_gvPrefix + "_mae";
  string gvAtr = g_gvPrefix + "_entryATR";
  string gvPos = g_gvPrefix + "_posTicket";

  double eq = AccountInfoDouble(ACCOUNT_EQUITY);

  if (InpResetPersistentState) {
    GlobalVariableSet(gvEq, eq);
    GlobalVariableSet(gvLoss, 0.0);
    GlobalVariableSet(gvCd, 0.0);
    GlobalVariableSet(gvLock, 0.0);
    GlobalVariableSet(gvMfe, 0.0);
    GlobalVariableSet(gvMae, 0.0);
    GlobalVariableSet(gvAtr, 0.0);
    GlobalVariableSet(gvPos, 0.0);

    g_equityPeak = eq;
    g_consecLosses = 0;
    g_cooldownUntil = 0;
    g_ddLocked = false;
    g_mfe = 0.0;
    g_mae = 0.0;
    g_entryATR = 0.0;
    g_posTicket = 0;

    Print("Persistent state reset for ", g_gvPrefix);
  } else {
    if (!GlobalVariableCheck(gvEq))
      GlobalVariableSet(gvEq, eq);
    g_equityPeak = GlobalVariableGet(gvEq);

    if (!GlobalVariableCheck(gvLoss))
      GlobalVariableSet(gvLoss, 0.0);
    g_consecLosses = (int)GlobalVariableGet(gvLoss);

    if (!GlobalVariableCheck(gvCd))
      GlobalVariableSet(gvCd, 0.0);
    g_cooldownUntil = (datetime)GlobalVariableGet(gvCd);

    if (!GlobalVariableCheck(gvLock))
      GlobalVariableSet(gvLock, 0.0);
    g_ddLocked = (GlobalVariableGet(gvLock) > 0.5);

    if (!GlobalVariableCheck(gvMfe))
      GlobalVariableSet(gvMfe, 0.0);
    g_mfe = GlobalVariableGet(gvMfe);

    if (!GlobalVariableCheck(gvMae))
      GlobalVariableSet(gvMae, 0.0);
    g_mae = GlobalVariableGet(gvMae);

    if (!GlobalVariableCheck(gvAtr))
      GlobalVariableSet(gvAtr, 0.0);
    g_entryATR = GlobalVariableGet(gvAtr);

    if (!GlobalVariableCheck(gvPos))
      GlobalVariableSet(gvPos, 0.0);
    g_posTicket = (ulong)GlobalVariableGet(gvPos);
  }

  ulong currentPos = FindOurPosition();
  if (currentPos != 0 && PositionSelectByTicket(currentPos)) {
    if (g_posTicket != currentPos) {
      g_mfe = 0.0;
      g_mae = 0.0;
      g_entryATR = ATR(1, InpATRPeriod);
      g_posTicket = currentPos;

      GlobalVariableSet(gvMfe, 0.0);
      GlobalVariableSet(gvMae, 0.0);
      GlobalVariableSet(gvAtr, g_entryATR);
      GlobalVariableSet(gvPos, (double)g_posTicket);
    } else {
      if (g_entryATR <= 0.0) {
        g_entryATR = ATR(1, InpATRPeriod);
        GlobalVariableSet(gvAtr, g_entryATR);
      }
    }
  } else {
    g_mfe = 0.0;
    g_mae = 0.0;
    g_entryATR = 0.0;
    g_posTicket = 0;

    GlobalVariableSet(gvMfe, 0.0);
    GlobalVariableSet(gvMae, 0.0);
    GlobalVariableSet(gvAtr, 0.0);
    GlobalVariableSet(gvPos, 0.0);
  }

  return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick() {
  UpdateEquityPeak();
  ManageOpenPosition();

  if (IsNewBar()) {
    g_pendingEntry = false;
    CheckForEntry();
  }

  if (g_pendingEntry)
    TryOpenPendingPosition();
}

//+------------------------------------------------------------------+
// FIX: helper – check if a position with given POSITION_IDENTIFIER is still
// open
bool IsPositionIdentifierOpen(ulong positionIdentifier) {
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0)
      continue;

    string sym = PositionGetString(POSITION_SYMBOL);
    long magic = PositionGetInteger(POSITION_MAGIC);
    ulong id = (ulong)PositionGetInteger(POSITION_IDENTIFIER);

    if (id == positionIdentifier && sym == _Symbol && magic == InpMagicNumber)
      return true;
  }
  return false;
}

//+------------------------------------------------------------------+
// FIX: use POSITION_IDENTIFIER (DEAL_POSITION_ID) for full position history
//      and partial close detection
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &req, const MqlTradeResult &res) {
  if (trans.type != TRADE_TRANSACTION_DEAL_ADD)
    return;

  ulong deal_ticket = trans.deal;
  if (deal_ticket == 0)
    return;

  long entryType = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
  if (entryType != DEAL_ENTRY_OUT)
    return;

  string sym = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
  long magic = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);

  if (sym != _Symbol)
    return;
  if (magic != InpMagicNumber)
    return;

  ulong position_id =
      (ulong)HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);

  if (position_id == 0) {
    Print("OnTradeTransaction: invalid position_id for deal ", deal_ticket);
    return;
  }

  if (IsPositionIdentifierOpen(position_id)) {
    // partial close – position still open with same identifier
    return;
  }

  if (!HistorySelectByPosition(position_id)) {
    Print("HistorySelectByPosition failed for position_id ", position_id);
    return;
  }

  double net = 0.0;
  int dealsTotal = HistoryDealsTotal();

  for (int i = dealsTotal - 1; i >= 0; i--) {
    ulong dTicket = HistoryDealGetTicket(i);
    if (dTicket == 0)
      continue;

    ulong dPos = (ulong)HistoryDealGetInteger(dTicket, DEAL_POSITION_ID);
    if (dPos != position_id)
      continue;

    string dSym = HistoryDealGetString(dTicket, DEAL_SYMBOL);
    long dMagic = HistoryDealGetInteger(dTicket, DEAL_MAGIC);
    if (dSym != _Symbol || dMagic != InpMagicNumber)
      continue;

    double dProfit = HistoryDealGetDouble(dTicket, DEAL_PROFIT);
    double dSwap = HistoryDealGetDouble(dTicket, DEAL_SWAP);
    double dCommission = HistoryDealGetDouble(dTicket, DEAL_COMMISSION);
    double dFee = HistoryDealGetDouble(dTicket, DEAL_FEE);

    net += dProfit + dSwap + dCommission + dFee;
  }

  if (net < 0.0)
    g_consecLosses++;
  else
    g_consecLosses = 0;

  GlobalVariableSet(g_gvPrefix + "_consecLosses", g_consecLosses);

  if (g_consecLosses >= InpMaxConsecutiveLosses) {
    int sec = PeriodSeconds(InpTimeframe);
    g_cooldownUntil = TimeCurrent() + (sec * InpCooldownBars);
    GlobalVariableSet(g_gvPrefix + "_cooldownUntil", (double)g_cooldownUntil);
  }

  g_mfe = 0.0;
  g_mae = 0.0;
  g_entryATR = 0.0;
  g_posTicket = 0;

  GlobalVariableSet(g_gvPrefix + "_mfe", 0.0);
  GlobalVariableSet(g_gvPrefix + "_mae", 0.0);
  GlobalVariableSet(g_gvPrefix + "_entryATR", 0.0);
  GlobalVariableSet(g_gvPrefix + "_posTicket", 0.0);
}

//+------------------------------------------------------------------+
void UpdateEquityPeak() {
  double eq = AccountInfoDouble(ACCOUNT_EQUITY);
  if (eq > g_equityPeak) {
    g_equityPeak = eq;
    GlobalVariableSet(g_gvPrefix + "_equityPeak", g_equityPeak);
  }
}

//+------------------------------------------------------------------+
double GetCurrentDrawdownPercent() {
  double eq = AccountInfoDouble(ACCOUNT_EQUITY);
  if (eq <= 0.0 || g_equityPeak <= 0.0)
    return 0.0;

  double dd = g_equityPeak - eq;
  if (dd <= 0.0)
    return 0.0;

  return (dd / g_equityPeak) * 100.0;
}

//+------------------------------------------------------------------+
bool CanTradeNow() {
  if (g_ddLocked) {
    Print("DD lock active, trading disabled for ", g_gvPrefix);
    return false;
  }

  if (TimeCurrent() < g_cooldownUntil)
    return false;

  double dd = GetCurrentDrawdownPercent();
  if (dd >= InpMaxDrawdownPercent) {
    g_ddLocked = true;
    GlobalVariableSet(g_gvPrefix + "_ddLock", 1.0);
    Print("Max drawdown reached (", DoubleToString(dd, 2),
          "%). Trading locked for ", g_gvPrefix);
    return false;
  }

  return true;
}

//+------------------------------------------------------------------+
bool IsNewBar() {
  datetime t = iTime(_Symbol, InpTimeframe, 0);
  if (t != g_lastBarTime) {
    g_lastBarTime = t;
    return true;
  }
  return false;
}

//+------------------------------------------------------------------+
void CheckForEntry() {
  if (!CanTradeNow())
    return;

  if (InpOnePositionOnly && HasAnyPositionOnSymbol())
    return;

  if (FindOurPosition() != 0)
    return;

  int needBars = InpDonchianPeriod + InpATRPeriod + InpSlowEMAPeriod + 10;

  MqlRates r[];
  ArraySetAsSeries(r, true);

  if (CopyRates(_Symbol, InpTimeframe, 0, needBars, r) < needBars)
    return;

  double high = r[2].high;
  double low = r[2].low;

  for (int i = 3; i <= InpDonchianPeriod + 1; i++) {
    if (r[i].high > high)
      high = r[i].high;
    if (r[i].low < low)
      low = r[i].low;
  }

  double close = r[1].close;

  bool longOK = true;
  bool shortOK = true;

  if (InpUseTrendFilter) {
    double f = GetEMA(g_fastEMAHandle, 1);
    double m = GetEMA(g_midEMAHandle, 1);
    double s = GetEMA(g_slowEMAHandle, 1);

    longOK = (f > m && m > s && close > f);
    shortOK = (f < m && m < s && close < f);

    if (InpUseTrendStrength) {
      double atr = ATR(1, InpATRPeriod);
      double distFastMid = MathAbs(f - m);
      double distMidSlow = MathAbs(m - s);

      // FIX v4.14: strongTrendLong es strongTrendShort korabban azonos
      // kepletet szamolt ki ketszer (nem irany-fuggo, mert abszolutertek-
      // tavolsagokon alapul) -> egyetlen kozos valtozora egyszerusitve,
      // a logika (eredmenye) valtozatlan.
      bool strongTrend = (distFastMid > atr * InpMinFastMidDistATR) &&
                         (distMidSlow > atr * InpMinMidSlowDistATR);

      longOK = longOK && strongTrend;
      shortOK = shortOK && strongTrend;
    }
  }

  if (InpUseMarketStructure) {
    double high1 = r[1].high;
    double high2 = r[2].high;
    double low1 = r[1].low;
    double low2 = r[2].low;

    bool structureLong = (high1 > high2) && (low1 > low2);
    bool structureShort = (high1 < high2) && (low1 < low2);

    longOK = longOK && structureLong;
    shortOK = shortOK && structureShort;
  }

  bool longSignal = InpAllowLong && close > high && longOK;
  bool shortSignal = InpAllowShort && close < low && shortOK;

  if (!longSignal && !shortSignal)
    return;

  double atr = ATR(1, InpATRPeriod);
  if (atr <= 0.0)
    return;

  double breakoutRange = r[1].high - r[1].low;
  if (breakoutRange < atr * InpMinBreakoutRangeATR)
    return;

  double avgRange = 0.0;
  for (int i = 1; i <= InpATRPeriod; i++)
    avgRange += (r[i].high - r[i].low);
  avgRange /= InpATRPeriod;

  if (atr < avgRange * InpMinATRMultiplier)
    return;

  if (InpUseVolatilityFilter) {
    bool lowVol = atr < avgRange * InpLowVolThreshold;
    bool highVol = atr > avgRange * InpHighVolThreshold;

    if (lowVol || highVol)
      return;
  }

  if (longSignal) {
    g_pendingEntry = true;
    g_pendingType = ORDER_TYPE_BUY;
    g_pendingATR = atr;
  } else {
    g_pendingEntry = true;
    g_pendingType = ORDER_TYPE_SELL;
    g_pendingATR = atr;
  }
}

//+------------------------------------------------------------------+
double GetEMA(int h, int shift) {
  double b[];
  ArraySetAsSeries(b, true);
  if (CopyBuffer(h, 0, shift, 1, b) != 1)
    return 0.0;
  return b[0];
}

//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE type, double entry, double atr) {
  bool buy = (type == ORDER_TYPE_BUY);

  double sl =
      buy ? entry - atr * InpInitialSL_ATR : entry + atr * InpInitialSL_ATR;

  sl = NormalizePrice(sl);

  double tp = buy ? entry + (MathAbs(entry - sl) * InpTakeProfit_R)
                  : entry - (MathAbs(entry - sl) * InpTakeProfit_R);

  tp = NormalizePrice(tp);

  double vol = CalcVolume(type, entry, sl);
  if (vol <= 0.0)
    return false;

  bool ok = false;

  if (buy)
    ok = trade.Buy(vol, _Symbol, 0, sl, tp);
  else
    ok = trade.Sell(vol, _Symbol, 0, sl, tp);

  if (!ok || trade.ResultRetcode() != TRADE_RETCODE_DONE) {
    Print("Order send failed: ", trade.ResultRetcode(), " ",
          trade.ResultRetcodeDescription());

    return false;
  }

  ulong deal = trade.ResultDeal();
  if (deal == 0) {
    Print("Order send completed but no deal ticket: ", trade.ResultRetcode(),
          " ", trade.ResultRetcodeDescription());

    return false;
  }

  g_mfe = 0.0;
  g_mae = 0.0;
  g_entryATR = atr;

  g_posTicket = FindOurPosition();

  GlobalVariableSet(g_gvPrefix + "_mfe", g_mfe);
  GlobalVariableSet(g_gvPrefix + "_mae", g_mae);
  GlobalVariableSet(g_gvPrefix + "_entryATR", g_entryATR);
  GlobalVariableSet(g_gvPrefix + "_posTicket", (double)g_posTicket);

  return true;
}

void TryOpenPendingPosition() {
  MqlTick tick;
  if (!SymbolInfoTick(_Symbol, tick))
    return;

  double price = (g_pendingType == ORDER_TYPE_BUY) ? tick.ask : tick.bid;

  if (OpenPosition(g_pendingType, price, g_pendingATR))
    g_pendingEntry = false;
}

//+------------------------------------------------------------------+
void ManageOpenPosition() {
  ulong ticket = FindOurPosition();
  if (ticket == 0)
    return;

  if (!PositionSelectByTicket(ticket))
    return;

  ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
  double open = PositionGetDouble(POSITION_PRICE_OPEN);
  double sl = PositionGetDouble(POSITION_SL);
  double tp = PositionGetDouble(POSITION_TP);

  MqlTick t;
  if (!SymbolInfoTick(_Symbol, t))
    return;

  bool buy = (type == POSITION_TYPE_BUY);
  double price = buy ? t.bid : t.ask;

  double profit = buy ? price - open : open - price;
  double risk = MathAbs(tp - open) / InpTakeProfit_R;

  double atr = ATR(1, InpATRPeriod);

  if (g_posTicket != ticket) {
    g_mfe = 0.0;
    g_mae = 0.0;
    g_entryATR = atr;
    g_posTicket = ticket;

    GlobalVariableSet(g_gvPrefix + "_mfe", g_mfe);
    GlobalVariableSet(g_gvPrefix + "_mae", g_mae);
    GlobalVariableSet(g_gvPrefix + "_entryATR", g_entryATR);
    GlobalVariableSet(g_gvPrefix + "_posTicket", (double)g_posTicket);
  }

  if (profit > 0.0) {
    if (profit > g_mfe) {
      g_mfe = profit;
      GlobalVariableSet(g_gvPrefix + "_mfe", g_mfe);
    }
  } else if (profit < 0.0) {
    double loss = -profit;
    if (loss > g_mae) {
      g_mae = loss;
      GlobalVariableSet(g_gvPrefix + "_mae", g_mae);
    }
  }

  // MAE exit (mar eredetileg is fuggetlen a profit elojelet vizsgalo
  // return-tol, ez valtozatlan)
  if (InpUseMAEExit && g_entryATR > 0.0) {
    if (g_mae > g_entryATR * InpMAEThresholdATR) {
      Print("MAE exit triggered on ", g_gvPrefix);
      if (!trade.PositionClose(ticket) ||
          trade.ResultRetcode() != TRADE_RETCODE_DONE) {
        Print("PositionClose failed (MAE): ", trade.ResultRetcode(), " ",
              trade.ResultRetcodeDescription());
      }
      return;
    }
  }

  // FIX v4.14: az MFE-retrace exit korabban a "if(profit <= 0.0) return;"
  // sor UTAN futott, igy ha a pozicio nagy MFE utan mar mar mar veszteseg-
  // be fordult (profit <= 0), a retrace-exit soha nem sult el. Most a
  // korabbi return ele kerult, tehat profit elojelenek allasatol
  // fuggetlenul ellenorzodik.
  if (InpUseMFEExit && g_entryATR > 0.0) {
    if (g_mfe > g_entryATR * InpMFETriggerATR) {
      double retraceLevel = g_mfe - g_entryATR * InpMFERetraceATR;
      if (profit < retraceLevel) {
        Print("MFE retrace exit triggered on ", g_gvPrefix);
        if (!trade.PositionClose(ticket) ||
            trade.ResultRetcode() != TRADE_RETCODE_DONE) {
          Print("PositionClose failed (MFE): ", trade.ResultRetcode(), " ",
                trade.ResultRetcodeDescription());
        }
        return;
      }
    }
  }

  if (profit <= 0.0)
    return;

  double newSL = sl;
  bool mod = false;

  if (InpUseBreakEven && profit >= risk * InpBreakEvenAt_R) {
    double be = open;

    if (InpBreakEvenOffsetPts != 0) {
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if (buy)
        be += InpBreakEvenOffsetPts * point;
      else
        be -= InpBreakEvenOffsetPts * point;
    }

    if (IsBetterStop(buy, be, sl)) {
      newSL = be;
      mod = true;
    }
  }

  if (InpUseTrailingStop && profit >= risk * InpTrailingStart_R) {
    double trSL =
        buy ? price - atr * InpTrailingATR : price + atr * InpTrailingATR;

    if (IsBetterStop(buy, trSL, newSL)) {
      newSL = trSL;
      mod = true;
    }
  }

  if (!mod)
    return;

  newSL = NormalizePrice(newSL);
  if (!trade.PositionModify(ticket, newSL, tp) ||
      trade.ResultRetcode() != TRADE_RETCODE_DONE) {
    Print("PositionModify failed: ", trade.ResultRetcode(), " ",
          trade.ResultRetcodeDescription());
  }
}

//+------------------------------------------------------------------+
double ATR(int shift, int period) {
  MqlRates r[];
  ArraySetAsSeries(r, true);

  if (CopyRates(_Symbol, InpTimeframe, 0, shift + period + 2, r) <
      shift + period + 2)
    return 0.0;

  double sum = 0.0;
  for (int i = shift; i < shift + period; i++) {
    double hl = r[i].high - r[i].low;
    double hc = MathAbs(r[i].high - r[i + 1].close);
    double lc = MathAbs(r[i].low - r[i + 1].close);
    sum += MathMax(hl, MathMax(hc, lc));
  }
  return sum / period;
}

//+------------------------------------------------------------------+
double CalcVolume(ENUM_ORDER_TYPE type, double entry, double sl) {
  double bal = AccountInfoDouble(ACCOUNT_BALANCE);
  double riskMoney = bal * InpRiskPercent / 100.0;

  double dd = GetCurrentDrawdownPercent();
  if (dd > 0.0) {
    double scale = 1.0;

    if (dd >= 20.0)
      scale = InpRiskScaleOnDrawdown;
    else if (dd >= 10.0)
      scale = 0.50;
    else if (dd >= 5.0)
      scale = 0.70;
    else
      scale = 1.0;

    riskMoney *= scale;
  }

  double profit1lot = 0.0;
  if (!OrderCalcProfit(type, _Symbol, 1.0, entry, sl, profit1lot))
    return 0.0;

  double loss1lot = MathAbs(profit1lot);
  if (loss1lot <= 0.0)
    return 0.0;

  double raw = riskMoney / loss1lot;

  double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

  if (raw < minV)
    return 0.0;

  double v = MathMin(raw, maxV);
  v = MathFloor(v / step) * step;

  int volDigits = 0;
  double tmp = step;
  while (tmp < 1.0 && volDigits < 8) {
    tmp *= 10.0;
    volDigits++;
  }

  return NormalizeDouble(v, volDigits);
}

//+------------------------------------------------------------------+
ulong FindOurPosition() {
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0)
      continue;

    if (PositionGetString(POSITION_SYMBOL) == _Symbol &&
        PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      return t;
  }
  return 0;
}

//+------------------------------------------------------------------+
bool HasAnyPositionOnSymbol() {
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    if (PositionGetString(POSITION_SYMBOL) == _Symbol)
      return true;
  }
  return false;
}

//+------------------------------------------------------------------+
bool IsBetterStop(bool buy, double proposed, double current) {
  double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

  if (current == 0.0)
    return true;

  if (buy)
    return proposed > current + tick;
  else
    return proposed < current - tick;
}

//+------------------------------------------------------------------+
double NormalizePrice(double p) {
  int d = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
  return NormalizeDouble(p, d);
}
//+------------------------------------------------------------------+