//+------------------------------------------------------------------+
//| AlexPro Full Expert Advisor (modified)                           |
//| Strategy: RSI(21) + MA(20/50) + ATR stops + SR + HTF + Momentum   |
//| Features: Partial Close + Smart Trailing SL + Adaptive Lots      |
//| Platform: MetaTrader 5                                           |
//+------------------------------------------------------------------+
#property copyright "AlexPro"
#property version   "2.10"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//---------------------------
// Inputs
//---------------------------
input double   LotSize            = 1.0;     // Fixed lot size
input int      ATR_Period         = 14;      // ATR period (15m)
input double   ATR_SL_Multiplier  = 0.5;     // SL = ATR * multiplier
input int      MaxTradesPerSignal = 2;       // Max trades per signal
input int      ConfirmBars        = 3;       // Trend confirmation bars
input int      SR_LookbackBars    = 20;      // bars to search SR on M15
input double   SR_ATR_Factor      = 0.5;     // proximity to SR
input double   MinATRFactor       = 0.6;     // min volatility relative to avg ATR
input double   MinATR_Pips        = 15.0;    // minimum ATR in pips
input int      HTF_RSI_Period     = 21;
input int      HTF_MA_Fast        = 20;
input int      HTF_MA_Slow        = 50;
input int      ATR_Avg_Lookback   = 20;
input double   PartialClosePct    = 50.0;    // % of position to close at half TP

// Session Times
input int BrokerGMTOffset = 2;
input int LondonStartGMT  = 7;
input int LondonEndGMT    = 16;
input int NYStartGMT      = 12;
input int NYEndGMT        = 21;

//---------------------------
// Global variables
//---------------------------
int lastSignal = 0;
int tradesCount = 0;

//---------------------------
// News Filters (MT5-safe, using time_utc)
//---------------------------

// Recent high-impact news
bool IsRecentHighImpactNews(int lookbackMinutes=30)
{
    datetime now = TimeTradeServer();
    MqlCalendarEvent events[];
    string currency = StringSubstr(_Symbol,0,3);
    int total = CalendarEventByCurrency(currency, events);
    if(total <= 0) return false;

    for(int i=0; i<total; i++)
    {
        if(events[i].importance == 2)  // high-impact
        {
            datetime eventTime = events[i].time_mode;  // use time_utc
            if(now >= eventTime && now - eventTime <= lookbackMinutes*60)
                return true;
        }
    }
    return false;
}

// Upcoming high-impact news
bool IsUpcomingHighImpactNews(int lookaheadMinutes=30)
{
    datetime now = TimeTradeServer();
    MqlCalendarEvent events[];
    string currency = StringSubstr(_Symbol,0,3);
    int total = CalendarEventByCurrency(currency, events);
    if(total <= 0) return false;

    for(int i=0; i<total; i++)
    {
        if(events[i].importance == 2)  // high-impact
        {
            datetime eventTime = events[i].time_mode;  // use time_utc
            if(eventTime >= now && eventTime - now <= lookaheadMinutes*60)
                return true;
        }
    }
    return false;
}

// Unified news check
bool IsNewsTime(int bufferMinutes=30)
{
    return IsRecentHighImpactNews(bufferMinutes) || IsUpcomingHighImpactNews(bufferMinutes);
}


bool IsSpike()
{
    double high = iHigh(_Symbol, PERIOD_M15, 1);
    double low  = iLow(_Symbol, PERIOD_M15, 1);
    double open = iOpen(_Symbol, PERIOD_M15, 1);

    double movePips = MathAbs(high - low) / _Point;
    if(SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 3 || SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 5)
        movePips /= 10.0;

    // Threshold: 50+ pips move on M15 considered spike (adjustable)
    if(movePips >= 50.0) return true;

    return false;
}

//---------------------------
// Indicator Helpers
//---------------------------
double GetRSI_TF(string symbol, ENUM_TIMEFRAMES tf, int period, int shift) {
    int handle = iRSI(symbol, tf, period, PRICE_CLOSE);
    if(handle == INVALID_HANDLE) return EMPTY_VALUE;
    double buf[];
    ArraySetAsSeries(buf,true);
    if(CopyBuffer(handle,0,shift,1,buf)<=0){ IndicatorRelease(handle); return EMPTY_VALUE; }
    IndicatorRelease(handle);
    return buf[0];
}

