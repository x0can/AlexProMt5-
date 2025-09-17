//+------------------------------------------------------------------+
//| AlexPro Intraday & M15 Scalper (v2.20)                           |
//| Strategy: RSI(21)+MA(20/50)+ATR stops+SR+HTF+Momentum            |
//| Profiles: DayTrade (intraday) / Scalp15 (15‑min scalping)        |
//| Additions: profile presets, TF rewire, spread filter, BE,        |
//|            daily loss/trade cap, max hold, flatten at session end|
//| Platform: MetaTrader 5                                           |
//+------------------------------------------------------------------+
#property copyright "AlexPro"
#property version   "2.20"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//---------------------------
// Inputs
//---------------------------
enum TradeProfile { PROFILE_DAYTRADE=0, PROFILE_SCALP15=1 };
input TradeProfile Profile          = PROFILE_SCALP15;
input bool    AutoProfileParams     = true;   // if true, profile will override key params below

// Timeframes (used if AutoProfileParams=false or for manual overrides)
input ENUM_TIMEFRAMES TF_Signal     = PERIOD_M15; // primary signal TF
input ENUM_TIMEFRAMES TF_Confirm    = PERIOD_M5;  // momentum confirm TF
input ENUM_TIMEFRAMES TF_HTF        = PERIOD_H1;  // trend/regime TF
input ENUM_TIMEFRAMES TF_ATR        = PERIOD_M15; // ATR/volatility TF for SL/TP sizing

// Strategy params (may be overridden by profile at runtime)
input ulong   ExpertMagic           = 202509121996;
input double  LotSize               = 1.0;
input bool    UseRiskPercent        = true;
input double  RiskPercent           = 1.0;

input int     ATR_Period            = 14;
input double  ATR_SL_Multiplier     = 2.0;    // may be overridden by profile
input double  TP_Multiplier         = 2.0;    // may be overridden by profile

input int     MaxTradesPerSignal    = 2;
input int     ConfirmBars           = 3;      // on TF_Confirm (e.g., M5)
input int     SR_LookbackBars       = 20;
input double  SR_ATR_Factor         = 0.5;
input double  MinATR_Pips           = 15.0;   // may be overridden by profile
input int     HTF_RSI_Period        = 21;
input int     HTF_MA_Fast           = 20;
input int     HTF_MA_Slow           = 50;
input double  PartialClosePct       = 50.0;

input bool    UseNewsFilter         = true;
input int     NewsLookaheadMin      = 30;
input int     NewsLookbackMin       = 15;

input bool    UseSpikeFilter        = true;
input double  SpikeATRMult          = 3.0;

input bool    UseADXFilter          = true;
input int     ADX_Period            = 14;
input double  ADX_Threshold         = 25.0;   // may be overridden by profile
input bool    ADX_RequireTrending   = true;

input bool    EnableWebhook         = true;
input string  WebhookURL            = "https://example.com/alexpro-webhook";
input int     WebhookTimeoutSec     = 10;

input bool    LogMLToCSV            = true;
input string  CsvFileName           = "AlexPro_trades.csv"; // Common\Files

input bool    ShowSRLines           = true;
input bool    VerboseLogging        = true;

// Sessions (GMT hours)
input int     LondonStartGMT        = 7;
input int     LondonEndGMT          = 16;
input int     NYStartGMT            = 12;
input int     NYEndGMT              = 21;

// Scalper/Intraday risk governance
input bool    UseSpreadFilter       = true;
input double  MaxSpreadPips         = 2.5;     // profile overrides (3.0 for DayTrade, 2.0–2.5 for Scalp15)

input bool    UseDailyMaxTrades     = true;
input int     DailyMaxTrades        = 8;

input bool    UseDailyLossLimit     = true;
input double  DailyLossLimitPct     = 3.0;     // % of equity drawdown to stop for the day

input bool    FlattenBeforeSessionEnd = true;
input int     FlattenMinutesBeforeEnd = 10;

input bool    UseMaxHoldMinutes     = true;
input int     MaxHoldMinutes        = 90;      // profile: 360 for DayTrade, 60–120 for Scalp15

input bool    EnableBreakEven       = true;
input double  BreakEvenAtTPPct      = 45.0;    // move SL to BE when % of TP reached (e.g., 40–50)
input double  BreakEvenBufferPips   = 0.5;     // small buffer beyond entry

//---------------------------
// Globals
//---------------------------
int      lastSignal         = 0;
int      tradesCount        = 0;
datetime lastM1Bar          = 0; // throttle manage to new M1
datetime lastSignalBarTime  = 0; // throttle entries to new TF_Signal bar

// Indicator handles (dynamic)
int hRSI_Sig        = INVALID_HANDLE;
int hRSI_Confirm    = INVALID_HANDLE;
int hMA20_Sig       = INVALID_HANDLE;
int hMA50_Sig       = INVALID_HANDLE;
int hMA20_Confirm   = INVALID_HANDLE;
int hMA50_Confirm   = INVALID_HANDLE;
int hMACD_HTF       = INVALID_HANDLE;
int hSTO_Sig        = INVALID_HANDLE;
int hBB_HTF         = INVALID_HANDLE;
int hADX_HTF        = INVALID_HANDLE;
int hATR_TF         = INVALID_HANDLE;

