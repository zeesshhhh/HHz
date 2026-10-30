# Crypto, forex and futures strategy bot

30 strategy styles in one Telegram bot. Run backtest first, then let paper trading prove which ones pay.

## Setup
1. @BotFather > /newbot > copy token. Message your bot, open https://api.telegram.org/bot<TOKEN>/getUpdates, copy `chat.id`.
2. Repo > Settings > Secrets > Actions: `TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID`. Optional: `ANTHROPIC_API_KEY` (AI summary), `COPY_SOURCE_URL`.
3. Actions > Signal bot > Run workflow > mode `backtest`. Read it before trusting anything.
4. Schedules: scan every 15 min, daily report 06:00 UTC, investing report Mondays 07:00 UTC.
   Private repos have 2,000 free Actions minutes per month: use a public repo or change the cron to hourly.

## Where each strategy lives
| Strategy | How it works here | Where |
|---|---|---|
| Scalping | 5m EMA9/21 cross, ADX filter, tight stop | strategies.py |
| Day trading | 15m pullback to EMA21, VWAP side | strategies.py |
| Intraday | 15m opening-range breakout, same-day exit | strategies.py |
| Swing | 1H entry confirmed by 4H trend, scored out of 7 | signals.py |
| Position | Daily golden/death cross, wide stop | strategies.py |
| Trend | Aligned EMAs, ADX above 25, dip entry | strategies.py |
| Momentum | Weekly cross-asset 60-day ranking, long top / short bottom | special.py |
| Breakout | 20-bar Donchian break, expansion, volume | strategies.py |
| Reversal | Band exhaustion plus engulfing or hammer | strategies.py |
| Range | Low ADX, fade range edges, target mid | strategies.py |
| Mean reversion | Z-score below -2 or above +2 with RSI, target mean | strategies.py |
| Price action | Pin bar or engulfing at confirmed swing levels | strategies.py |
| Quantitative | Multi-factor z-score (momentum, flow, trend) | indicators.py, strategies.py |
| News trading | Headline sentiment plus confirming candle | special.py |
| Event-driven | Break of pre-event range after high-impact release, plus 1-hour heads-up | special.py, main.py |
| Pairs trading | Hedge-ratio regression, spread z-score (ETH/BTC, EUR/GBP, gold/silver) | special.py |
| Arbitrage | Coinbase vs Kraken vs OKX spread alerts (alert only) | special.py |
| Options trading | Deribit put/call ratio and IV, SPY chain, option-structure ideas | special.py |
| Futures trading | Gold, silver, S&P, Nasdaq, crude run through all strategies, plus funding data | config.py |
| Forex / Crypto trading | Asset classes with forex session filter and crypto order flow | main.py |
| Algorithmic trading | The scheduled engine itself, rules only, no discretion | main.py |
| HFT | Order-book depth snapshot only (see limits) | special.py |
| Copy trading | Relays trades from a JSON feed you point to | special.py |
| Paper trading | Every alert becomes a virtual trade with per-strategy results | paper.py |
| Value / Growth / Dividend investing | Weekly fundamental screens on STOCKS | fundamentals.py |
| Long-term / buy and hold | 200DMA, 12-month return, drawdown, DCA guidance, benchmark in backtest | fundamentals.py, backtest.py |

## Crypto futures coins
`FUTURES_TOP_N` in config.py (default 30) adds the top USDT perpetual coins by 24h volume, scanned with OKX data on 15m, 30m, 1H, 4H and 1D. They run every strategy but are always tagged experimental. Set it to 0 to switch off. Binance coins outside the top N are available in the app's Scanner tab only.

## Optional trading-platform market-data connectors

Choose one source for the Python signal engine with the environment variable `MARKET_DATA_PROVIDER` (one provider at a time):
`yahoo` (default), `mt5`, `bybit`, `okx`, `oanda`, or `ibkr`. These connectors fetch candles for analysis; **they do not place, modify, or close live orders**. The Flutter app's direct market screen remains a separate data client.

- **Bybit**: public market candles are supported without API credentials for supported crypto symbols. API docs: https://bybit-exchange.github.io/docs/v5/intro
- **OKX**: public swap candles are supported without API credentials for supported crypto symbols. API docs: https://www.okx.com/docs-v5
- **OANDA**: set `OANDA_API_TOKEN` and `OANDA_ENV=practice` (default) or `live`. Gold/silver and FX symbol availability depends on the account and region. API docs: https://developer.oanda.com/rest-live-v20/introduction/
- **MetaTrader 5**: install the MT5 terminal and the official `MetaTrader5` Python package on a compatible Windows machine; optional `MT5_LOGIN`, `MT5_PASSWORD`, `MT5_SERVER` environment variables can select an account. Broker symbol names differ, so update `MT5_SYMBOLS` in `broker_adapters.py` for suffixes such as `.a` or `m`.
- **Interactive Brokers**: install `ib_insync`, run TWS or IB Gateway, and configure `IBKR_HOST`, `IBKR_PORT` (paper TWS commonly 7497), and `IBKR_CLIENT_ID`. IBKR requires market-data permissions; futures expiry/contract selection may need to be configured for your account. API docs: https://www.interactivebrokers.com/docs/

