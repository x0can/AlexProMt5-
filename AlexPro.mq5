//+------------------------------------------------------------------+
//| AlexPro Expert Advisor                                           |
//| Strategy: RSI(21) + MA(20/50) confirmation + ATR stops           |
//| Platform: MetaTrader 5                                           |
//+------------------------------------------------------------------+
#property copyright "AlexPro"
#property version   "1.00"
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

//---------------------------
// Global variables
//---------------------------
int lastSignal   = 0; // +1 = buy, -1 = sell
int tradesCount  = 0;
//--- new inputs for pre-trade filters
input int    SR_LookbackBars     = 20;    // bars to search SR on M15
input double SR_ATR_Factor       = 0.5;   // must be this * ATR away from SR to pass
input double MinATRFactor        = 0.6;   // require ATR >= MinATRFactor * avgATR (quiet market filter)
input int    HTF_RSI_Period      = 21;    // RSI used on HTF confirmation (M15)
input int    HTF_MA_Fast         = 20;    // MA periods on HTF
input int    HTF_MA_Slow         = 50;
input int    ATR_Avg_Lookback    = 20;    // average ATR length for volatility check

// new input for ATR min threshold (pips)
input double MinATR_Pips = 15.0;    // minimum ATR(15m) in pips before allowing trades



// --- INPUT PARAMETERS ---
input int BrokerGMTOffset = 2;    // Broker server time vs GMT (example: GMT+2)
input int LocalGMTOffset  = 3;    // Your local timezone (EAT = GMT+3)
input int LondonStartGMT  = 7;    // London session open (07:00 GMT)
input int LondonEndGMT    = 16;   // London session close (16:00 GMT)
input int NYStartGMT      = 12;   // New York open (12:00 GMT)
input int NYEndGMT        = 21;   // New York close (21:00 GMT)

// --- SESSION FILTER FUNCTION ---
bool InTradingSession(string &reason)
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);

   // Convert broker time -> GMT
   int hourGMT = t.hour - BrokerGMTOffset;

   // Wrap around if needed
   if(hourGMT < 0)  hourGMT += 24;
   if(hourGMT >= 24) hourGMT -= 24;

   // Check if within London or NY sessions
   bool inLondon = (hourGMT >= LondonStartGMT && hourGMT <= LondonEndGMT);
   bool inNY     = (hourGMT >= NYStartGMT && hourGMT <= NYEndGMT);

   if(!(inLondon || inNY))
   {
      reason = StringFormat("Outside sessions (GMT hour=%d, Broker hour=%d)", hourGMT, t.hour);
      return false;
   }
   return true;
}


//+------------------------------------------------------------------+
//| Indicator Functions                                              |
//+------------------------------------------------------------------+
double GetRSI(int period=21, int appliedPrice=PRICE_CLOSE)
{
   int handle = iRSI(_Symbol, PERIOD_M5, period, appliedPrice);
   if(handle == INVALID_HANDLE) return 0.0;
   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(handle, 0, 0, 1, buffer) > 0)
      return buffer[0];
   return 0.0;
}

double GetMA(int period)
{
   int handle = iMA(_Symbol, PERIOD_M5, period, 0, MODE_SMA, PRICE_CLOSE);
   if(handle == INVALID_HANDLE) return 0.0;
   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(handle, 0, 0, 1, buffer) > 0)
      return buffer[0];
   return 0.0;
}

bool ConfirmTrend(int direction, int bars=3)
{
   for(int i=1; i<=bars; i++)
   {
      double closePrice = iClose(_Symbol, PERIOD_M5, i);
      double openPrice  = iOpen(_Symbol, PERIOD_M5, i);
      if(direction==1 && closePrice <= openPrice) return false;
      if(direction==-1 && closePrice >= openPrice) return false;
   }
   return true;
}