double GetMA_TF(string symbol, ENUM_TIMEFRAMES tf,int period,int shift){
    int handle=iMA(symbol,tf,period,0,MODE_SMA,PRICE_CLOSE);
    if(handle==INVALID_HANDLE) return EMPTY_VALUE;
    double buf[]; ArraySetAsSeries(buf,true);
    if(CopyBuffer(handle,0,shift,1,buf)<=0){IndicatorRelease(handle); return EMPTY_VALUE;}
    IndicatorRelease(handle);
    return buf[0];
}

double GetAvgATR_TF(string symbol, ENUM_TIMEFRAMES tf, int atrPeriod,int lookback){
    int handle=iATR(symbol,tf,atrPeriod);
    if(handle==INVALID_HANDLE) return EMPTY_VALUE;
    double buf[]; ArraySetAsSeries(buf,true);
    if(CopyBuffer(handle,0,1,lookback,buf)<=0){IndicatorRelease(handle); return EMPTY_VALUE;}
    IndicatorRelease(handle);
    double s=0; for(int i=0;i<ArraySize(buf);i++) s+=buf[i];
    return s/MathMax(1,ArraySize(buf));
}

// Returns ATR in pips for the given symbol and timeframe
double GetATRInPips(string symbol, ENUM_TIMEFRAMES tf, int atrPeriod)
{
    int handle = iATR(symbol, tf, atrPeriod);
    if(handle == INVALID_HANDLE) return EMPTY_VALUE;

    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(handle, 0, 1, 1, buf) <= 0)
    {
        IndicatorRelease(handle);
        return EMPTY_VALUE;
    }

    double atrVal = buf[0]; // ATR in price units
    IndicatorRelease(handle);

    int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    double pipFactor = (digits == 3 || digits == 5) ? 10.0 : 1.0;

    return (atrVal / _Point) / pipFactor;
}


void GetRecentSwingHighLow(string symbol, ENUM_TIMEFRAMES tf,int lookback,double &hh,double &ll){
    int idxH=iHighest(symbol,tf,MODE_HIGH,lookback,1);
    int idxL=iLowest(symbol,tf,MODE_LOW,lookback,1);
    hh=(idxH>=0)?iHigh(symbol,tf,idxH):EMPTY_VALUE;
    ll=(idxL>=0)?iLow(symbol,tf,idxL):EMPTY_VALUE;
}

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
// Signal Generation
//---------------------------
int GenerateSignal(string &reason){
    reason="";
    double rsi=GetRSI_TF(_Symbol,PERIOD_M5,21,1);
    double ma20=GetMA_TF(_Symbol,PERIOD_M5,20,1);
    double ma50=GetMA_TF(_Symbol,PERIOD_M5,50,1);
    if(rsi==EMPTY_VALUE || ma20==EMPTY_VALUE || ma50==EMPTY_VALUE){reason="Indicators not ready"; return 0;}
    double close=iClose(_Symbol,PERIOD_M5,1);
    if(rsi>50 && close>ma20 && close>ma50){reason="BUY setup"; return 1;}
    if(rsi<50 && close<ma20 && close<ma50){reason="SELL setup"; return -1;}
    reason="No setup"; return 0;
}

