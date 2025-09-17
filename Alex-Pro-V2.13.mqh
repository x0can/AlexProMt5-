//+------------------------------------------------------------------+
//| AlexPro Full Expert Advisor (v2.13)                              |
//| Strategy: RSI(21)+MA(20/50)+ATR stops+SR+HTF+Momentum            |
//| Additions: % risk sizing, ADX regime filter, webhook fallback,   |
//|            ML CSV logging                                        |
//| Platform: MetaTrader 5                                           |
//+------------------------------------------------------------------+
#property copyright "AlexPro"
#property version   "2.13"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//---------------------------
// Inputs
//---------------------------
input ulong   ExpertMagic       = 202509121996;
input double  LotSize           = 1.0;
input bool    UseRiskPercent    = true;
input double  RiskPercent       = 1.0;
input int     ATR_Period        = 14;
input double  ATR_SL_Multiplier = 2.0;
input int     MaxTradesPerSignal= 2;
input int     ConfirmBars       = 3;
input int     SR_LookbackBars   = 20;
input double  SR_ATR_Factor     = 0.5;
input double  MinATR_Pips       = 15.0;
input int     HTF_RSI_Period    = 21;
input int     HTF_MA_Fast       = 20;
input int     HTF_MA_Slow       = 50;
input int     ATR_Avg_Lookback  = 20;
input double  PartialClosePct   = 50.0;

input bool    UseNewsFilter     = true;
input int     NewsLookaheadMin  = 30;
input int     NewsLookbackMin   = 15;

input bool    UseSpikeFilter    = true;
input double  SpikeATRMult      = 3.0;

input bool    UseADXFilter      = true;
input int     ADX_Period        = 14;
input double  ADX_Threshold     = 25.0;
input bool    ADX_RequireTrending = true;

input bool    EnableWebhook     = true;
input string  WebhookURL        = "https://example.com/alexpro-webhook";
input int     WebhookTimeoutSec = 10;

input bool    LogMLToCSV        = true;
input string  CsvFileName       = "AlexPro_trades.csv"; // Common\Files

input bool    ShowSRLines       = true;
input bool    VerboseLogging    = true;

// Session Times (GMT hours)
input int     LondonStartGMT    = 7;
input int     LondonEndGMT      = 16;
input int     NYStartGMT        = 12;
input int     NYEndGMT          = 21;

//---------------------------
// Globals
//---------------------------
int    lastSignal = 0;
int    tradesCount = 0;
datetime lastM1Bar = 0; // throttle heavy logic to new M1 bars

// Indicator handles (reused)
int hRSI_M1   = INVALID_HANDLE;
int hRSI_M5   = INVALID_HANDLE;
int hMA20_M1  = INVALID_HANDLE;
int hMA50_M1  = INVALID_HANDLE;
int hMA20_M5  = INVALID_HANDLE;
int hMA50_M5  = INVALID_HANDLE;
int hMACD_H1  = INVALID_HANDLE;
int hSTO_M15  = INVALID_HANDLE;
int hBB_H1    = INVALID_HANDLE;
int hADX_H1   = INVALID_HANDLE;
int hATR_H1   = INVALID_HANDLE;

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

// ATR in pips (H1)
double GetATRInPips_H1(const int shift=1) // use shift=1 to avoid current-bar noise
{
   double atr=EMPTY_VALUE;
   if(!Copy1(hATR_H1,0,shift,atr)) return EMPTY_VALUE;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipFactor = (digits == 3 || digits == 5) ? 10.0 : 1.0;
   return (atr/_Point)/pipFactor;
}

//---------------------------
// ADX / regime
//---------------------------
bool GetADX_H1(double &adx,double &plusDI,double &minusDI,const int shift=1)
{
   if(hADX_H1==INVALID_HANDLE) return false;
   if(!Copy1(hADX_H1,0,shift,adx)) return false;
   if(!Copy1(hADX_H1,1,shift,plusDI)) return false;
   if(!Copy1(hADX_H1,2,shift,minusDI)) return false;
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
// Spike detector (H4 range vs H1 ATR)
//---------------------------
bool IsSpike()
{
   double atrH1 = GetATRInPips_H1();
   if(atrH1 == EMPTY_VALUE) return false;

   double high = iHigh(_Symbol, PERIOD_H4, 1);
   double low  = iLow(_Symbol, PERIOD_H4, 1);
   double movePips = MathAbs(high - low) / _Point;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5) movePips /= 10.0;

   double threshold = MathMax(atrH1 * SpikeATRMult, 10.0);
   bool spike = (movePips >= threshold);
   if(spike && VerboseLogging) PrintFormat("Spike detected: move=%.1f pips threshold=%.1f pips", movePips, threshold);
   return spike;
}