//---------------------------
// Profile helpers
//---------------------------
double GetATRSLMult()
{
   if(!AutoProfileParams) return ATR_SL_Multiplier;
   return (Profile==PROFILE_SCALP15 ? 1.2 : 1.6);
}
double GetTPMult()
{
   if(!AutoProfileParams) return TP_Multiplier;
   return (Profile==PROFILE_SCALP15 ? 1.4 : 2.0);
}
double GetMinATRPips()
{
   if(!AutoProfileParams) return MinATR_Pips;
   return (Profile==PROFILE_SCALP15 ? 8.0 : 12.0);
}
double GetADXThr()
{
   if(!AutoProfileParams) return ADX_Threshold;
   return (Profile==PROFILE_SCALP15 ? 20.0 : 22.0);
}
int GetConfirmBars()
{
   if(!AutoProfileParams) return ConfirmBars;
   return (Profile==PROFILE_SCALP15 ? 2 : 3);
}
double GetRiskPct()
{
   if(!AutoProfileParams) return RiskPercent;
   return (Profile==PROFILE_SCALP15 ? 0.30 : 0.50);
}
double GetMaxSpreadPips()
{
   if(!AutoProfileParams) return MaxSpreadPips;
   return (Profile==PROFILE_SCALP15 ? 2.2 : 3.0);
}
int GetMaxHoldMinutes()
{
   if(!AutoProfileParams) return MaxHoldMinutes;
   return (Profile==PROFILE_SCALP15 ? 90 : 360);
}
ENUM_TIMEFRAMES GetTF_Signal(){ return TF_Signal; }
ENUM_TIMEFRAMES GetTF_Confirm(){ return TF_Confirm; }
ENUM_TIMEFRAMES GetTF_HTF()    { return TF_HTF; }
ENUM_TIMEFRAMES GetTF_ATR()    { return TF_ATR; }

//---------------------------
// Utils
//---------------------------
double GetSafeLotSize(double requestedLot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(minLot <= 0 || maxLot <= 0 || step <= 0) return requestedLot;
   double lot = MathMax(minLot, MathMin(requestedLot, maxLot));
   lot = MathFloor(lot / step) * step;
   return MathMax(lot, minLot);
}

bool Copy1(const int handle,const int buffer,const int shift,double &val)
{
   val = EMPTY_VALUE;
   if(handle==INVALID_HANDLE) return false;
   double buf[]; ArraySetAsSeries(buf,true);
   if(CopyBuffer(handle,buffer,shift,1,buf)<=0) return false;
   val = buf[0];
   return true;
}

double PointsToPips(double points)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipFactor = (digits==3 || digits==5) ? 10.0 : 1.0;
   return (points/_Point)/pipFactor;
}
double PipsToPoints(double pips)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipFactor = (digits==3 || digits==5) ? 10.0 : 1.0;
   return pips * _Point * pipFactor;
}

// ATR in pips from chosen TF (shift>=1 avoids current-bar noise)
double GetATRInPips_TF(const int shift=1)
{
   double atr=EMPTY_VALUE;
   if(!Copy1(hATR_TF,0,shift,atr)) return EMPTY_VALUE;
   return PointsToPips(atr);
}

double CurrentSpreadPips()
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   return PointsToPips(MathAbs(ask-bid));
}

//---------------------------
// ADX / regime
//---------------------------
bool GetADX_HTF(double &adx,double &plusDI,double &minusDI,const int shift=1)
{
   if(hADX_HTF==INVALID_HANDLE) return false;
   if(!Copy1(hADX_HTF,0,shift,adx)) return false;
   if(!Copy1(hADX_HTF,1,shift,plusDI)) return false;
   if(!Copy1(hADX_HTF,2,shift,minusDI)) return false;
   return true;
}

//---------------------------
// News
//---------------------------
bool HasHighImpactNewsForCurrency(string currency, int minutes, bool upcoming=true)
{
   MqlCalendarEvent events[];
   int total = CalendarEventByCurrency(currency, events);
   if(total <= 0) return false;

   datetime now = TimeCurrent();
   datetime from = now - 7*24*60*60;
   datetime to   = now + 7*24*60*60;

   for(int i=0; i<total; i++)
   {
      if(events[i].importance != CALENDAR_IMPORTANCE_HIGH) continue;
      MqlCalendarValue values[];
      int vtotal = CalendarValueHistoryByEvent(events[i].id, values, from, to);
      if(vtotal <= 0) continue;

      for(int j=0; j<vtotal; j++)
      {
         datetime evTime = values[j].time;
         if(evTime == 0) continue;
         if(upcoming && evTime >= now && evTime - now <= minutes*60)
         { if(VerboseLogging) PrintFormat("Upcoming High-Impact News: %s (%s) at %s", events[i].name, currency, TimeToString(evTime, TIME_DATE|TIME_MINUTES)); return true; }
         if(!upcoming && evTime <= now && now - evTime <= minutes*60)
         { if(VerboseLogging) PrintFormat("Recent High-Impact News: %s (%s) at %s", events[i].name, currency, TimeToString(evTime, TIME_DATE|TIME_MINUTES)); return true; }
      }
   }
   return false;
}

bool IsUpcomingHighImpactNews(int lookaheadMinutes=30)
{ return HasHighImpactNewsForCurrency("GBP", lookaheadMinutes, true) || HasHighImpactNewsForCurrency("USD", lookaheadMinutes, true); }

bool IsRecentHighImpactNews(int lookbackMinutes=15)
{ return HasHighImpactNewsForCurrency("GBP", lookbackMinutes, false) || HasHighImpactNewsForCurrency("USD", lookbackMinutes, false); }

bool CheckWebhookBlock()
{
   if(StringLen(WebhookURL) < 8) return false;
   uchar result[]; char data[]; string headers="User-Agent: AlexPro-Agent\r\n"; string result_headers;
   int res = WebRequest("GET", WebhookURL, headers, WebhookTimeoutSec*1000, data, result, result_headers);
   if(res <= 0) { if(VerboseLogging) PrintFormat("WebRequest failed (err %d). Check allowed URLs.", GetLastError()); return false; }
   string body = StringToLower(CharArrayToString(result));
   if(StringFind(body,"block")>=0) return true;
   if(StringFind(body,"allow")>=0) return false;
   return false;
}

bool IsNewsTime(int lookaheadMinutes=30, int lookbackMinutes=15)
{
   if(!UseNewsFilter) return false;
   if(IsUpcomingHighImpactNews(lookaheadMinutes)) return true;
   if(IsRecentHighImpactNews(lookbackMinutes))   return true;
   if(EnableWebhook && CheckWebhookBlock()) { if(VerboseLogging) Print("Webhook blocked trading."); return true; }
   return false;
}