//---------------------------
// Filters
//---------------------------
bool InTradingSession(){
    MqlDateTime t; TimeToStruct(TimeTradeServer(),t);
    int hourGMT=t.hour - BrokerGMTOffset; if(hourGMT<0) hourGMT+=24; if(hourGMT>=24) hourGMT-=24;
    return ((hourGMT>=LondonStartGMT && hourGMT<=LondonEndGMT)||(hourGMT>=NYStartGMT && hourGMT<=NYEndGMT));
}
bool CanPassFilters(int signal, string &reason)
{
    reason = "";

    // --- No signal ---
    if(signal == 0)
    {
        reason = "No signal";
        return false;
    }

    // --- Trading session check ---
    if(!InTradingSession())
    {
        reason = "Outside trading sessions";
        return false;
    }

    // --- News filter ---
    if(IsNewsTime(30))
    {
        reason = "High-impact news upcoming or just occurred";
        return false;
    }

    // --- ATR check (in pips) ---
    double atrPips = GetATRInPips(_Symbol, PERIOD_M15, ATR_Period);
    if(atrPips == EMPTY_VALUE)
    {
        reason = "ATR not ready";
        return false;
    }
    if(atrPips < MinATR_Pips)
    {
        reason = StringFormat("ATR too low (%.1f < %.1f pips)", atrPips, MinATR_Pips);
        return false;
    }

    // --- Support/Resistance check ---
    double hh, ll;
    GetRecentSwingHighLow(_Symbol, PERIOD_M15, SR_LookbackBars, hh, ll);
    double price = (signal > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double tol = SR_ATR_Factor * atrPips * _Point; // use ATR in pips converted to price units
    if(signal > 0 && hh != EMPTY_VALUE && MathAbs(price - hh) <= tol)
    {
        reason = "Near resistance";
        return false;
    }
    if(signal < 0 && ll != EMPTY_VALUE && MathAbs(price - ll) <= tol)
    {
        reason = "Near support";
        return false;
    }

    // --- HTF confirmation ---
    double rsiHTF = GetRSI_TF(_Symbol, PERIOD_H1, HTF_RSI_Period, 1);
    double maFast = GetMA_TF(_Symbol, PERIOD_H1, HTF_MA_Fast, 1);
    double maSlow = GetMA_TF(_Symbol, PERIOD_H1, HTF_MA_Slow, 1);
    if(rsiHTF != EMPTY_VALUE && maFast != EMPTY_VALUE && maSlow != EMPTY_VALUE)
    {
        if(signal > 0 && !(rsiHTF > 50 && maFast > maSlow))
        {
            reason = "HTF mismatch";
            return false;
        }
        if(signal < 0 && !(rsiHTF < 50 && maFast < maSlow))
        {
            reason = "HTF mismatch";
            return false;
        }
    }

    // --- Momentum slope ---
    double rsiPrev = GetRSI_TF(_Symbol, PERIOD_M5, HTF_RSI_Period, 2);
    double rsiNow  = GetRSI_TF(_Symbol, PERIOD_M5, HTF_RSI_Period, 1);
    if(signal > 0 && rsiNow < rsiPrev)
    {
        reason = "RSI weakening";
        return false;
    }
    if(signal < 0 && rsiNow > rsiPrev)
    {
        reason = "RSI weakening";
        return false;
    }

    // --- Confirm directional bars ---
    int cnt = CountDirectionalBars(_Symbol, PERIOD_M5, ConfirmBars, signal > 0 ? 1 : -1);
    if(cnt < MathMax(1, ConfirmBars - 1))
    {
        reason = "Not enough confirming bars";
        return false;
    }

    reason = "OK ✅";
    return true;
}


//---------------------------
// Trade Execution
//---------------------------
void TryOpenTrade(int signal)
{
    string reason;
    if(!CanPassFilters(signal, reason))
    {
        PrintFormat("Signal blocked: %s", reason);
        return;
    }

    // Reset trades count if new signal
    if(signal != lastSignal)
    {
        lastSignal = signal;
        tradesCount = 0;
    }

    if(tradesCount >= MaxTradesPerSignal)
        return;

    // --- ATR-based SL/TP ---
    double atrPips = GetATRInPips(_Symbol, PERIOD_M15, ATR_Period);
    if(atrPips == EMPTY_VALUE)
    {
        Print("ATR not ready for trade");
        return;
    }

    double pipValue = (SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 3 || 
                       SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 5) ? 0.1 : 1.0;

    double stopDist = ATR_SL_Multiplier * atrPips * _Point;  // convert pips to price
    double price = (signal > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = (signal > 0) ? price - stopDist : price + stopDist;
    double tp = (signal > 0) ? price + 2 * stopDist : price - 2 * stopDist;
    sl = NormalizeDouble(sl, _Digits);
    tp = NormalizeDouble(tp, _Digits);

    // --- Execute trade ---
    trade.SetExpertMagicNumber(202509121996);
    bool res = (signal > 0) 
               ? trade.Buy(LotSize, _Symbol, 0, sl, tp, "AlexPro Buy") 
               : trade.Sell(LotSize, _Symbol, 0, sl, tp, "AlexPro Sell");

    if(res)
    {
        tradesCount++;
        PrintFormat("Placed %s order at %.5f | SL=%.5f | TP=%.5f", 
                    (signal > 0 ? "BUY" : "SELL"), price, sl, tp);
    }
}

//---------------------------
// Position Management: Partial close + Smart Trailing
//---------------------------
void ManagePositions(){
    int total=(int)PositionsTotal();
    for(int i=total-1;i>=0;i--){
        ulong ticket=PositionGetTicket(i);
        if(ticket==0) continue;
        string sym=PositionGetString(POSITION_SYMBOL);
        if(sym!=_Symbol) continue;
        long magic=(long)PositionGetInteger(POSITION_MAGIC); if(magic!=202509121996) continue;
        double vol=PositionGetDouble(POSITION_VOLUME);
        double entry=PositionGetDouble(POSITION_PRICE_OPEN);
        double sl=PositionGetDouble(POSITION_SL);
        double tp=PositionGetDouble(POSITION_TP);
        long type=PositionGetInteger(POSITION_TYPE);
        int dir=(type==POSITION_TYPE_BUY?1:-1);
        double mkt=(dir>0)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);

        // Partial Close dynamic
        double halfTP=entry+dir*0.5*(tp-entry);
        double profitPoints=MathAbs(mkt-entry);
        double targetPoints=MathAbs(tp-entry);
        if(profitPoints>=0.5*targetPoints && vol>0){
            double pctClose=PartialClosePct/100.0;
            double closeVol=MathMax(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),
                MathFloor(vol*pctClose/SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP))
                *SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP));
            if(closeVol>0 && closeVol<vol+1e-12){
                trade.PositionClosePartial(ticket,closeVol);
            }
        }

        // Smart Trailing SL
        double newSL=(dir>0)?iLow(_Symbol,PERIOD_M5,1):iHigh(_Symbol,PERIOD_M5,1);
        for(int b=2;b<=3;b++){
            double ext=(dir>0)?iLow(_Symbol,PERIOD_M5,b):iHigh(_Symbol,PERIOD_M5,b);
            newSL=(dir>0)?MathMin(newSL,ext):MathMax(newSL,ext);
        }
        double stopPoints=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
        if(dir>0 && (newSL>sl+1e-12)) {
            newSL=MathMax(newSL,mkt-stopPoints);
            trade.PositionModify(ticket,newSL,tp);
        }
        if(dir<0 && (newSL<sl-1e-12||sl==0)) {
            newSL=MathMin(newSL,mkt+stopPoints);
            trade.PositionModify(ticket,newSL,tp);
        }
    }
}