int GenerateSignal(string &sigReason)
{
   sigReason = "";

   // --- RSI condition ---
   int hRSI = iRSI(_Symbol, PERIOD_M5, 21, PRICE_CLOSE);
   if(hRSI == INVALID_HANDLE) { sigReason = "RSI handle invalid"; return 0; }
   double rsiBuf[];
   ArraySetAsSeries(rsiBuf, true);
   if(CopyBuffer(hRSI, 0, 1, 1, rsiBuf) <= 0) { IndicatorRelease(hRSI); sigReason = "RSI not ready"; return 0; }
   double rsiVal = rsiBuf[0];
   IndicatorRelease(hRSI);

   // --- MAs ---
   int hMA20 = iMA(_Symbol, PERIOD_M5, 20, 0, MODE_SMA, PRICE_CLOSE);
   int hMA50 = iMA(_Symbol, PERIOD_M5, 50, 0, MODE_SMA, PRICE_CLOSE);
   if(hMA20 == INVALID_HANDLE || hMA50 == INVALID_HANDLE) { sigReason = "MA handle invalid"; return 0; }
   double ma20[], ma50[];
   ArraySetAsSeries(ma20, true); ArraySetAsSeries(ma50, true);
   if(CopyBuffer(hMA20, 0, 1, 1, ma20) <= 0 || CopyBuffer(hMA50, 0, 1, 1, ma50) <= 0)
   {
      IndicatorRelease(hMA20); IndicatorRelease(hMA50);
      sigReason = "MA values not ready"; return 0;
   }
   double ma20Val = ma20[0], ma50Val = ma50[0];
   IndicatorRelease(hMA20); IndicatorRelease(hMA50);

   // --- Conditions for BUY/SELL ---
   if(rsiVal > 50 && iClose(_Symbol, PERIOD_M5, 1) > ma20Val && iClose(_Symbol, PERIOD_M5, 1) > ma50Val)
   {
      sigReason = "BUY setup: RSI>50 and Price>MA20/50";
      return +1;
   }
   if(rsiVal < 50 && iClose(_Symbol, PERIOD_M5, 1) < ma20Val && iClose(_Symbol, PERIOD_M5, 1) < ma50Val)
   {
      sigReason = "SELL setup: RSI<50 and Price<MA20/50";
      return -1;
   }

   sigReason = StringFormat("No signal: RSI=%.2f, MA20=%.5f, MA50=%.5f", rsiVal, ma20Val, ma50Val);
   return 0;
}


//+------------------------------------------------------------------+
//| Order Execution                                                  |
//+------------------------------------------------------------------+
void TryOpenTrade(int signal)
{
   string reason;
   if(!CanPassFilters(signal, reason))
   {
      PrintFormat("AlexPro: Signal blocked by filter: %s", reason);
      return; // do not open trade
   }

   if(signal == 0) return;

   if(signal != lastSignal) // reset if new direction
   {
      lastSignal  = signal;
      tradesCount = 0;
   }
   if(tradesCount >= MaxTradesPerSignal) return;

   // ATR-based stop
   int atrHandle = iATR(_Symbol, PERIOD_M15, ATR_Period);
   double atrArr[];
   ArraySetAsSeries(atrArr, true);
   if(CopyBuffer(atrHandle, 0, 1, 1, atrArr) <= 0)
   {
      IndicatorRelease(atrHandle);
      return;
   }
   double atrVal = atrArr[0];
   IndicatorRelease(atrHandle);

   double stopDist = ATR_SL_Multiplier * atrVal;

   double price = (signal>0)? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (signal>0)? price - stopDist : price + stopDist;
   double tp = (signal>0)? price + 2*stopDist : price - 2*stopDist;

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   trade.SetExpertMagicNumber(202509121996);
   bool result = false;
   if(signal > 0)
      result = trade.Buy(LotSize, _Symbol, 0, sl, tp, "AlexPro Buy");
   else
      result = trade.Sell(LotSize, _Symbol, 0, sl, tp, "AlexPro Sell");

   if(result)
   {
      tradesCount++;
      PrintFormat("AlexPro: Placed %s order #%d at %.5f SL=%.5f TP=%.5f",
                  (signal>0)?"BUY":"SELL", tradesCount, price, sl, tp);
   }
}