Set secrets in your hosting environment/GitHub Actions, never commit credentials into the repository. Keep API keys read-only where possible. To test live order execution, build a separate explicit execution layer and start with each platform's demo/paper environment; this package does not trade live.

## Honest limits
- True HFT needs colocated servers and microsecond latency. GitHub Actions cannot do it. The bot only reads order-book imbalance at scan time.
- Arbitrage and copy trading are alerts. Fees, withdrawal time and USD-vs-USDT premiums often erase small spreads.
- Yahoo data can be delayed or patchy, and forex volume is mostly missing.
- Backtests ignore slippage in fast markets. Judge strategies by their paper-trading record, not one backtest.
- Analysis only, not financial advice.

## Android app (APK)
The bot publishes `docs/feed.json` after each run. The app reads it, so the repo must be public.
1. Run the Signal bot workflow once so `docs/feed.json` exists.
2. Actions > Build APK > Run workflow (about 10 minutes).
3. Open the repo's Releases page on your phone, download `signal-bot.apk`, and allow "install unknown apps" when asked.
4. Tabs: Markets, Scanner, Signals, News, Alerts, Account (the bot's paper trades), Paper (the app's own paper trades), Report. Pull down to refresh.

### In-app auto paper trading (Paper tab)
- Switch on Auto paper trading. Choose the coins (top 20, 50 or 100 by 24h volume) and the timeframes (5m, 15m, 30m, 1h, 4h, 1d). When a candle closes on a chosen timeframe, the app checks each coin once on that candle and opens virtual trades from signals that meet your minimum strength and quality filter. Signals more than 60% of a candle old are skipped so entries are never stale.
- Rules: 1.2+ reward to risk, one open trade per coin and timeframe, none during a high-impact news window, cooldown after a close. 1% risk per trade, 0.05R fees, same-candle stop and target counts as a loss.
- Quality filter (Paper tab, default 3 of 5). Before a scanner trade opens, the app re-checks it: the verdict must hold on the closed candle (the forming candle repaints), price must not be stretched over 3 ATR from EMA20 or RSI exhausted, volume must not be dead, and the next higher timeframe must not oppose it. Altcoins also must not fight the Bitcoin 1h and 4h trend. Five points are then scored: next timeframe agrees, the one above agrees, volume 1.2x average or more, ADX 20+, and funding and news not crowded against it. Choose Off, 3 of 5 or 4 of 5. Quality is logged per trade, so the Paper tab and CSV show whether the filter actually improves results.
- Markets tab has a Paper trade this button for a manual entry.
- Stops, targets and timeouts are checked every 60 seconds while the app is open. On reopening, the app replays candles since entry, so hits made while it was closed are still recorded.
- Accuracy: win rate, average R, profit factor, hit target vs stop vs timeout, breakdown by timeframe, direction, signal strength and coin, plus a short list of the best and worst groups.
- Download logs: in-app CSV, bot CSV, or both at once (share sheet, or copy to clipboard). Column names match, so the two can be compared. Send the files to tune the bot.

### Keeping your data between installs
Builds are now signed with a fixed key (app_src/debug.keystore) and a rising version number, so a new APK installs over the old one and keeps your paper trades and Lab data. The one time you move from an older APK to this one, Android will ask you to uninstall first, which erases the old data. Use All logs to export before that. Data is stored as files in the app's own folder, written safely, and never overwritten if it cannot be read.

### Signal Lab (Lab tab)
- Switch it on and keep the app open. At every candle close (15m, 1h, 4h, 1d, optional 5m) for the top 10, 20 or 40 coins, it records the vote of every indicator (trend, momentum, volume, breakout, support/resistance, candle patterns, overall verdict).
- 6 candles later it scores each vote: direction right or wrong, how far price moved in ATR, and a race test (+1.5 ATR before -1.5 ATR).
- The tab compares trading styles (Scalping 15m, Intraday 1h, Swing 4h, Position 1d), indicator families and each single indicator, best first. Anything under 30 signals is greyed out.
- Download the accuracy table, the raw snapshots, or All logs (also includes paper trades and the bot log).

- Trades live on the phone only. Clearing app data or Reset deletes them, so download first.
Telegram stays your push-notification channel. The app is for viewing.


## Changes after the server Lab (one month, 46 coins)
- Mean-reversion votes (RSI, MFI, Bollinger %B, CCI, Stochastic, Williams %R, Stochastic RSI, Ultimate Oscillator, support/resistance position) are shown as "info only" and no longer count towards the verdict. They were right less often than a coin flip in every style and in the forward test.
- Keltner, Donchian, ADX, Ichimoku and SMA 50 count more; candle patterns count less.
- Auto paper trading only takes signals with ADX of 25 or more (setting: Minimum ADX), skips coins with ATR above 8% or a stop/target at or below zero, and 30m is off by default.
- `histlab.py` (optional, see HISTLAB_README.md) checks all of this on months of history.


## Paper-trading accuracy review
See `PAPER_TRADE_DIAGNOSIS.md` for the supplied CSV results, the missing-confirmation scoring issue, conservative auto-paper changes, and testing limitations.