//---------------------------
/* Spike detector: compares the last H1 range against ATR on chosen TF.
   For scalping, this avoids trading right after outsized impulse bars. */
bool IsSpike()
{
   double atrPips = GetATRInPips_TF();
   if(atrPips == EMPTY_VALUE) return false;

   double high = iHigh(_Symbol, PERIOD_H1, 1);
   double low  = iLow(_Symbol, PERIOD_H1, 1);
   double movePips = PointsToPips(MathAbs(high - low));

   double threshold = MathMax(atrPips * SpikeATRMult, 10.0);
   bool spike = (movePips >= threshold);
   if(spike && VerboseLogging) PrintFormat("Spike detected: move=%.1f pips threshold=%.1f pips", movePips, threshold);
   return spike;
}

//---------------------------
// Swing High/Low (S/R)
//---------------------------
void GetRecentSwingHighLow(string symbol, ENUM_TIMEFRAMES tf, int lookback, double &hh, double &ll)
{
   hh = EMPTY_VALUE; ll = EMPTY_VALUE;
   int idxH = iHighest(symbol, tf, MODE_HIGH, lookback, 1);
   if(idxH >= 0) hh = iHigh(symbol, tf, idxH);
   int idxL = iLowest(symbol, tf, MODE_LOW, lookback, 1);
   if(idxL >= 0) ll = iLow(symbol, tf, idxL);
}

//---------------------------
// Indicator wrappers
//---------------------------
double RSI_Sig(int shift){ double v; if(!Copy1(hRSI_Sig,0,shift,v)) return EMPTY_VALUE; return v; }
double RSI_Confirm(int shift){ double v; if(!Copy1(hRSI_Confirm,0,shift,v)) return EMPTY_VALUE; return v; }
double MA20_Sig(int shift){ double v; if(!Copy1(hMA20_Sig,0,shift,v)) return EMPTY_VALUE; return v; }
double MA50_Sig(int shift){ double v; if(!Copy1(hMA50_Sig,0,shift,v)) return EMPTY_VALUE; return v; }
double MA20_Confirm(int shift){ double v; if(!Copy1(hMA20_Confirm,0,shift,v)) return EMPTY_VALUE; return v; }
double MA50_Confirm(int shift){ double v; if(!Copy1(hMA50_Confirm,0,shift,v)) return EMPTY_VALUE; return v; }

bool MACD_HTF(int shift,double &macd,double &sig)
{
   if(hMACD_HTF==INVALID_HANDLE) return false;
   if(!Copy1(hMACD_HTF,0,shift,macd)) return false;
   if(!Copy1(hMACD_HTF,1,shift,sig))  return false;
   return true;
}

bool STO_Sig(int shift,double &k,double &d)
{
   if(hSTO_Sig==INVALID_HANDLE) return false;
   if(!Copy1(hSTO_Sig,0,shift,k)) return false; // %K
   if(!Copy1(hSTO_Sig,1,shift,d)) return false; // %D
   return true;
}

bool BB_HTF(int shift,double &upper,double &middle,double &lower)
{
   if(hBB_HTF==INVALID_HANDLE) return false;
   if(!Copy1(hBB_HTF,0,shift,upper))  return false;
   if(!Copy1(hBB_HTF,1,shift,middle)) return false;
   if(!Copy1(hBB_HTF,2,shift,lower))  return false;
   return true;
}

// Directional bars on any TF
int CountDirectionalBars(string symbol,ENUM_TIMEFRAMES tf,int bars,int dir){
    int cnt=0;
    for(int i=1;i<=bars;i++){
        double o=iOpen(symbol,tf,i),c=iClose(symbol,tf,i);
        if(dir>0 && c>o) cnt++;
        if(dir<0 && c<o) cnt++;
    }
    return cnt;
}

//---------------------------
// GenerateSignal (weighted, M15 focus)
//---------------------------
int GenerateSignal(string &reason, double &confidence)
{
    reason = ""; confidence = 0.0;
    double totalWeight=0.0, bull=0.0, bear=0.0;

    // RSI + MA (Signal TF) — 0.25
    double rsiSig  = RSI_Sig(1);
    double maFast  = MA20_Sig(1);
    double maSlow  = MA50_Sig(1);
    if(rsiSig!=EMPTY_VALUE && maFast!=EMPTY_VALUE && maSlow!=EMPTY_VALUE){
        const double w=0.25; totalWeight+=w;
        if(rsiSig>55 && maFast>maSlow){ bull+=w; reason+="[RSI/MA Sig bull] "; }
        else if(rsiSig<45 && maFast<maSlow){ bear+=w; reason+="[RSI/MA Sig bear] "; }
    }

    // MACD (HTF) — 0.25
    double macd, macdSig;
    if(MACD_HTF(1,macd,macdSig)){
        const double w=0.25; totalWeight+=w;
        if(macd>macdSig){ bull+=w; reason+="[MACD HTF bull] "; }
        else if(macd<macdSig){ bear+=w; reason+="[MACD HTF bear] "; }
    }

    // Stochastic (Signal TF) — 0.15
    double k,d;
    if(STO_Sig(1,k,d)){
        const double w=0.15; totalWeight+=w;
        if(k<20 && d<20){ bull+=w; reason+="[Stoch Sig OS bull] "; }
        else if(k>80 && d>80){ bear+=w; reason+="[Stoch Sig OB bear] "; }
    }

    // Bollinger Bands (HTF) — 0.20
    double upper, mid, lower;
    if(BB_HTF(1,upper,mid,lower)){
        double closePrice = iClose(_Symbol, GetTF_HTF(), 1);
        const double w=0.20; totalWeight+=w;
        if(closePrice<=lower){ bull+=w; reason+="[BB HTF lower touch] "; }
        else if(closePrice>=upper){ bear+=w; reason+="[BB HTF upper touch] "; }
    }

    // Momentum confirm (Confirm TF) — 0.15
    int dir = (bull>bear? 1 : (bear>bull? -1 : 0));
    if(dir!=0){
        int confirmBars = GetConfirmBars();
        int confDirCount = CountDirectionalBars(_Symbol, GetTF_Confirm(), confirmBars, dir);
        const double w=0.15; totalWeight+=w;
        if(confDirCount >= MathMax(1, confirmBars-1)){
            if(dir>0) bull+=w; else bear+=w; reason+="[Confirm mom strong] ";
        }else{
            reason+="[Confirm mom weak] ";
        }
    }

    // Confidence
    if(totalWeight>0){
        if(bull>bear) confidence = (bull/totalWeight)*100.0;
        else if(bear>bull) confidence = (bear/totalWeight)*100.0;
        else confidence = 50.0;
    }

    if(bull>bear) return 1;
    if(bear>bull) return -1;
    return 0;
}