bool VolatilityOkay()
{
   int atrHandle = iATR(_Symbol, PERIOD_M15, ATR_Period);
   double atrVal[];
   ArraySetAsSeries(atrVal, true);
   if(CopyBuffer(atrHandle, 0, 1, 1, atrVal) <= 0) return false;

   double atrPips = atrVal[0] / _Point; // convert to pips

   if(atrPips >= 15.0) return true;  // require at least 15 pips volatility
   return false;
}


double GetAdaptiveLotSize()
{
   int atrHandle = iATR(_Symbol, PERIOD_M15, ATR_Period);
   double atrVal[];
   ArraySetAsSeries(atrVal, true);
   if(CopyBuffer(atrHandle, 0, 1, 1, atrVal) <= 0) return LotSize;

   double atrPips = atrVal[0] / _Point;

   if(atrPips >= 40) return LotSize * 0.5; // scale down on extreme volatility
   if(atrPips <= 20) return LotSize * 1.5; // scale up on low-moderate vol
   return LotSize; // normal
}



//+------------------------------------------------------------------+
//| Position Management                                              |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Position Management                                              |

//---------------------------
// Helper: get RSI for a given TF (closed bars)
//---------------------------
double GetRSI_TF(const string symbol, ENUM_TIMEFRAMES tf, int period, int start_shift)
{
   int handle = iRSI(symbol, tf, period, PRICE_CLOSE);
   if(handle == INVALID_HANDLE) return(EMPTY_VALUE);
   double buf[];
   ArraySetAsSeries(buf, true);
   // copy one closed-bar value at shift 'start_shift' (start_shift=1 => last closed bar)
   if(CopyBuffer(handle, 0, start_shift, 1, buf) <= 0)
   {
      IndicatorRelease(handle);
      return(EMPTY_VALUE);
   }
   IndicatorRelease(handle);
   return(buf[0]);
}

//---------------------------
// Helper: get MA for a given TF (closed bar shift)
//---------------------------
double GetMA_TF(const string symbol, ENUM_TIMEFRAMES tf, int ma_period, int start_shift)
{
   int handle = iMA(symbol, tf, ma_period, 0, MODE_SMA, PRICE_CLOSE);
   if(handle == INVALID_HANDLE) return(EMPTY_VALUE);
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, start_shift, 1, buf) <= 0)
   {
      IndicatorRelease(handle);
      return(EMPTY_VALUE);
   }
   IndicatorRelease(handle);
   return(buf[0]);
}

//---------------------------
// Helper: avg ATR on a timeframe (closed bars)
//---------------------------
double GetAvgATR_TF(const string symbol, ENUM_TIMEFRAMES tf, int atrPeriod, int lookback)
{
   int handle = iATR(symbol, tf, atrPeriod);
   if(handle == INVALID_HANDLE) return(EMPTY_VALUE);
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, 1, lookback, buf) <= 0) // start=1 for closed bars
   {
      IndicatorRelease(handle);
      return(EMPTY_VALUE);
   }
   IndicatorRelease(handle);
   double s = 0.0;
   for(int i=0;i<ArraySize(buf); i++) s += buf[i];
   return s / MathMax(1, ArraySize(buf));
}

//---------------------------
// Helper: get recent swing high/low on a TF using iHighest/iLowest
// returns highestHighPrice and lowestLowPrice (last 'lookback' closed bars)
//---------------------------
void GetRecentSwingHighLow(const string symbol, ENUM_TIMEFRAMES tf, int lookback, double &highestHigh, double &lowestLow)
{
   // iHighest/Lowest return bar index (shift). Use start=1 to skip current forming bar
   int idxHighShift = iHighest(symbol, tf, MODE_HIGH, lookback, 1); // shift relative to current
   int idxLowShift  = iLowest(symbol, tf, MODE_LOW , lookback, 1);
   if(idxHighShift < 0) highestHigh = EMPTY_VALUE; else highestHigh = iHigh(symbol, tf, idxHighShift);
   if(idxLowShift  < 0) lowestLow  = EMPTY_VALUE; else lowestLow  = iLow(symbol, tf, idxLowShift);
}