//---------------------------
// Draw/Update SR lines
//---------------------------
void DrawSRLines(double hh, double ll)
{
    static string resLine = "SR_Resistance";
    static string supLine = "SR_Support";

    // Only draw/update if the values are valid
    if(hh != EMPTY_VALUE)
    {
        if(ObjectFind(0, resLine) < 0)
            ObjectCreate(0, resLine, OBJ_HLINE, 0, 0, hh);
        else
            ObjectSetDouble(0, resLine, OBJPROP_PRICE, hh);

        ObjectSetInteger(0, resLine, OBJPROP_COLOR, clrRed);
        ObjectSetInteger(0, resLine, OBJPROP_WIDTH, 2);
        ObjectSetInteger(0, resLine, OBJPROP_STYLE, STYLE_SOLID);
    }
    if(ll != EMPTY_VALUE)
    {
        if(ObjectFind(0, supLine) < 0)
            ObjectCreate(0, supLine, OBJ_HLINE, 0, 0, ll);
        else
            ObjectSetDouble(0, supLine, OBJPROP_PRICE, ll);

        ObjectSetInteger(0, supLine, OBJPROP_COLOR, clrGreen);
        ObjectSetInteger(0, supLine, OBJPROP_WIDTH, 2);
        ObjectSetInteger(0, supLine, OBJPROP_STYLE, STYLE_SOLID);
    }
}