//---------------------------
// Swing High/Low (S/R)
//---------------------------
void GetRecentSwingHighLow(string symbol, ENUM_TIMEFRAMES tf,int lookback,double &hh,double &ll)
{
    hh = EMPTY_VALUE; ll = EMPTY_VALUE;
    int idxH = iHighest(symbol, tf, MODE_HIGH, lookback, 1);
    if(idxH >= 0) hh = iHigh(symbol, tf, idxH);
    int idxL = iLowest(symbol, tf, MODE_LOW, lookback, 1);
    if(idxL >= 0) ll = iLow(symbol, tf, idxL);
}

//---------------------------
// Indicators via handles
//---------------------------
double RSI_M1(int shift){ double v; if(!Copy1(hRSI_M1,0,shift,v)) return EMPTY_VALUE; return v; }
double RSI_M5(int shift){ double v; if(!Copy1(hRSI_M5,0,shift,v)) return EMPTY_VALUE; return v; }
double MA20_M1(int shift){ double v; if(!Copy1(hMA20_M1,0,shift,v)) return EMPTY_VALUE; return v; }
double MA50_M1(int shift){ double v; if(!Copy1(hMA50_M1,0,shift,v)) return EMPTY_VALUE; return v; }
double MA20_M5(int shift){ double v; if(!Copy1(hMA20_M5,0,shift,v)) return EMPTY_VALUE; return v; }
double MA50_M5(int shift){ double v; if(!Copy1(hMA50_M5,0,shift,v)) return EMPTY_VALUE; return v; }

bool MACD_H1(int shift,double &macd,double &sig)
{
   if(hMACD_H1==INVALID_HANDLE) return false;
   if(!Copy1(hMACD_H1,0,shift,macd)) return false;
   if(!Copy1(hMACD_H1,1,shift,sig))  return false;
   return true;
}

bool STO_M15(int shift,double &k,double &d)
{
   if(hSTO_M15==INVALID_HANDLE) return false;
   if(!Copy1(hSTO_M15,0,shift,k)) return false; // %K
   if(!Copy1(hSTO_M15,1,shift,d)) return false; // %D
   return true;
}

bool BB_H1(int shift,double &upper,double &middle,double &lower)
{
   if(hBB_H1==INVALID_HANDLE) return false;
   if(!Copy1(hBB_H1,0,shift,upper))  return false;
   if(!Copy1(hBB_H1,1,shift,middle)) return false;
   if(!Copy1(hBB_H1,2,shift,lower))  return false;
   return true;
}