//---------------------------
// Helper: count bullish/bearish closed candles on TF
//---------------------------
int CountDirectionalClosedBars(const string symbol, ENUM_TIMEFRAMES tf, int bars, int direction) // +1 bullish, -1 bearish
{
   int count = 0;
   for(int i=1; i<=bars; i++) // closed bars 1..bars
   {
      double op = iOpen(symbol, tf, i);
      double cl = iClose(symbol, tf, i);
      if(direction>0 && cl > op) count++;
      if(direction<0 && cl < op) count++;
   }
   return(count);
}

//---------------------------
// SR filter: returns true if price is not 'too close' to SR level
// Uses ATR to define proximity threshold
//---------------------------
bool SRFilter(int signal)
{
   double h, l;
   GetRecentSwingHighLow(_Symbol, PERIOD_M15, SR_LookbackBars, h, l); // M15 search
   if(h == EMPTY_VALUE || l == EMPTY_VALUE) return(true); // no SR found -> pass

   // current market price (use mid of bid/ask)
   double price = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;

   // ATR baseline on M15
   double atr = GetRSI_TF(_Symbol, PERIOD_M15, 1, 1); // dummy fallback
   // better get ATR value:
   int atrHandle = iATR(_Symbol, PERIOD_M15, ATR_Period);
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(atrHandle, 0, 1, 1, atrBuf) > 0) atr = atrBuf[0];
   IndicatorRelease(atrHandle);
   if(atr <= 0) return(true); // can't calculate ATR -> pass

   double tol = SR_ATR_Factor * atr; // threshold distance to SR

   if(signal > 0) // buy: check distance to nearest resistance (recent high)
   {
      if(MathAbs(price - h) <= tol) return(false); // too close to resistance -> block
   }
   else if(signal < 0) // sell: check distance to nearest support (recent low)
   {
      if(MathAbs(price - l) <= tol) return(false); // too close to support -> block
   }
   return(true);
}

//---------------------------
// HTF confirmation: require M15 signal alignment
//---------------------------
bool HTFConfirm(int signal)
{
   if(signal == 0) return(false);

   double rsi_htf = GetRSI_TF(_Symbol, PERIOD_M15, HTF_RSI_Period, 1); // last closed M15
   double ma_fast  = GetMA_TF(_Symbol, PERIOD_M15, HTF_MA_Fast, 1);
   double ma_slow  = GetMA_TF(_Symbol, PERIOD_M15, HTF_MA_Slow, 1);

   if(rsi_htf == EMPTY_VALUE || ma_fast == EMPTY_VALUE || ma_slow == EMPTY_VALUE) return(true); // be permissive if HTF unavailable

   if(signal > 0)
      return (rsi_htf > 50 && ma_fast > ma_slow);
   else
      return (rsi_htf < 50 && ma_fast < ma_slow);
}

//---------------------------
// Momentum continuation check
//---------------------------
bool MomentumOk(int signal)
{
   if(signal == 0) return(false);

   // RSI slope on M5: rsi(prev closed) - rsi(prev-1 closed) > 0 for bullish continuation
   int rsiPeriod = 21;
   int handle = iRSI(_Symbol, PERIOD_M5, rsiPeriod, PRICE_CLOSE);
   if(handle == INVALID_HANDLE) return(true); // permissive
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, 1, 2, buf) <= 1) { IndicatorRelease(handle); return(true); }
   IndicatorRelease(handle);

   double rsi_prev = buf[0]; // last closed bar
   double rsi_prev2 = buf[1]; // two bars ago

   bool slopeUp = (rsi_prev > rsi_prev2);
   bool slopeDown = (rsi_prev < rsi_prev2);

   // count closed directional bars in last ConfirmBars on M5
   int cntBull = CountDirectionalClosedBars(_Symbol, PERIOD_M5, ConfirmBars, +1);
   int cntBear = CountDirectionalClosedBars(_Symbol, PERIOD_M5, ConfirmBars, -1);

   if(signal > 0)
      return (slopeUp && cntBull >= MathMax(1, ConfirmBars-1)); // e.g., if ConfirmBars=3 require >=2 bullish
   else
      return (slopeDown && cntBear >= MathMax(1, ConfirmBars-1));
}