//---------------------------
// Session check
//---------------------------
bool InTradingSession()
{
    MqlDateTime dt; TimeToStruct(TimeTradeServer(), dt);
    int serverGMTOffset = (int)((TimeTradeServer() - TimeGMT()) / 3600);
    int hourGMT = dt.hour - serverGMTOffset;
    if(hourGMT < 0) hourGMT += 24;
    if(hourGMT >= 24) hourGMT -= 24;
    bool inLondon = (hourGMT >= LondonStartGMT && hourGMT <= LondonEndGMT);
    bool inNY     = (hourGMT >= NYStartGMT && hourGMT <= NYEndGMT);
    return (inLondon || inNY);
}

int MinutesToSessionEndGMT()
{
    MqlDateTime dt; TimeToStruct(TimeTradeServer(), dt);
    int serverGMTOffset = (int)((TimeTradeServer() - TimeGMT()) / 3600);
    int hourGMT = dt.hour - serverGMTOffset;
    if(hourGMT < 0) hourGMT += 24;
    if(hourGMT >= 24) hourGMT -= 24;

    int curMinsGMT = hourGMT*60 + dt.min;
    int endLondon  = LondonEndGMT*60;
    int endNY      = NYEndGMT*60;

    int distL = endLondon - curMinsGMT;
    int distN = endNY - curMinsGMT;
    int best = 1000000;
    if(distL>=0) best = MathMin(best, distL);
    if(distN>=0) best = MathMin(best, distN);
    return (best==1000000 ? -1 : best);
}

//---------------------------
// ML CSV logging
//---------------------------
void LogTradeCSV(string tag, string side, double lot, double entry, double sl, double tp, string reason)
{
    if(!LogMLToCSV) return;
    int handle = FileOpen(CsvFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
    if(handle == INVALID_HANDLE)
    {
        handle = FileOpen(CsvFileName, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
        if(handle == INVALID_HANDLE){ if(VerboseLogging) Print("Failed to open CSV: ", CsvFileName); return; }
        FileWrite(handle, "timestamp,tag,symbol,side,lot,entry,sl,tp,reason,atr_pips,adx_htf,rsi_sig,ma20_sig,ma50_sig,hh,ll");
    }
    else { FileSeek(handle, 0, SEEK_END); }

    double plusDI, minusDI, adx;
    double atrPips = GetATRInPips_TF();
    if(!GetADX_HTF(adx,plusDI,minusDI,1)) adx=EMPTY_VALUE;
    double rsiSig = RSI_Sig(1);
    double ma20   = MA20_Sig(1);
    double ma50   = MA50_Sig(1);
    double hh=EMPTY_VALUE, ll=EMPTY_VALUE;
    GetRecentSwingHighLow(_Symbol, GetTF_Signal(), SR_LookbackBars, hh, ll);

    string line = StringFormat("%s,%s,%s,%s,%.2f,%.5f,%.5f,%.5f,%s,%.2f,%.2f,%.2f,%.5f,%.5f,%.5f,%.5f",
                              TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                              tag,_Symbol,side,lot,entry,sl,tp,reason,
                              (atrPips==EMPTY_VALUE?0.0:atrPips),
                              (adx==EMPTY_VALUE?0.0:adx),
                              (rsiSig==EMPTY_VALUE?0.0:rsiSig),
                              (ma20==EMPTY_VALUE?0.0:ma20),
                              (ma50==EMPTY_VALUE?0.0:ma50),
                              (hh==EMPTY_VALUE?0.0:hh),
                              (ll==EMPTY_VALUE?0.0:ll));
    FileWrite(handle, line);
    FileClose(handle);
}

//---------------------------
// Risk lot sizing
//---------------------------
double GetRiskLotSize(double stopDistPriceUnits)
{
    if(stopDistPriceUnits <= 0) return 0;
    // use equity for safer sizing during drawdown
    double riskAmount = AccountInfoDouble(ACCOUNT_EQUITY) * (GetRiskPct() / 100.0);
    if(riskAmount <= 0) return 0;

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tickValue <= 0 || tickSize <= 0) return 0;

    double valuePerPriceUnitPerLot = tickValue / tickSize;
    double rawLot = riskAmount / (stopDistPriceUnits * valuePerPriceUnitPerLot);
    return GetSafeLotSize(rawLot);
}

//---------------------------
// Daily governance
//---------------------------
datetime TodayStart()
{
   string d = TimeToString(TimeCurrent(), TIME_DATE);
   return (datetime)StringToTime(d); // 00:00 server time
}

int CountTradesToday()
{
   if(!UseDailyMaxTrades) return 0;
   datetime t0 = TodayStart();
   HistorySelect(t0, TimeCurrent());
   int cnt=0;
   int total = (int)HistoryDealsTotal();
   for(int i=total-1;i>=0;i--){
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket==0 || !HistoryDealSelect(ticket)) continue;
      if((ulong)HistoryDealGetInteger(DEAL_MAGIC)!=ExpertMagic) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      datetime t = (datetime)HistoryDealGetInteger(DEAL_TIME);
      if(t >= t0) cnt++;
   }
   return cnt;
}

