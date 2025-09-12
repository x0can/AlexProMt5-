# AlexPro – Professional MT5 Trading Bot

**Version:** 1.0  
**Platform:** MetaTrader 5 (MT5)  
**Developer:** [Your Name]  
**Date:** 2025-09-12  

---

## Overview

**AlexPro** is a multi-timeframe, momentum- and trend-based Expert Advisor designed for professional traders seeking a balance between precision and flexibility. It incorporates advanced filtering, dynamic trade management, and a visual dashboard to provide real-time trade signals and actionable insights.  

AlexPro is built for **both intrabar (tick-based) and closed candle signals**, and it manages trades dynamically with risk controls, ATR-based stops, and partial exits.


## Core Features

### 1. Signal Detection
- RSI-based trend bias:
  - `RSI(21) > 50` → bullish trend, `RSI(21) < 50` → bearish trend.
- Moving averages alignment:
  - MA(20) and MA(50) cross-confirmation.
- Multi-timeframe confirmation:
  - M5 entry confirmed by M15 trend (RSI + MA alignment).
- Consecutive bullish/bearish candles confirmation.
- Signal alerts for momentum forming, weak signals, and confirmations.

### 2. Trade Execution
- Market orders only.
- Lot size: fixed at 1 lot.
- ATR-based risk management:
  - Stop-loss: 0.5 × ATR (15M).
  - Take-profit: 1 × ATR (15M).
- Single and multiple trades management:
  - Executes one trade per signal set.
  - Can scale to additional trades if new confirmation occurs.
- Dynamic trade management:
  - Partial close when floating profit ≥ 0.5 × TP and momentum fades.
  - Trailing stop behind recent highs/lows (last 2–3 M5 bars).
  - Adaptive stop-loss and take-profit recalculation based on recent price action.


### 3. Filters & Safety Checks
- ATR filter:
  - Minimum volatility required to execute trades (recommended 15–20 pips for M5).
- Support and resistance proximity:
  - Avoids entries too close to recent swing highs/lows to prevent reversals.
- Higher timeframe trend confirmation (M15):
  - RSI + MA alignment confirms direction.
- Momentum check:
  - RSI slope check (rising/falling) to avoid entering fading trends.
- Session filters (planned):
  - Option to trade only during London/New York sessions.
- Weak signal detection:
  - Alerts for momentum forming but not confirmed yet.

### 4. Dashboard / UI
- Visual panel on chart with colored labels and icons.
- Displays:
  - RSI value & trend direction.
  - MA alignment.
  - ATR (M5) in pips.
  - Signal direction (BUY / SELL / None) with icons.
  - Active trades count.
  - Status messages with filter reasons for blocked trades.
- Updated in real-time on every tick.

### 5. Logging & Alerts
- Prints detailed logs to Experts tab:
  - Trade execution.
  - Blocked signals with reasoning (e.g., ATR too low, close to resistance).
  - Momentum forming alerts.
- Optional notifications for pending signals.


## Pending Improvements / Future Features

1. **Multi-Timeframe Confluence Enhancements**
   - Include higher timeframes (H1, H4) for trend alignment.
   - Filter trades against multi-timeframe market reversals.

2. **Volatility & News Filters**
   - Avoid trading during low ATR periods or high-impact news events.

3. **Adaptive Position Sizing**
   - Scale-in/out positions dynamically based on momentum or volatility.

4. **Session Filters**
   - Enable only London/NY trading sessions based on user's local time.

5. **Advanced Dashboard Enhancements**
   - Live trade info: entry price, SL, TP, floating PnL.
   - Graphical support/resistance zones on chart.
   - Momentum heatmap or trend strength visual.

6. **Trade Optimization**
   - Fine-tune confirmation bars, RSI periods, MA lengths.
   - Integrate trailing stop adaptive logic for maximum profit capture.

7. **User Configurable Parameters**
   - Easy-to-adjust settings for ATR multiplier, MA periods, RSI period, number of confirming bars, lot size, and max trades per signal.

---

## Installation

1. Copy `AlexPro.mq5` and all module files into:

2. Compile the EA using MetaEditor.
3. Attach `AlexPro` to your chart (M1/M5 recommended).
4. Enable “AutoTrading”.
5. Observe real-time dashboard updates and signals.

---

## Recommendations

- **Testing:** Always test in a demo account before live deployment.
- **Risk:** Even with advanced filters, market reversals can occur; manage risk accordingly.
- **Timeframes:** Entry on M5 confirmed by M15 trend is optimal; lower timeframes increase signal noise.


## References

- MetaTrader 5 Documentation: [https://www.mql5.com/en/docs](https://www.mql5.com/en/docs)
- ATR and MA-based trading strategies.
- Multi-timeframe trend confirmation techniques.

---

## Closing Remarks

AlexPro is designed to provide professional-grade trade signals with robust filtering and dynamic trade management. With a clear, visual dashboard, traders can easily monitor trend strength, momentum, ATR, and active positions.  

Future updates will continue to enhance multi-timeframe confluence, adaptive risk management, and dashboard visualization, making AlexPro a high-performance, reliable tool for disciplined traders.

---

**Disclaimer:**  
Trading involves risk. Past performance is not indicative of future results. Always use proper risk management and test strategies in a demo environment before live deployment.