//---------------------------
// Volatility filter: ensure ATR(15) not too low vs historical average
//---------------------------
bool VolatilityOk()
{
   double avgATR = GetAvgATR_TF(_Symbol, PERIOD_M15, ATR_Period, ATR_Avg_Lookback);
   if(avgATR == EMPTY_VALUE || avgATR <= 0.0) return(true); // permissive if can't compute
   // current ATR
   int h = iATR(_Symbol, PERIOD_M15, ATR_Period);
   double arr[];
   ArraySetAsSeries(arr, true);
   double curATR = 0.0;
   if(CopyBuffer(h, 0, 1, 1, arr) > 0) curATR = arr[0];
   IndicatorRelease(h);
   if(curATR <= 0.0) return(true);

   return (curATR >= MinATRFactor * avgATR);
}

//---------------------------
// Final pre-trade filter combining everything
//---------------------------
//---------------------------
// CanPassFilters - corrected MQL5 version (uses handles + CopyBuffer)
//---------------------------
bool CanPassFilters(int signal, string &reason)
{
   reason = "";
   
   // --- 6) Session filter ---
   if(!InTradingSession(reason))
      return false;


   if(signal == 0) { reason = "no signal"; return(false); }

   // --- 1) ATR filter on M15 (last closed bar) ---
   int hATR = iATR(_Symbol, PERIOD_M15, ATR_Period);
   if(hATR == INVALID_HANDLE) { reason = "ATR handle invalid"; return(false); }
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hATR, 0, 1, 1, atrBuf) <= 0) // start=1 -> last closed bar
   {
      IndicatorRelease(hATR);
      reason = "ATR not ready";
      return(false);
   }
   double atrVal = atrBuf[0];
   IndicatorRelease(hATR);

   // convert ATR (price units) to pips
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipFactor = (digits == 3 || digits == 5) ? 10.0 : 1.0;
   double atrPips = (atrVal / _Point) / pipFactor;

   if(atrPips < MinATR_Pips)
   {
      reason = StringFormat("ATR too low: %.2f pips < %.2f", atrPips, MinATR_Pips);
      return(false);
   }

   // --- 2) Support / Resistance proximity on M15 (recent swing high/low) ---
   int idxHighShift = iHighest(_Symbol, PERIOD_M15, MODE_HIGH, SR_LookbackBars, 1);
   int idxLowShift  = iLowest(_Symbol, PERIOD_M15, MODE_LOW, SR_LookbackBars, 1);

   double recentHigh = (idxHighShift >= 0) ? iHigh(_Symbol, PERIOD_M15, idxHighShift) : EMPTY_VALUE;
   double recentLow  = (idxLowShift  >= 0) ? iLow(_Symbol, PERIOD_M15, idxLowShift)  : EMPTY_VALUE;

   double price = (signal > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double srTolerance = SR_ATR_Factor * atrVal;

   if(signal > 0) // BUY: don’t buy if too close to resistance
   {
      if(recentHigh != EMPTY_VALUE && MathAbs(recentHigh - price) <= srTolerance)
      {
         reason = "Price too close to resistance (risk of reversal)";
         return(false);
      }
   }
   else // SELL: don’t sell if too close to support
   {
      if(recentLow != EMPTY_VALUE && MathAbs(price - recentLow) <= srTolerance)
      {
         reason = "Price too close to support (risk of reversal)";
         return(false);
      }
   }

   // --- 3) Higher Time Frame confirmation (H1) ---
   int hRSI_H1 = iRSI(_Symbol, PERIOD_H1, HTF_RSI_Period, PRICE_CLOSE);
   if(hRSI_H1 == INVALID_HANDLE) { reason = "HTF RSI handle invalid"; return(false); }
   double rsiBuf[];
   ArraySetAsSeries(rsiBuf, true);
   if(CopyBuffer(hRSI_H1, 0, 1, 1, rsiBuf) <= 0) { IndicatorRelease(hRSI_H1); reason = "HTF RSI not ready"; return(false); }
   double rsiHTF = rsiBuf[0];
   IndicatorRelease(hRSI_H1);

   int hMAfast = iMA(_Symbol, PERIOD_H1, HTF_MA_Fast, 0, MODE_SMA, PRICE_CLOSE);
   int hMAslow = iMA(_Symbol, PERIOD_H1, HTF_MA_Slow, 0, MODE_SMA, PRICE_CLOSE);
   if(hMAfast == INVALID_HANDLE || hMAslow == INVALID_HANDLE) { reason = "HTF MA handle invalid"; return(false); }

   double maFastBuf[], maSlowBuf[];
   ArraySetAsSeries(maFastBuf, true);
   ArraySetAsSeries(maSlowBuf, true);
   if(CopyBuffer(hMAfast, 0, 1, 1, maFastBuf) <= 0) { IndicatorRelease(hMAfast); IndicatorRelease(hMAslow); reason = "HTF MA fast not ready"; return(false); }
   if(CopyBuffer(hMAslow, 0, 1, 1, maSlowBuf) <= 0) { IndicatorRelease(hMAfast); IndicatorRelease(hMAslow); reason = "HTF MA slow not ready"; return(false); }
   double maFast = maFastBuf[0], maSlow = maSlowBuf[0];
   IndicatorRelease(hMAfast); IndicatorRelease(hMAslow);

   if(signal > 0) // BUY
   {
      if(!(rsiHTF > 50 && maFast > maSlow))
      {
         reason = StringFormat("HTF mismatch (rsi=%.2f, maFast=%.5f, maSlow=%.5f)", rsiHTF, maFast, maSlow);
         return(false);
      }
   }
   else // SELL
   {
      if(!(rsiHTF < 50 && maFast < maSlow))
      {
         reason = StringFormat("HTF mismatch (rsi=%.2f, maFast=%.5f, maSlow=%.5f)", rsiHTF, maFast, maSlow);
         return(false);
      }
   }

   // --- 4) Momentum slope on M5 (RSI direction) ---
   int hRSI_M5 = iRSI(_Symbol, PERIOD_M5, HTF_RSI_Period, PRICE_CLOSE);
   if(hRSI_M5 == INVALID_HANDLE) { reason = "M5 RSI handle invalid"; return(false); }
   double rsi5Buf[];
   ArraySetAsSeries(rsi5Buf, true);
   if(CopyBuffer(hRSI_M5, 0, 1, 2, rsi5Buf) <= 1) { IndicatorRelease(hRSI_M5); reason = "M5 RSI not ready"; return(false); }
   double rsi_last = rsi5Buf[0], rsi_prev = rsi5Buf[1];
   IndicatorRelease(hRSI_M5);

   if(signal > 0 && rsi_last < rsi_prev) { reason = "RSI momentum weakening for BUY"; return(false); }
   if(signal < 0 && rsi_last > rsi_prev) { reason = "RSI momentum weakening for SELL"; return(false); }

   // --- 5) Confirm directional closed candles on M5 ---
   int cntDir = 0;
   for(int i = 1; i <= ConfirmBars; i++)
   {
      double op = iOpen(_Symbol, PERIOD_M5, i);
      double cl = iClose(_Symbol, PERIOD_M5, i);
      if(signal > 0 && cl > op) cntDir++;
      if(signal < 0 && cl < op) cntDir++;
   }
   int minRequired = MathMax(1, ConfirmBars - 1);
   if(cntDir < minRequired)
   {
      reason = StringFormat("Not enough confirming bars (%d of %d)", cntDir, ConfirmBars);
      return(false);
   }
   // --- 6) Session filter (London/NY only) ---
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   int hour = t.hour;
   
   if(!((hour >= 7 && hour <= 17) || (hour >= 13 && hour <= 22)))
   {
      reason = StringFormat("Outside London/NY sessions (hour=%d)", hour);
      return(false);
   }

   // --- All filters passed ---
   reason = "OK";
   return(true);
}