double DailyRealizedPL()
{
   datetime t0 = TodayStart();
   HistorySelect(t0, TimeCurrent());
   double pl=0.0;
   int total = (int)HistoryDealsTotal();
   for(int i=total-1;i>=0;i--){
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket==0 || !HistoryDealSelect(ticket)) continue;
      if((ulong)HistoryDealGetInteger(DEAL_MAGIC)!=ExpertMagic) continue;
      double p = HistoryDealGetDouble(DEAL_PROFIT); // includes swap/commission
      datetime t = (datetime)HistoryDealGetInteger(DEAL_TIME);
      if(t >= t0) pl += p;
   }
   return pl;
}

bool DailyGuardsBlock(string &out)
{
   out="";
   if(UseDailyMaxTrades && CountTradesToday() >= DailyMaxTrades){ out="Daily max trades reached"; return true; }
   if(UseDailyLossLimit){
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      double startEqApprox = bal; // conservative proxy
      double maxLoss = startEqApprox * (DailyLossLimitPct/100.0);
      double realized = DailyRealizedPL();
      if(realized <= -maxLoss){ out=StringFormat("Daily loss limit hit (%.2f%%)", DailyLossLimitPct); return true; }
   }
   return false;
}

//---------------------------
// Filters
//---------------------------
bool CanPassFilters(const int origSignal, string &outReason)
{
    outReason = "";
    if(origSignal == 0) { outReason = "No signal"; return false; }

    if(!InTradingSession()){ outReason="Outside trading sessions"; if(VerboseLogging) Print(outReason); return false; }

    if(FlattenBeforeSessionEnd){
        int minsToEnd = MinutesToSessionEndGMT();
        if(minsToEnd>=0 && minsToEnd <= FlattenMinutesBeforeEnd){ outReason="Near session end"; if(VerboseLogging) Print(outReason); return false; }
    }

    if(IsNewsTime(NewsLookaheadMin, NewsLookbackMin)){ outReason="Blocked by high-impact news"; if(VerboseLogging) Print(outReason); return false; }

    if(UseSpikeFilter && IsSpike()){ outReason="Blocked by spike"; if(VerboseLogging) Print(outReason); return false; }

    // Spread filter for scalping
    if(UseSpreadFilter && CurrentSpreadPips() > GetMaxSpreadPips()){
        outReason=StringFormat("Spread too high (%.1f > %.1f pips)", CurrentSpreadPips(), GetMaxSpreadPips());
        if(VerboseLogging) Print(outReason); return false;
    }

    double atrPips = GetATRInPips_TF();
    if(atrPips == EMPTY_VALUE){ outReason="ATR not ready"; return false; }
    if(atrPips < GetMinATRPips()){ outReason=StringFormat("ATR too low (%.1f < %.1f pips)", atrPips, GetMinATRPips()); if(VerboseLogging) Print(outReason); return false; }

    double hh,ll; GetRecentSwingHighLow(_Symbol, GetTF_Signal(), SR_LookbackBars, hh, ll);
    double price = (origSignal > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double tolPrice = SR_ATR_Factor * atrPips * _Point * ((int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)==3 || (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)==5 ? 10.0 : 1.0);
    if(origSignal > 0 && hh!=EMPTY_VALUE && MathAbs(price - hh) <= tolPrice){ outReason="Near resistance (Sig TF)"; if(VerboseLogging) Print(outReason); return false; }
    if(origSignal < 0 && ll!=EMPTY_VALUE && MathAbs(price - ll) <= tolPrice){ outReason="Near support (Sig TF)";    if(VerboseLogging) Print(outReason); return false; }

    if(UseADXFilter){
        double adx,plusDI,minusDI;
        if(!GetADX_HTF(adx,plusDI,minusDI,1)){ outReason="ADX not ready"; if(VerboseLogging) Print(outReason); return false; }
        if(ADX_RequireTrending && adx < GetADXThr()){ outReason=StringFormat("ADX too low (%.2f < %.2f)", adx, GetADXThr()); if(VerboseLogging) Print(outReason); return false; }
        if(origSignal>0 && minusDI>plusDI){ outReason="DI misaligned for BUY"; if(VerboseLogging) Print(outReason); return false; }
        if(origSignal<0 && plusDI>minusDI){ outReason="DI misaligned for SELL"; if(VerboseLogging) Print(outReason); return false; }
    }

    // RSI momentum on Confirm TF
    double rsiPrev = RSI_Confirm(2), rsiNow = RSI_Confirm(1);
    if(rsiPrev!=EMPTY_VALUE && rsiNow!=EMPTY_VALUE){
        if(origSignal > 0 && rsiNow < rsiPrev){ outReason="RSI weakening (BUY)"; if(VerboseLogging) Print(outReason); return false; }
        if(origSignal < 0 && rsiNow > rsiPrev){ outReason="RSI weakening (SELL)"; if(VerboseLogging) Print(outReason); return false; }
    }

    int cnt = CountDirectionalBars(_Symbol, GetTF_Confirm(), GetConfirmBars(), origSignal>0?1:-1);
    if(cnt < MathMax(1, GetConfirmBars()-1)){ outReason="Not enough confirming bars"; if(VerboseLogging) Print(outReason); return false; }

    // Daily governance
    if(UseDailyMaxTrades || UseDailyLossLimit){
        string why="";
        if(DailyGuardsBlock(why)){ outReason=why; if(VerboseLogging) Print(outReason); return false; }
    }

    outReason = "OK ✅";
    return true;
}

//---------------------------
// Trade Execution
//---------------------------
void EnforceStopsToBrokerRules(int dir, double entry, double &sl, double &tp)
{
    int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    int freeze     = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
    double minDist = (stopsLevel + freeze) * _Point;

    if(dir>0){ // BUY
        if(entry - sl < minDist)  sl = entry - minDist;
        if(tp - entry < minDist)  tp = entry + minDist;
    }else{     // SELL
        if(sl - entry < minDist)  sl = entry + minDist;
        if(entry - tp < minDist)  tp = entry - minDist;
    }
    sl = NormalizeDouble(sl,_Digits);
    tp = NormalizeDouble(tp,_Digits);
}

bool IsNewSignalBar()
{
    datetime t = iTime(_Symbol, GetTF_Signal(), 0);
    if(lastSignalBarTime == 0 || t != lastSignalBarTime){
        lastSignalBarTime = t; 
        return true;
    }
    return false;
}

void TryOpenTrade(const int signal, const string sigReason, const double confidence)
{
    // Only evaluate entries on a NEW Signal TF bar
    if(!IsNewSignalBar()) return;

    string reason = "";
    if(!CanPassFilters(signal, reason))
    { if(VerboseLogging) PrintFormat("Signal blocked: %s (from: %s)", reason, sigReason); return; }

    if(signal != lastSignal){ lastSignal = signal; tradesCount = 0; }
    if(tradesCount >= MaxTradesPerSignal){ if(VerboseLogging) Print("Max trades reached for current signal."); return; }

    double atrPips = GetATRInPips_TF();
    if(atrPips == EMPTY_VALUE) { Print("ATR not ready for trade."); return; }

    double atrSLmult = GetATRSLMult();
    double tpMult    = GetTPMult();

    // Convert ATR pips -> price distance
    double stopDistPrice = PipsToPoints(atrPips * atrSLmult);
    double priceAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double priceBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double entry = (signal>0 ? priceAsk : priceBid);

    double sl = (signal>0 ? entry - stopDistPrice : entry + stopDistPrice);
    double tp = (signal>0 ? entry + tpMult*stopDistPrice : entry - tpMult*stopDistPrice);

    EnforceStopsToBrokerRules(signal, entry, sl, tp);

    double safeLot = UseRiskPercent ? GetRiskLotSize(stopDistPrice) : GetSafeLotSize(LotSize);
    if(safeLot <= 0) { if(VerboseLogging) Print("Lot sizing failed."); return; }

    trade.SetExpertMagicNumber(ExpertMagic);

    // Include profile info in comment (helps BE logic if needed later)
    string cmt = (signal>0?"Buy":"Sell");
    cmt += StringFormat("|Prof=%s|SLx=%.2f|TPx=%.2f", (Profile==PROFILE_SCALP15?"Scalp15":"DayTrade"), atrSLmult, tpMult);

    bool sent=false;
    if(signal>0) sent = trade.Buy(safeLot, _Symbol, 0.0, sl, tp, cmt);
    else         sent = trade.Sell(safeLot, _Symbol, 0.0, sl, tp, cmt);

    int rc = trade.ResultRetcode();
    if(!sent || (rc!=10009 && rc!=10008)) // DEAL_PLACED / ORDER_PLACED
    {
        if(VerboseLogging) PrintFormat("Order send failed (retcode=%d, lastErr=%d)", rc, GetLastError());
        return;
    }

    tradesCount++;
    PrintFormat("Placed %s at %.5f | SL=%.5f | TP=%.5f | lot=%.2f | Strength=%.1f%% | %s",
                (signal>0?"BUY":"SELL"), entry, sl, tp, safeLot, confidence,
                (Profile==PROFILE_SCALP15?"Scalp15":"DayTrade"));

    LogTradeCSV("OPEN", (signal>0?"BUY":"SELL"), safeLot, entry, sl, tp, sigReason);
}

//---------------------------
// Position Management
//---------------------------
bool ForceClosePosition(ulong ticket)
{
   if(ticket==0 || !PositionSelectByTicket(ticket)) return false;
   trade.SetExpertMagicNumber(ExpertMagic);
   // Try by ticket (hedging) then by symbol (netting)
   if(trade.PositionClose(ticket)) return true;
   return trade.PositionClose(PositionGetString(POSITION_SYMBOL));
}

void ManagePositions()
{
    int total = PositionsTotal();
    for(int i = total - 1; i >= 0; i--){
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if((ulong)PositionGetInteger(POSITION_MAGIC) != ExpertMagic) continue;

        double vol   = PositionGetDouble(POSITION_VOLUME);
        double entry = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl    = PositionGetDouble(POSITION_SL);
        double tp    = PositionGetDouble(POSITION_TP);
        long type    = (long)PositionGetInteger(POSITION_TYPE);
        int dir = (type == POSITION_TYPE_BUY ? 1 : -1);
        double mkt = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        // Time-based exit
        if(UseMaxHoldMinutes){
            datetime tOpen = (datetime)PositionGetInteger(POSITION_TIME);
            if(tOpen>0){
                int aliveMin = (int)((TimeCurrent() - tOpen)/60);
                if(aliveMin >= GetMaxHoldMinutes()){
                    if(VerboseLogging) PrintFormat("Max hold reached (%d min) -> closing ticket %I64u", GetMaxHoldMinutes(), ticket);
                    if(ForceClosePosition(ticket)){
                        LogTradeCSV("TIME_EXIT", (dir>0?"BUY":"SELL"), vol, mkt, sl, tp, "MaxHold");
                        continue;
                    }
                }
            }
        }

        // Flatten near session end (safety)
        if(FlattenBeforeSessionEnd){
            int minsToEnd = MinutesToSessionEndGMT();
            if(minsToEnd>=0 && minsToEnd <= FlattenMinutesBeforeEnd){
                if(VerboseLogging) PrintFormat("Flatten before session end (%d min) -> closing ticket %I64u", minsToEnd, ticket);
                if(ForceClosePosition(ticket)){
                    LogTradeCSV("FLATTEN", (dir>0?"BUY":"SELL"), vol, mkt, sl, tp, "Session End");
                    continue;
                }
            }
        }

        // Partial close at 50% of TP distance (kept)
        double profitPoints = MathAbs(mkt - entry);
        double targetPoints = MathAbs(tp  - entry);
        if(targetPoints > 1e-12 && profitPoints >= 0.5 * targetPoints && vol > 0){
            double pctClose = PartialClosePct / 100.0;
            double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            double rawClose = MathFloor(vol * pctClose / step) * step;
            double closeVol = MathMax(minVol, rawClose);
            if(closeVol >= vol) closeVol = MathMax(minVol, vol - step);
            if(closeVol > 0 && closeVol <= vol - 1e-12){
                if(trade.PositionClosePartial(ticket, closeVol)){
                    PrintFormat("Partial close: ticket=%I64u vol=%.2f", ticket, closeVol);
                    LogTradeCSV("PARTIAL_CLOSE", (dir>0?"BUY":"SELL"), closeVol, mkt, sl, tp, "Partial at half TP");
                }
            }
        }

        // Break-even move
        if(EnableBreakEven && targetPoints>0.0){
            double beTrigger = (BreakEvenAtTPPct/100.0) * targetPoints;
            if(profitPoints >= beTrigger){
                double bePrice = (dir>0 ? entry + PipsToPoints(BreakEvenBufferPips) : entry - PipsToPoints(BreakEvenBufferPips));
                double newSL = sl;
                if(dir>0){
                    if(sl < bePrice){
                        newSL = bePrice;
                    }
                }else{
                    if(sl > bePrice || sl==0.0){
                        newSL = bePrice;
                    }
                }
                if(MathAbs(newSL - sl) > (_Point*0.5)){
                    trade.PositionModify(ticket, NormalizeDouble(newSL,_Digits), tp);
                }
            }
        }

        // Trailing stop based on recent lows/highs on Confirm TF (tighter for scalps)
        double newSL = (dir > 0) ? iLow(_Symbol, GetTF_Confirm(), 1) : iHigh(_Symbol, GetTF_Confirm(), 1);
        for(int b=2; b<=3; b++){
            double ext = (dir > 0) ? iLow(_Symbol, GetTF_Confirm(), b) : iHigh(_Symbol, GetTF_Confirm(), b);
            newSL = (dir > 0) ? MathMin(newSL, ext) : MathMax(newSL, ext);
        }

        double stopPointsMin = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

        if(dir > 0){
            if((sl==0 || newSL > sl + 1e-12) && (mkt - newSL >= stopPointsMin + _Point)){
                double effectiveSL = MathMax(newSL, mkt - (stopPointsMin + 1.0*_Point));
                trade.PositionModify(ticket, NormalizeDouble(effectiveSL,_Digits), tp);
            }
        } else {
            if((sl==0 || newSL < sl - 1e-12) && (newSL - mkt >= stopPointsMin + _Point)){
                double effectiveSL = MathMin(newSL, mkt + (stopPointsMin + 1.0*_Point));
                trade.PositionModify(ticket, NormalizeDouble(effectiveSL,_Digits), tp);
            }
        }
    }
}

//---------------------------
// SR lines & Dashboard
//---------------------------
void DrawSRLines(double hh, double ll)
{
    if(!ShowSRLines) return;
    static string resLine = "SR_Resistance";
    static string supLine = "SR_Support";
    if(hh != EMPTY_VALUE){
        if(ObjectFind(0, resLine) < 0) ObjectCreate(0, resLine, OBJ_HLINE, 0, 0, hh);
        else ObjectSetDouble(0, resLine, OBJPROP_PRICE, hh);
        ObjectSetInteger(0, resLine, OBJPROP_COLOR, clrRed);
        ObjectSetInteger(0, resLine, OBJPROP_WIDTH, 1);
        ObjectSetInteger(0, resLine, OBJPROP_STYLE, STYLE_SOLID);
    }
    if(ll != EMPTY_VALUE){
        if(ObjectFind(0, supLine) < 0) ObjectCreate(0, supLine, OBJ_HLINE, 0, 0, ll);
        else ObjectSetDouble(0, supLine, OBJPROP_PRICE, ll);
        ObjectSetInteger(0, supLine, OBJPROP_COLOR, clrGreen);
        ObjectSetInteger(0, supLine, OBJPROP_WIDTH, 1);
        ObjectSetInteger(0, supLine, OBJPROP_STYLE, STYLE_SOLID);
    }
}

void DrawLabel(const string name,const int x,const int y,const color clr,const string txt)
{
    if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);
    ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
    ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
    ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
    ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
    ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
    ObjectSetString(0,name,OBJPROP_TEXT,txt);
}