// Directional bars
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
// GenerateSignal (weighted)
//---------------------------
int GenerateSignal(string &reason, double &confidence)
{
    reason = ""; confidence = 0.0;
    double totalWeight=0.0, bull=0.0, bear=0.0;

    // RSI + MA (M1) — 0.20
    double rsiM1  = RSI_M1(1);
    double maFast = MA20_M1(1);
    double maSlow = MA50_M1(1);
    if(rsiM1!=EMPTY_VALUE && maFast!=EMPTY_VALUE && maSlow!=EMPTY_VALUE){
        const double w=0.20; totalWeight+=w;
        if(rsiM1>55 && maFast>maSlow){ bull+=w; reason+="[RSI/MA M1 bull] "; }
        else if(rsiM1<45 && maFast<maSlow){ bear+=w; reason+="[RSI/MA M1 bear] "; }
    }

    // MACD (H1) — 0.25
    double macd, macdSig;
    if(MACD_H1(1,macd,macdSig)){
        const double w=0.25; totalWeight+=w;
        if(macd>macdSig){ bull+=w; reason+="[MACD H1 bull] "; }
        else if(macd<macdSig){ bear+=w; reason+="[MACD H1 bear] "; }
    }

    // Stochastic (M15) — 0.15
    double k,d;
    if(STO_M15(1,k,d)){
        const double w=0.15; totalWeight+=w;
        if(k<20 && d<20){ bull+=w; reason+="[Stoch M15 OS bull] "; }
        else if(k>80 && d>80){ bear+=w; reason+="[Stoch M15 OB bear] "; }
    }

    // Bollinger Bands (H1) — 0.20
    double upper, mid, lower;
    if(BB_H1(1,upper,mid,lower)){
        double closePrice = iClose(_Symbol, PERIOD_H1, 1);
        const double w=0.20; totalWeight+=w;
        if(closePrice<=lower){ bull+=w; reason+="[BB H1 lower touch] "; }
        else if(closePrice>=upper){ bear+=w; reason+="[BB H1 upper touch] "; }
    }

    // Momentum confirm (M5) — 0.20
    int dir = (bull>bear? 1 : (bear>bull? -1 : 0));
    if(dir!=0){
        int m5DirCount = CountDirectionalBars(_Symbol, PERIOD_M5, ConfirmBars, dir);
        const double w=0.20; totalWeight+=w;
        if(m5DirCount >= MathMax(1, ConfirmBars-1)){
            if(dir>0) bull+=w; else bear+=w; reason+="[M5 mom strong] ";
        }else{
            reason+="[M5 mom weak] ";
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
        FileWrite(handle, "timestamp,tag,symbol,side,lot,entry,sl,tp,reason,atr_pips,adx_h1,rsi_m5,ma20_m5,ma50_m5,hh,ll");
    }
    else { FileSeek(handle, 0, SEEK_END); }

    double plusDI, minusDI, adx;
    double atrPips = GetATRInPips_H1();
    if(!GetADX_H1(adx,plusDI,minusDI,1)) adx=EMPTY_VALUE;
    double rsiM5 = RSI_M5(1);
    double ma20  = MA20_M5(1);
    double ma50  = MA50_M5(1);
    double hh=EMPTY_VALUE, ll=EMPTY_VALUE;
    GetRecentSwingHighLow(_Symbol, PERIOD_M15, SR_LookbackBars, hh, ll);

    string line = StringFormat("%s,%s,%s,%s,%.2f,%.5f,%.5f,%.5f,%s,%.2f,%.2f,%.2f,%.5f,%.5f,%.5f,%.5f",
                              TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                              tag,_Symbol,side,lot,entry,sl,tp,reason,
                              (atrPips==EMPTY_VALUE?0.0:atrPips),
                              (adx==EMPTY_VALUE?0.0:adx),
                              (rsiM5==EMPTY_VALUE?0.0:rsiM5),
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
    double riskAmount = AccountInfoDouble(ACCOUNT_EQUITY) * (RiskPercent / 100.0);
    if(riskAmount <= 0) return 0;

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tickValue <= 0 || tickSize <= 0) return 0;

    double valuePerPriceUnitPerLot = tickValue / tickSize;
    double rawLot = riskAmount / (stopDistPriceUnits * valuePerPriceUnitPerLot);
    return GetSafeLotSize(rawLot);
}

//---------------------------
// Filters
//---------------------------
bool CanPassFilters(const int origSignal, string &outReason)
{
    outReason = "";
    if(origSignal == 0) { outReason = "No signal"; return false; }

    if(!InTradingSession()){ outReason="Outside trading sessions"; if(VerboseLogging) Print(outReason); return false; }

    if(IsNewsTime(NewsLookaheadMin, NewsLookbackMin)){ outReason="Blocked by high-impact news"; if(VerboseLogging) Print(outReason); return false; }

    if(UseSpikeFilter && IsSpike()){ outReason="Blocked by spike"; if(VerboseLogging) Print(outReason); return false; }

    double atrPips = GetATRInPips_H1();
    if(atrPips == EMPTY_VALUE){ outReason="ATR not ready"; return false; }
    if(atrPips < MinATR_Pips){ outReason=StringFormat("ATR too low (%.1f < %.1f pips)", atrPips, MinATR_Pips); if(VerboseLogging) Print(outReason); return false; }

    double hh,ll; GetRecentSwingHighLow(_Symbol, PERIOD_M15, SR_LookbackBars, hh, ll);
    double price = (origSignal > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double tolPrice = SR_ATR_Factor * atrPips * _Point;
    if(origSignal > 0 && hh!=EMPTY_VALUE && MathAbs(price - hh) <= tolPrice){ outReason="Near resistance"; if(VerboseLogging) Print(outReason); return false; }
    if(origSignal < 0 && ll!=EMPTY_VALUE && MathAbs(price - ll) <= tolPrice){ outReason="Near support";    if(VerboseLogging) Print(outReason); return false; }

    if(UseADXFilter){
        double adx,plusDI,minusDI;
        if(!GetADX_H1(adx,plusDI,minusDI,1)){ outReason="ADX not ready"; if(VerboseLogging) Print(outReason); return false; }
        if(ADX_RequireTrending && adx < ADX_Threshold){ outReason=StringFormat("ADX too low (%.2f < %.2f)", adx, ADX_Threshold); if(VerboseLogging) Print(outReason); return false; }
        // soft alignment (no mutation of signal)
        if(origSignal>0 && minusDI>plusDI){ outReason="DI misaligned for BUY"; if(VerboseLogging) Print(outReason); return false; }
        if(origSignal<0 && plusDI>minusDI){ outReason="DI misaligned for SELL"; if(VerboseLogging) Print(outReason); return false; }
    }

    double rsiPrev = RSI_M5(2), rsiNow = RSI_M5(1);
    if(rsiPrev!=EMPTY_VALUE && rsiNow!=EMPTY_VALUE){
        if(origSignal > 0 && rsiNow < rsiPrev){ outReason="RSI weakening (BUY)"; if(VerboseLogging) Print(outReason); return false; }
        if(origSignal < 0 && rsiNow > rsiPrev){ outReason="RSI weakening (SELL)"; if(VerboseLogging) Print(outReason); return false; }
    }

    int cnt = CountDirectionalBars(_Symbol, PERIOD_M5, ConfirmBars, origSignal>0?1:-1);
    if(cnt < MathMax(1, ConfirmBars-1)){ outReason="Not enough confirming bars"; if(VerboseLogging) Print(outReason); return false; }

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

void TryOpenTrade(const int signal, const string sigReason, const double confidence)
{
    string reason = "";
    if(!CanPassFilters(signal, reason))
    { if(VerboseLogging) PrintFormat("Signal blocked: %s (from: %s)", reason, sigReason); return; }

    if(signal != lastSignal){ lastSignal = signal; tradesCount = 0; }
    if(tradesCount >= MaxTradesPerSignal){ if(VerboseLogging) Print("Max trades reached for current signal."); return; }

    double atrPips = GetATRInPips_H1();
    if(atrPips == EMPTY_VALUE) { Print("ATR not ready for trade."); return; }

    double stopDistPrice = ATR_SL_Multiplier * atrPips * _Point;
    double priceAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double priceBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double entry = (signal>0 ? priceAsk : priceBid);

    double sl = (signal>0 ? entry - stopDistPrice : entry + stopDistPrice);
    double tp = (signal>0 ? entry + 2.0*stopDistPrice : entry - 2.0*stopDistPrice);

    EnforceStopsToBrokerRules(signal, entry, sl, tp);

    double safeLot = UseRiskPercent ? GetRiskLotSize(stopDistPrice) : GetSafeLotSize(LotSize);
    if(safeLot <= 0) { if(VerboseLogging) Print("Lot sizing failed."); return; }

    trade.SetExpertMagicNumber(ExpertMagic);

    bool sent=false;
    if(signal>0) sent = trade.Buy(safeLot, _Symbol, 0.0, sl, tp, "Buy");
    else         sent = trade.Sell(safeLot, _Symbol, 0.0, sl, tp, "Sell");

    int rc = trade.ResultRetcode();
    if(!sent || (rc!=10009 && rc!=10008)) // DEAL_PLACED / ORDER_PLACED
    {
        if(VerboseLogging) PrintFormat("Order send failed (retcode=%d, lastErr=%d)", rc, GetLastError());
        return;
    }

    tradesCount++;
    PrintFormat("Placed %s at %.5f | SL=%.5f | TP=%.5f | lot=%.2f | Strength=%.1f%%",
                (signal>0?"BUY":"SELL"), entry, sl, tp, safeLot, confidence);

    LogTradeCSV("OPEN", (signal>0?"BUY":"SELL"), safeLot, entry, sl, tp, sigReason);
}

//---------------------------
// Position Management
//---------------------------
int CountActiveSymbolMagicPositions()
{
    int total = PositionsTotal(), n=0;
    for(int i=0;i<total;i++){
        ulong tk = PositionGetTicket(i);
        if(tk==0 || !PositionSelectByTicket(tk)) continue;
        if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
        if((ulong)PositionGetInteger(POSITION_MAGIC)!=ExpertMagic) continue;
        n++;
    }
    return n;
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

        // Partial close at 50% of TP distance
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

        // Trailing stop based on recent M5 lows/highs
        double newSL = (dir > 0) ? iLow(_Symbol, PERIOD_M5, 1) : iHigh(_Symbol, PERIOD_M5, 1);
        for(int b=2; b<=3; b++){
            double ext = (dir > 0) ? iLow(_Symbol, PERIOD_M5, b) : iHigh(_Symbol, PERIOD_M5, b);
            newSL = (dir > 0) ? MathMin(newSL, ext) : MathMax(newSL, ext);
        }
        double stopPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

        if(dir > 0){
            if((sl==0 || newSL > sl + 1e-12) && (mkt - newSL >= stopPoints + _Point)){
                double effectiveSL = MathMax(newSL, mkt - (stopPoints + 1.0*_Point));
                trade.PositionModify(ticket, NormalizeDouble(effectiveSL,_Digits), tp);
            }
        } else {
            if((sl==0 || newSL < sl - 1e-12) && (newSL - mkt >= stopPoints + _Point)){
                double effectiveSL = MathMin(newSL, mkt + (stopPoints + 1.0*_Point));
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
    double rsi = RSI_M5(1);
    double ma20= MA20_M5(1);
    double ma50= MA50_M5(1);
    if(!GetADX_H1(adx,plusDI,minusDI,1)) adx=EMPTY_VALUE;
    double atrPips  = GetATRInPips_H1(); if(atrPips==EMPTY_VALUE) atrPips=0;

    int activeTrades = CountActiveSymbolMagicPositions();

    DrawLabel(prefix+"Status",100,40,(signal>0?clrGreen:(signal<0?clrRed:clrYellow)),
              StringFormat("Status: %s (%s)", status, reason));

    DrawLabel(prefix+"ATR",20,65,clrAqua, StringFormat("ATR (H1): %.1f pips", atrPips));
    string rsiTrend = (rsi>50 ? "↑ Bullish" : "↓ Bearish");
    string maAlign  = (ma20>ma50 ? "✅ Uptrend" : "❌ Downtrend");
    string adxStr   = (adx!=EMPTY_VALUE ? StringFormat("%.1f",adx) : "N/A");
    DrawLabel(prefix+"Trend",20,90,clrWhite,
              StringFormat("RSI: %.1f %s | MA: %s | ADX: %s", rsi, rsiTrend, maAlign, adxStr));

    DrawLabel(prefix+"Signal",20,115,(signal>0?clrGreen:(signal<0?clrRed:clrYellow)),
              StringFormat("Signal: %s", (signal>0?"BUY":(signal<0?"SELL":"None"))));

    DrawLabel(prefix+"ActiveTrades",20,140,clrYellow,
              StringFormat("Active Trades (%s/%I64u): %d", _Symbol, ExpertMagic, activeTrades));

    string sessionStr = InTradingSession() ? "Open" : "Closed";
    string newsStr    = IsNewsTime(NewsLookaheadMin, NewsLookbackMin) ? "High Impact News ⚠" : "No News";
    DrawLabel(prefix+"News",20,165,clrOrange, StringFormat("Session: %s | News: %s", sessionStr, newsStr));
}

//---------------------------
// OnTick / OnInit / OnDeinit
//---------------------------
void OnTick()
{
    // Throttle heavy logic to new M1 bar
    datetime curM1 = iTime(_Symbol, PERIOD_M1, 0);
    if(curM1 == lastM1Bar) { ManagePositions(); return; }
    lastM1Bar = curM1;

    string sigReason; double confidence=0.0;
    int signal = GenerateSignal(sigReason, confidence);

    double hh, ll; GetRecentSwingHighLow(_Symbol, PERIOD_H1, SR_LookbackBars, hh, ll);
    DrawSRLines(hh, ll);

    string dashReason = sigReason;
    if(confidence > 0.0 && confidence <= 100.0) dashReason += StringFormat(" | conf: %.1f%%", confidence);

    if(signal == 0){
        UpdateDashboard("Idle", dashReason, signal);
        ManagePositions();
        return;
    }

    TryOpenTrade(signal, sigReason, confidence);
    ManagePositions();
    UpdateDashboard("Running", dashReason, signal);
}

int OnInit()
{
    Print("AlexPro v2.13 initialized. ExpertMagic=", ExpertMagic);

    // Create indicator handles
    hRSI_M1  = iRSI(_Symbol, PERIOD_M1,  HTF_RSI_Period, PRICE_CLOSE);
    hRSI_M5  = iRSI(_Symbol, PERIOD_M5,  HTF_RSI_Period, PRICE_CLOSE);

    hMA20_M1 = iMA(_Symbol, PERIOD_M1, HTF_MA_Fast, 0, MODE_SMA, PRICE_CLOSE);
    hMA50_M1 = iMA(_Symbol, PERIOD_M1, HTF_MA_Slow, 0, MODE_SMA, PRICE_CLOSE);
    hMA20_M5 = iMA(_Symbol, PERIOD_M5, HTF_MA_Fast, 0, MODE_SMA, PRICE_CLOSE);
    hMA50_M5 = iMA(_Symbol, PERIOD_M5, HTF_MA_Slow, 0, MODE_SMA, PRICE_CLOSE);

    hMACD_H1 = iMACD(_Symbol, PERIOD_H1, 12, 26, 9, PRICE_CLOSE);
    hSTO_M15 = iStochastic(_Symbol, PERIOD_M15, 5, 3, 3, MODE_SMA, STO_LOWHIGH);

    // iBands(symbol, tf, period, deviation, bands_shift, applied_price)
    hBB_H1   = iBands(_Symbol, PERIOD_H1, 50, 2.0, 0, PRICE_CLOSE);

    // ADX & ATR
    hADX_H1  = iADX(_Symbol, PERIOD_H1, ADX_Period);
    hATR_H1  = iATR(_Symbol, PERIOD_H1, ATR_Period);

    // Basic handle sanity (non-fatal: just log)
    if(hRSI_M1==INVALID_HANDLE || hRSI_M5==INVALID_HANDLE ||
       hMA20_M1==INVALID_HANDLE || hMA50_M1==INVALID_HANDLE ||
       hMA20_M5==INVALID_HANDLE || hMA50_M5==INVALID_HANDLE ||
       hMACD_H1==INVALID_HANDLE || hSTO_M15==INVALID_HANDLE ||
       hBB_H1==INVALID_HANDLE  || hADX_H1==INVALID_HANDLE ||
       hATR_H1==INVALID_HANDLE)
    {
        Print("Warning: one or more indicator handles are invalid. Check symbols/timeframes.");
    }

    lastM1Bar = iTime(_Symbol, PERIOD_M1, 0);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    // Release all indicator handles
    int hs[] = {hRSI_M1,hRSI_M5,hMA20_M1,hMA50_M1,hMA20_M5,hMA50_M5,hMACD_H1,hSTO_M15,hBB_H1,hADX_H1,hATR_H1};
    for(int i=0;i<ArraySize(hs);i++) if(hs[i]!=INVALID_HANDLE) IndicatorRelease(hs[i]);

    // Clean UI objects (optional)
    string prefix = "AlexProUI_";
    string objs[] = { "Status","ATR","Trend","Signal","ActiveTrades","News","SR_Resistance","SR_Support" };
    for(int j=0;j<ArraySize(objs);j++) ObjectDelete(0, (j<6? prefix+objs[j] : objs[j]));
}