//+------------------------------------------------------------------+
// Corrected ManagePositions() - safe MQL5 usage (no implicit conversion)
void ManagePositions()
{
   int total = (int)PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      // Get ticket and auto-select that position (PositionGetTicket selects it)
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) 
         continue;          

      // Now that PositionGetTicket was called, position properties are available
      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym != _Symbol) 
         continue;          // only manage positions for current chart symbol

      // optional: restrict to trades opened by this EA (recommended)
      long magic = (long)PositionGetInteger(POSITION_MAGIC);
      if(magic != 202509121996)   // use your EA magic here
         continue;

      // read position properties (safe after PositionGetTicket)
      double volume = PositionGetDouble(POSITION_VOLUME);
      double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL  = PositionGetDouble(POSITION_SL);
      double curTP  = PositionGetDouble(POSITION_TP);
      long   type   = PositionGetInteger(POSITION_TYPE); // POSITION_TYPE_BUY or SELL
      int    direction = (type == POSITION_TYPE_BUY) ? 1 : -1;

      double marketPrice = (direction>0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      // --- Partial close logic ---
      // close half the position if profit >= 50% of (TP - entry) and momentum weakens
      if(curTP != 0) // ensure TP exists
      {
         double halfTPdistance = MathAbs(curTP - entry) * 0.5;
         double profitPoints = MathAbs(marketPrice - entry);

         double rsiNow = GetRSI(21, PRICE_CLOSE);         // reuse your RSI func
         bool weakening = (direction>0) ? (rsiNow < 50) : (rsiNow > 50);

         if(profitPoints >= halfTPdistance && weakening && volume > 0.0)
         {
            // compute partial-close volume respecting broker step/minimum
            double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            double minVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            double desired = volume / 2.0;

            // round down to allowed step
            int steps = (int)MathFloor(desired / volStep + 1e-9);
            double closeVol = steps * volStep;
            if(closeVol < minVol) closeVol = minVol;

            if(closeVol > 0 && closeVol < volume + 1e-12)
            {
               bool ok = trade.PositionClosePartial(ticket, closeVol); // CTrade partial close
               if(!ok)
                  PrintFormat("AlexPro: Partial close FAILED ticket=%I64u closeVol=%.2f err=%d", ticket, closeVol, GetLastError());
               else
                  PrintFormat("AlexPro: Partial close OK ticket=%I64u closed=%.2f", ticket, closeVol);
            }
         }
      }

      // --- Trailing SL based on last 2-3 closed 5-min bars ---
      double newSL = 0.0;
      for(int b = 1; b <= 3; b++) // b=1 is last closed bar
      {
         double ext = (direction>0) ? iLow(_Symbol, PERIOD_M5, b) : iHigh(_Symbol, PERIOD_M5, b);
         if(b == 1) newSL = ext;
         else
         {
            if(direction>0) newSL = MathMin(newSL, ext);
            else             newSL = MathMax(newSL, ext);
         }
      }

      // Make sure newSL obeys the broker's stops level
      double stops_level_points = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); // in points
      double stops_level_price  = stops_level_points * _Point;
      if(direction > 0)
      {
         // only move SL up (lock profits). require minimal distance from price
         if(newSL > curSL + 1e-12)
         {
            double minAllowedSL = marketPrice - stops_level_price;
            // ensure SL is at least the minimal allowed distance
            if(newSL < minAllowedSL) newSL = minAllowedSL;
            if(newSL > curSL + 1e-12)
            {
               if(!trade.PositionModify(ticket, newSL, curTP))
                  PrintFormat("AlexPro: PositionModify (raise SL) FAILED ticket=%I64u err=%d", ticket, GetLastError());
               else
                  PrintFormat("AlexPro: Trailing SL raised ticket=%I64u newSL=%.5f", ticket, newSL);
            }
         }
      }
      else
      {
         // short: only move SL down (lock profits)
         if(newSL < curSL - 1e-12 || curSL == 0.0)
         {
            double minAllowedSL = marketPrice + stops_level_price;
            if(newSL > minAllowedSL) newSL = minAllowedSL;
            if(newSL < curSL - 1e-12 || curSL == 0.0)
            {
               if(!trade.PositionModify(ticket, newSL, curTP))
                  PrintFormat("AlexPro: PositionModify (lower SL) FAILED ticket=%I64u err=%d", ticket, GetLastError());
               else
                  PrintFormat("AlexPro: Trailing SL lowered ticket=%I64u newSL=%.5f", ticket, newSL);
            }
         }
      }
   } // for positions
}