void UpdateDashboard(string status="Idle", string reason="", int signal=0)
{
    string prefix = "AlexProUI_";
    double plusDI, minusDI, adx;
    double rsi = RSI_Sig(1);
    double ma20= MA20_Sig(1);
    double ma50= MA50_Sig(1);
    if(!GetADX_HTF(adx,plusDI,minusDI,1)) adx=EMPTY_VALUE;
    double atrPips  = GetATRInPips_TF(); if(atrPips==EMPTY_VALUE) atrPips=0;

    int activeTrades = 0;
    int total = PositionsTotal();
    for(int i = total-1; i>=0; --i){
        ulong tk = PositionGetTicket(i);
        if(tk==0 || !PositionSelectByTicket(tk)) continue;
        if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
        if((ulong)PositionGetInteger(POSITION_MAGIC)!=ExpertMagic) continue;
        activeTrades++;
    }

    DrawLabel(prefix+"Status",100,40,(signal>0?clrGreen:(signal<0?clrRed:clrYellow)),
              StringFormat("Status: %s (%s)", status, reason));

    DrawLabel(prefix+"ATR",20,65,clrAqua, StringFormat("ATR (%s): %.1f pips", EnumToString(GetTF_ATR()), atrPips));
    string rsiTrend = (rsi>50 ? "↑ Bullish" : "↓ Bearish");
    string maAlign  = (ma20>ma50 ? "✅ Uptrend" : "❌ Downtrend");
    string adxStr   = (adx!=EMPTY_VALUE ? StringFormat("%.1f",adx) : "N/A");

    DrawLabel(prefix+"Trend",20,90,clrWhite,
              StringFormat("Profile:%s | SigTF:%s | ConfTF:%s | HTF:%s",
                           (Profile==PROFILE_SCALP15?"Scalp15":"DayTrade"),
                           EnumToString(GetTF_Signal()),
                           EnumToString(GetTF_Confirm()),
                           EnumToString(GetTF_HTF())));

    DrawLabel(prefix+"Trend2",20,115,clrWhite,
              StringFormat("RSI: %.1f %s | MA: %s | ADX(HTF): %s | Spread: %.1f p",
                           rsi, rsiTrend, maAlign, adxStr, CurrentSpreadPips()));

    DrawLabel(prefix+"Signal",20,140,(signal>0?clrGreen:(signal<0?clrRed:clrYellow)),
              StringFormat("Signal: %s | SLx:%.2f TPx:%.2f | MinATR:%.1f",
                           (signal>0?"BUY":(signal<0?"SELL":"None")), GetATRSLMult(), GetTPMult(), GetMinATRPips()));

    DrawLabel(prefix+"ActiveTrades",20,165,clrYellow,
              StringFormat("Active Trades (%s/%I64u): %d", _Symbol, ExpertMagic, activeTrades));

    string sessionStr = InTradingSession() ? "Open" : "Closed";
    string newsStr    = IsNewsTime(NewsLookaheadMin, NewsLookbackMin) ? "High Impact News ⚠" : "No News";
    DrawLabel(prefix+"News",20,190,clrOrange, StringFormat("Session: %s | News: %s", sessionStr, newsStr));
}