//---------------------------
// OnTick
//---------------------------
void OnTick(){
    string sigReason; int signal=GenerateSignal(sigReason);
    double hh, ll;
   GetRecentSwingHighLow(_Symbol, PERIOD_M15, SR_LookbackBars, hh, ll);
   DrawSRLines(hh, ll);

    
    if(signal==0){UpdateDashboard("Idle",sigReason,signal); return;}
    TryOpenTrade(signal);
    ManagePositions();
    UpdateDashboard("Running",sigReason,signal);
}

//---------------------------
// Dashboard (simplified)
//---------------------------
void UpdateDashboard(string status="Idle", string reason="", int signal=0)
{
   string prefix = "AlexProUI_";

   // --- Indicators ---
   double rsi   = GetRSI_TF(_Symbol, PERIOD_M5, 21, 1); // last closed bar
   double ma20  = GetMA_TF(_Symbol, PERIOD_M5, 20, 1);
   double ma50  = GetMA_TF(_Symbol, PERIOD_M5, 50, 1);

   int activeTrades = PositionsTotal();

   // --- ATR (M5) calculation for dashboard (modified) ---
   double atrPips = 0;
   int hATR = iATR(_Symbol, PERIOD_M5, ATR_Period); // use ATR_Period input
   if(hATR != INVALID_HANDLE)
   {
       double atrBuf[];
       ArraySetAsSeries(atrBuf, true);
       if(CopyBuffer(hATR, 0, 1, 1, atrBuf) > 0)
       {
           double digits = (double)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
           double pipFactor = (digits == 3 || digits == 5) ? 10.0 : 1.0;
           atrPips = (atrBuf[0] / _Point) / pipFactor;
       }
       IndicatorRelease(hATR);
   }

   // --- Text Info ---
   string rsiTrend = (rsi > 50) ? "↑ Bullish" : "↓ Bearish";
   string maAlign  = (ma20 > ma50) ? "✅ Uptrend" : "❌ Downtrend";
   string sigTxt   = (signal > 0) ? "BUY ✅" : (signal < 0 ? "SELL ❌" : "None ⚠");

   // --- Status Line ---
   string stat = prefix + "Status";
   if(ObjectFind(0, stat) < 0)
      ObjectCreate(0, stat, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, stat, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, stat, OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, stat, OBJPROP_YDISTANCE, 40);
   ObjectSetInteger(0, stat, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, stat, OBJPROP_COLOR, (signal > 0 ? clrGreen : (signal < 0 ? clrRed : clrYellow)));
   ObjectSetString(0, stat, OBJPROP_TEXT,
      StringFormat("Status: %s (%s)", status, reason));

   // --- ATR Info ---
   string atrTxt = prefix + "ATR";
   if(ObjectFind(0, atrTxt) < 0)
      ObjectCreate(0, atrTxt, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, atrTxt, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, atrTxt, OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, atrTxt, OBJPROP_YDISTANCE, 65);
   ObjectSetInteger(0, atrTxt, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, atrTxt, OBJPROP_COLOR, clrAqua);
   ObjectSetString(0, atrTxt, OBJPROP_TEXT,
      StringFormat("ATR (M5): %.1f pips", atrPips));

   // --- RSI + MA Alignment ---
   string trendTxt = prefix + "Trend";
   if(ObjectFind(0, trendTxt) < 0)
      ObjectCreate(0, trendTxt, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, trendTxt, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, trendTxt, OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, trendTxt, OBJPROP_YDISTANCE, 90);
   ObjectSetInteger(0, trendTxt, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, trendTxt, OBJPROP_COLOR, clrWhite);
   ObjectSetString(0, trendTxt, OBJPROP_TEXT,
      StringFormat("RSI: %.1f %s | MA: %s", rsi, rsiTrend, maAlign));

   // --- Signal Direction ---
   string sigObj = prefix + "Signal";
   if(ObjectFind(0, sigObj) < 0)
      ObjectCreate(0, sigObj, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, sigObj, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, sigObj, OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, sigObj, OBJPROP_YDISTANCE, 115);
   ObjectSetInteger(0, sigObj, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, sigObj, OBJPROP_COLOR, (signal > 0 ? clrGreen : (signal < 0 ? clrRed : clrYellow)));
   ObjectSetString(0, sigObj, OBJPROP_TEXT,
      StringFormat("Signal: %s | Active Trades: %d", sigTxt, activeTrades));
}