//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Dashboard (Modernized)                                           |
//+------------------------------------------------------------------+

void CreateDashboard()
{
   string prefix = "AlexProUI_";

   // --- Panel background ---
   string panel = prefix + "Panel";
   if(ObjectFind(0, panel) < 0)
   {
      ObjectCreate(0, panel, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, panel, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, panel, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, panel, OBJPROP_YDISTANCE, 10);
      ObjectSetInteger(0, panel, OBJPROP_XSIZE, 260);
      ObjectSetInteger(0, panel, OBJPROP_YSIZE, 140);
      ObjectSetInteger(0, panel, OBJPROP_BGCOLOR, clrBlack);
      ObjectSetInteger(0, panel, OBJPROP_COLOR, clrSilver);
      ObjectSetInteger(0, panel, OBJPROP_BACK, true);
   }

   // --- Title ---
   string title = prefix + "Title";
   if(ObjectFind(0, title) < 0)
   {
      ObjectCreate(0, title, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, title, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, title, OBJPROP_XDISTANCE, 20);
      ObjectSetInteger(0, title, OBJPROP_YDISTANCE, 15);
      ObjectSetInteger(0, title, OBJPROP_FONTSIZE, 12);
      ObjectSetInteger(0, title, OBJPROP_COLOR, clrLime);
      ObjectSetString(0, title, OBJPROP_TEXT, "📊 AlexPro Dashboard");
   }
}