//---------------------------
// OnTick / OnInit / OnDeinit
//---------------------------
void OnTick()
{
    // Manage every new M1 bar
    datetime curM1 = iTime(_Symbol, PERIOD_M1, 0);
    if(curM1 != lastM1Bar){
        lastM1Bar = curM1;

        // Draw SR from HTF for context
        double hh, ll; GetRecentSwingHighLow(_Symbol, GetTF_HTF(), SR_LookbackBars, hh, ll);
        DrawSRLines(hh, ll);

        ManagePositions();
    }

    // Entry logic (gated to Signal TF new bar inside TryOpenTrade)
    string sigReason; double confidence=0.0;
    int signal = GenerateSignal(sigReason, confidence);

    string dashReason = sigReason;
    if(confidence > 0.0 && confidence <= 100.0) dashReason += StringFormat(" | conf: %.1f%%", confidence);

    if(signal != 0) TryOpenTrade(signal, sigReason, confidence);

    UpdateDashboard(signal==0?"Idle":"Running", dashReason, signal);
}

int OnInit()
{
    Print("AlexPro v2.20 initialized. ExpertMagic=", ExpertMagic, " | Profile=", (Profile==PROFILE_SCALP15?"Scalp15":"DayTrade"));

    // Build indicator handles using configured TFs
    hRSI_Sig      = iRSI(_Symbol, GetTF_Signal(),  HTF_RSI_Period, PRICE_CLOSE);
    hRSI_Confirm  = iRSI(_Symbol, GetTF_Confirm(), HTF_RSI_Period, PRICE_CLOSE);

    hMA20_Sig     = iMA(_Symbol, GetTF_Signal(),  HTF_MA_Fast, 0, MODE_SMA, PRICE_CLOSE);
    hMA50_Sig     = iMA(_Symbol, GetTF_Signal(),  HTF_MA_Slow, 0, MODE_SMA, PRICE_CLOSE);
    hMA20_Confirm = iMA(_Symbol, GetTF_Confirm(), HTF_MA_Fast, 0, MODE_SMA, PRICE_CLOSE);
    hMA50_Confirm = iMA(_Symbol, GetTF_Confirm(), HTF_MA_Slow, 0, MODE_SMA, PRICE_CLOSE);

    hMACD_HTF     = iMACD(_Symbol, GetTF_HTF(), 12, 26, 9, PRICE_CLOSE);
    hSTO_Sig      = iStochastic(_Symbol, GetTF_Signal(), 5, 3, 3, MODE_SMA, STO_LOWHIGH);

    hBB_HTF       = iBands(_Symbol, GetTF_HTF(), 50, 2.0, 0, PRICE_CLOSE);

    hADX_HTF      = iADX(_Symbol, GetTF_HTF(), ADX_Period);
    hATR_TF       = iATR(_Symbol, GetTF_ATR(), ATR_Period);

    if(hRSI_Sig==INVALID_HANDLE || hRSI_Confirm==INVALID_HANDLE ||
       hMA20_Sig==INVALID_HANDLE || hMA50_Sig==INVALID_HANDLE ||
       hMA20_Confirm==INVALID_HANDLE || hMA50_Confirm==INVALID_HANDLE ||
       hMACD_HTF==INVALID_HANDLE || hSTO_Sig==INVALID_HANDLE ||
       hBB_HTF==INVALID_HANDLE  || hADX_HTF==INVALID_HANDLE ||
       hATR_TF==INVALID_HANDLE)
    {
        Print("Warning: one or more indicator handles are invalid. Check symbols/timeframes.");
    }

    lastM1Bar = iTime(_Symbol, PERIOD_M1, 0);
    lastSignalBarTime = iTime(_Symbol, GetTF_Signal(), 0);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    int hs[] = {hRSI_Sig,hRSI_Confirm,hMA20_Sig,hMA50_Sig,hMA20_Confirm,hMA50_Confirm,hMACD_HTF,hSTO_Sig,hBB_HTF,hADX_HTF,hATR_TF};
    for(int i=0;i<ArraySize(hs);i++) if(hs[i]!=INVALID_HANDLE) IndicatorRelease(hs[i]);

    // Clean UI objects
    string prefix = "AlexProUI_";
    string objs[] = { "Status","ATR","Trend","Trend2","Signal","ActiveTrades","News","SR_Resistance","SR_Support" };
    for(int j=0;j<ArraySize(objs);j++) ObjectDelete(0, (j<7? prefix+objs[j] : objs[j]));
}