// Update dynamic info
void UpdateDashboard(string status="Idle", string reason="", int signal=0)
{
   string prefix = "AlexProUI_";

   // --- Indicators ---
   double rsi   = GetRSI(21, PRICE_CLOSE);
   double ma20  = GetMA(20);
   double ma50  = GetMA(50);
   int activeTrades = PositionsTotal();

   // --- ATR (M5) calculation for dashboard ---
   double atrPips = 0;
   int hATR = iATR(_Symbol, PERIOD_M5, 14);
   if(hATR != INVALID_HANDLE)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(hATR, 0, 1, 1, atrBuf) > 0)
      {
         int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
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

void OnTick()
{
   //--- generate signal + explanation
   string sigReason;
   int signal = GenerateSignal(sigReason);

   if(signal == 0)
   {
      PrintFormat("AlexPro: Signal blocked — %s", sigReason);
      UpdateDashboard(); // still update panel to show status
      return;
   }

   //--- apply filters (ATR, SR, HTF RSI/MA, momentum, candles)
   string filterReason;
   if(!CanPassFilters(signal, filterReason))
   {
      PrintFormat("AlexPro: Signal blocked by filter: %s", filterReason);
      UpdateDashboard(); // show why no trade executed
      return;
   }

   //--- open trade if everything is valid
   TryOpenTrade(signal);

   //--- manage open positions
   ManagePositions();

   //--- update visual dashboard
   UpdateDashboard("Running", sigReason, signal);

}
