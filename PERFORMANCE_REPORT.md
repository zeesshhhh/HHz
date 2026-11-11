# Signal Bot: accuracy review and changes

Data used: `app_paper_trades.csv` (205 trades, 182 closed, Oct 31 17:50 to Nov 1 05:05 UTC) and `lab_*` files (1,500 snapshots).
`bot_paper_log.csv` has only the header row, so there is nothing to analyse for the GitHub bot.

## 1. What the results show (before any change)
| | n | win rate | net R | profit factor |
|---|---|---|---|---|
| All closed app trades | 182 | 40.7% | -42.7 | 0.62 |
| BUY | 79 | 43.0% | -14.5 | 0.69 |
| SELL | 103 | 38.8% | -28.3 | 0.57 |
| 5m | 161 | 41.6% | -34.7 | 0.65 |
| 30m | 16 | 31.2% | -6.8 | 0.41 |
| 1h / 15m | 3 / 2 | too few | | |

With a 1:1 target and the 0.05R fee, a trade must win **52.5%** to break even. 40.7% over 182 trades is clearly below that
(about 3 standard errors), so the poor accuracy is real, not noise.

The numbers in your brief (BUY 40.63%, SELL 54.29%, overall 47.76%) do not match any CSV you uploaded (67 closed trades would be needed).
Please send the file they came from if you want those tuned.

## 2. Root cause that the data supports
Price extension from EMA20 at entry (`ext_atr`):
| extension | n | win | net R |
|---|---|---|---|
| up to 1.0 ATR | 62 | 41.9% | -13.1 |
| 1.0 to 1.2 ATR | 37 | 56.8% | +3.6 |
| **1.2 to 1.5 ATR** | **83** | **32.5%** | **-33.3** |

The old gate allowed up to 1.5 ATR. Those 83 late entries produce 78% of all losses, and the pattern holds in both the first (36%) and
second (27%) time halves of the data. This confirms your observation.
Other findings: signal score is not monotonic (score 0.5-0.6 won only 27.6%, n=29), 5m trades are 88% of the sample, and the old
quality score of 4 (n=124) won 37%.

## 3. Counterfactual with the new extension limit (not a true backtest)
Dropping the trades with extension above 1.2 ATR from the same data:
| | n | win | net R | avg R |
|---|---|---|---|---|
| Before | 182 | 40.7% | -42.7 | -0.235 |
| After (ext <= 1.2) | 99 | 47.5% | -9.5 | -0.096 |
| After, first 60% of time | 59 | 42.4% | -11.5 | -0.194 |
| After, last 40% of time | 40 | 55.0% | +2.0 | +0.050 |
Still below break-even overall (95% interval for the win rate: 37.9% to 57.2%). So this change removes most of the loss, but
**it does not prove a profitable edge.** BUY after the gate: 45 trades, 55.6%, +3.2R. SELL after the gate: 54 trades, 40.7%, -12.7R, negative
in both halves. That sample is one 11-hour window in a mostly rising market, so treat the BUY/SELL gap as a hypothesis.

## 4. Indicator lab (1,500 snapshots, one night, highly correlated across coins)
Overall verdict: direction right 46.4%, race win 49.5% (no edge). Best: RSI(14) 58.4% (n=436), RSI(2) 52.7%, Z-score 52.1%,
CCI 52.0%, Bollinger %B 52.0%. Worst: ADX 44.8%, Ichimoku 45.2%, Linear regression 45.7%, TRIX 45.9%.
The pattern is that mean-reversion style indicators beat trend-following ones in this sample. RSI, CCI, Stochastic, Williams and %B all
measure the same thing, so they count as about one signal, not five. One night of data cannot support re-weighting the verdict, so the
weights are unchanged and the lab keeps collecting.

## 5. What changed in the app (`app_src/main.dart`)
* **Paper tab live board**: every open trade shows exchange, side, entry, current rate, TP, SL, unrealized P&L ($ and R), P&L %, TP progress,
  SL distance, status (OPEN LIVE / STALE / OFFLINE) and time since entry; summary cards (open, unrealized, realized, winning now, losing now,
  average TP progress, average SL distance); manual refresh; last update time. Open trades are not counted as wins or losses.
* **Rates**: Binance best bid/ask for all symbols in one request every 3 seconds (futures, spot as fallback). BUY is valued at the bid, SELL at
  the ask, minus the 0.05R fee. Forex/gold/oil use Yahoo Finance (can be delayed, labelled). Not a WebSocket stream.
* **Signal quality gate**, separate BUY/SELL constants (`gateExtMax`, `gateRsiLimit`, `gateMinScoreAdd`): anti-chasing limit lowered
  from 1.5 to 1.2 ATR; market regime (strong up/down trend, ranging, high/low volatility, possible reversal) with counter-trend, high-volatility
  and low-volatility rejections; late-entry check (over 3 ATR in 5 candles); strong opposite candle check; support/resistance within 0.5 ATR;
  existing volume, RSI, higher-timeframe, Bitcoin and funding checks are kept. Every rejection is shown as NO TRADE with the reason (Paper tab list, and
  a line under the Final call in Markets).
* **Dashboard**: signals (session), executed, open, closed, wins, losses, win rate, TP rate, SL rate, average win/loss, net P&L, profit factor,
  expectancy, max drawdown, direction-right vs profitable, plus breakdowns by timeframe, direction, ADX range, market regime and agreeing indicator.
* **Amount per trade (USD)**: new input in the Paper settings. Typed amount = position size, so profit/loss = price move % x amount and a stop-out loses about amount x stop distance %. Empty = the old rule (risk 1% of the paper account). New `Amount` column in the live board and `amount_usd` in the CSV. The bot has the same option: `PAPER_AMOUNT` in `config.py` (None = old rule). The 1:1 reward-to-risk is unchanged.
* **Stop a trade manually**: a red `Close` button on every open trade (live board and on the Markets chart card). It asks for confirmation, exits at the current bid (BUY) or ask (SELL), charges the same 0.05R fee, saves immediately and counts as a closed trade with reason MANUAL.
* **Tap a trade to see it on the chart**: tapping a row (open or closed) in the Paper tab switches to Markets, selects that coin and timeframe, and for open trades draws Entry, SL and TP lines on the chart plus a summary card with live P&L.
* **Filter for open trades**: coin search, Side (All/BUY/SELL), Timeframe (only the ones you have open), P&L now (All/Winning/Losing) and Sort (Newest, Best/Worst P&L, Closest to TP, Closest to SL), with a Clear button and a "showing X of Y" line. The summary cards follow the filter.
* **Mean-reversion BUY strategy ("App MR", experimental, switch in Paper settings)**: opens a paper BUY when the Z-score(20) is oversold and at least one more stretch indicator (RSI(2), CCI, Bollinger %B, MFI, Stochastic RSI, Williams %R) agrees. Same 1:1 plan, news blackout, cooldown and one-trade-per-coin as the trend trades, but its own label so results never mix (new "By strategy" breakdown). Evidence (lab snapshots Nov 1, 6 hours): after these BUY signals price rose 64.3% of the time, average +0.43 ATR (n=42, 70% in the first half and 59% in the second). The matching SELL signals lost (price rose +0.6 ATR on average), so SELL is off (`mrAllowSell`). Small sample and a mostly rising window: treat as an experiment.
* **Price path logging**: every open trade records its unrealized R about every 5 minutes (new `r_path` CSV column). With this, break-even and trailing-stop rules can be tested on real paths instead of guessed.
* Trades now store `market_regime` and `agreeing_indicators` (two new CSV columns at the end; old saved trades still load).

## 6. What was NOT done, and why
* **No backtest per timeframe (5m/15m/30m/1h) and no out-of-sample optimisation of RSI/Z-score/weights**: this environment has no market-data access
  and no Flutter/Dart, so I could not download history or run the app. The new regime, late-entry, candle and support/resistance limits are
  sensible defaults, not validated values. Use the new CSV columns to judge them after 100+ trades per rule.
* **TP/SL, trailing stop, break-even, partial profits not changed**: the CSV only had best/worst move, not the path, so the effect could not be
  measured. The new `r_path` column fixes that for future trades. 26 of 108 losing trades reached +0.5R first, which makes break-even worth testing, but it needs candle-by-candle data.
* **No WebSocket**, no per-timeframe parameter sets, and the Python bot was not changed.
* Look-ahead: the app already enters at the next candle's open using only the closed candle, which I kept.

## 7. Testing
* `tests/test_logic.py`: Python mirrors of the new formulas (live P&L for BUY/SELL, bid/ask side, regime rules, dashboard maths checked against an independent
  pandas calculation on your CSV: PF 0.895, net -421.65 $, max drawdown 10.74% on the older 74-trade file). These test the logic, **not the Dart code**.
* The Dart code was checked for balanced brackets and lexing only. **It has not been compiled or run.** If Build APK fails, send me the log.
* Not tested: real-device rendering, restart behaviour, offline handling on a phone, exchange symbol mapping against live APIs.

## 8. Modified files
`app_src/main.dart`, `config.py` and `paper.py` (new `PAPER_AMOUNT` option only), `tests/test_logic.py` (new), `PERFORMANCE_REPORT.md` (new). Everything else is unchanged from your upload.

## 9. Experiments added on Nov 1 (second lab window, 360 snapshots, 12:15-12:55 UTC) - UNVALIDATED
Offline tests on `lab_signal_snapshots.csv` and `app_paper_trades.csv` (107 closed trades). All in-sample, one rising-market window.

**Added (small, switchable, not compiled):**
* **Stretch veto** (`gateStretchVeto`, `stretchInds` in `main.dart`): a trend SELL is rejected when 2 or more of RSI(14), Z-score, %B, CCI, MFI, RSI(2) already say oversold.
  Reason: 97 of 105 trend SELLs had an oversold reading and won 18%; the veto removes 80 of them (15% win), the 25 that pass still only won 28%.
  BUY side is OFF (`{1: 0, -1: 2}`) because the same test would have blocked 18 of 21 BUYs that won 72%. Set both to 0 to disable.
* **RSI (14) added to the mean-reversion BUY confirmers**: Z-score + RSI(14) + one more gave 97% direction on 38 signals.

**Tested and NOT added:**
* Blending the oscillators into the verdict score: with weight 1 only 2 of 360 snapshots reach a 0.5 score, at 0.3 accuracy is 36% (trend alone 33%). It suppresses trades without improving them.
* Break-even stop on the logged `r_path`: +5R at best (trigger 0.3R) on -54R total, with only about 5 path samples per trade. Not a fix.
* Mean-reversion SELL: 36% direction (n=11). Stays off.

**Caution:** all 59 mean-reversion BUY signals came from the first 5 of 9 timestamps (one dip-and-rebound event). Treat the 91% as one event, not 59 independent results.

## Update (Nov 1, evening)
* **Stretch veto** in the quality gate: a trend SELL is rejected when the Z-score says price is oversold, and a trend BUY when it says overbought. Reason: in the 12:20 UTC data the trend SELLs were opened on coins the lab marked oversold and were stopped out by the bounce.
* **Loose-filter warning** in the Paper settings when the quality filter or ADX filter is Off or the strength is below 0.35. In the 12:20 UTC data every filter was off (quality 0, ADX down to 9, score 0.21): 128 of 154 trades were SELLs, 96 opened in one second, 26.5% won.
* **15m removed from the timeframes once** (one-time migration; switch it back on if you want). 15m has lost in three data sets (about 29% wins over 28 trades).
* Evidence level: all small samples. 19 closed trades in the latest set (MR 15 trades, 47% wins, -2.1R). Judge the strategies only after 100+ closed trades each.

## Update 2 (Nov 1, night)
* **Latest data**: 33 closed app trades, 33% wins, -13.0R. Mean reversion: 26 trades, 38.5% wins, -7.6R (first half 8 wins of 13, second half 2 of 13 as the market fell). Every MR trade was a dip-buy while 7-10 trend indicators were bearish; 12 of 22 losses never moved up. Your own backtest also had Mean reversion negative (-7.6R, 20 trades). **MR is now off by default** (one-time migration; the switch is still in the Paper settings).
* **Selectable target (reward:risk)** in the Paper settings: 1:1 (default, unchanged), 1:1.5 or 1:2, plus a "By target" breakdown. Reason: 1:1 needs about 52.5% wins to break even, and the strategies that were profitable in `backtest_results.txt` (Intraday ORB PF 1.21 over 167 trades, Day trading PF 1.18 over 281, Reversal PF 1.14 over 148) won only 38-43%, which only works with targets above 1:1. The bot has the same switch (`RR` in `config.py`).
* **Not proven**: these backtest edges are small (about +0.09 to +0.13R per trade) and untested forward. Compare 1:1 against 1:1.5 or 1:2 on the same strategies over 100+ trades each.

## Update 3 (Nov 9): speed with hundreds of open trades
* **Cause of the slowdown**: with "No limit", 500 trades were open. Every second the whole screen was rebuilt and the live table drew up to 150 rows x 15 cells, and every open coin was re-checked against candle data every 10 seconds.
* **Fixes**: the live table shows 30 rows at a time ("Show 30 more" / "Show less"; filters and the summary cards still use all trades); with more than 60 trades the whole screen refreshes every 5 seconds while the live table still updates every second; with more than 60 open trades each coin's candles are re-checked every 60 seconds instead of 10 (candles still cover the whole time since entry, so no stop or target is missed, a close can just show up to a minute later).
* **Setting to use**: Paper tab, "Max open trades" 100 (or 50). 500 correlated trades are mostly the same bet and distort the results.
* **Max open trades** now offers 20, 50, 100, 200, 500 and No limit. The limit counts automatic trend and mean-reversion trades together (your manual trades never count). The speed fixes above are what make 500 workable.

## Update 4: custom target ratio
* Paper settings now has a **Custom 1 : ___** box under the 1:1 / 1:1.5 / 1:2 chips. Any value from 0.5 to 10 (e.g. 1.25). Empty box = 1:1, which stays the default.
* The line under it shows the current target and the break-even win rate for it (105 / (ratio + 1) %, fees included).
* Applies to new trades only. "By target" now shows up to two decimals (1:1.25), so results per ratio stay separate.
* GitHub bot: change `RR` in `config.py` (e.g. `RR = 1.25`).

## Update 5: Focus on profitable coins, directions and indicators
* New **Focus** card in the Paper tab (below the dashboard). It uses closed trades only, without manual closes, and splits every group into its older and newer half:
  * Direction overall (all BUY, all SELL)
  * Proven profitable coins + direction: 15+ trades, profit factor above 1.1, profit in both halves
  * Coins + direction losing in both halves
  * Indicators better / worse than the average trade of the same direction in both halves (by at least 0.1 R per trade)
  * Leading coins + direction with 5+ trades that are not proven yet
* **Focus filter** (Off / Skip losers / Proven only). Default Off. Only affects new auto and MR trades; skipped signals appear in the NO TRADE list with the reason.
  * Indicators are judged against the direction average because almost every indicator agrees on most trades. On the uploaded data every indicator lost in both halves only because the whole system lost; an absolute rule would have blocked nearly every trade.
* **app_profit_analysis.csv**: manual closes left out; new groups `coin+side+timeframe` and `coin+side+indicator`; new columns `first_half_r`, `second_half_r`; verdict is now `PROVEN (both halves)`, `LOSING (both halves)`, `profitable, not consistent`, `mixed` or `too few trades` (under 15).
* Result on your uploaded trades (475 with indicators recorded): no coin + direction has 15 trades yet; BUY -26.8R, SELL -31.3R; only Elder Ray (13) SELL beat its direction average in both halves (24 trades).

## Update 6: why no auto trade opened
* The status line under "Auto paper trading" now lists why signals were skipped in each check: no signal / weak score or ADX, failed the quality gate, coin already has an open trade, cooldown, news blackout, Focus filter, invalid stop/target, max open reached.
* It also says when it is waiting for a candle close, when no timeframe is selected, or when the Binance futures coin list did not load (before, the scan stopped silently in these cases).
* Fixed: after a reset, an old migration set Max open trades back to 8. The unlimited migration now runs after it.
* Focus "Proven only" shows a red warning while nothing is proven (it would open no trades).

## Update 7: Focus on what makes money (bot focus signals)
Walk-forward test on 2,201 closed GitHub bot trades (Oct 30 - Nov 9), using only trades closed before each signal:
| Rule | Trades | Net R | PF | Older half | Newer half |
|---|---|---|---|---|---|
| All bot signals | 2,201 | -70.8 | 0.95 | -136.6 | +65.8 |
| Strategy + direction with 30+ closed trades and net profit | 630 | +81.4 | 1.21 | +10.8 | +70.6 |
| Same, thresholds 25 / 40 / 50 | 650 / 574 / 542 | +68.5 / +80.4 / +64.0 | 1.17-1.22 | | |
| Same rule at a 1:1 target (estimated from MFE) | 483 | +11.2 | 1.05 | +22.5 | -11.3 |
| App's own indicator signals (426 trades), best filter found | - | negative | | | |

* The edge exists at the bot's own targets (mostly 1:2), not at 1:1. 1:2.5 targets did worse than 1:2.
* Today the rule selects only SELL strategies (Day trading, Quant factor, Intraday ORB, Swing, Price action, Breakout, Breakout 30m, Trend 4H, Day trading 30m), because crypto fell during the test. It adapts: a BUY strategy becomes focus again when its record turns positive, because the bot keeps paper-trading every strategy.
* App changes: Signals tab shows FOCUS badges, each signal's strategy + direction and coin + direction record, and "Show only focus signals" (on by default). Paper settings: Trade source = Bot focus signals (default) / App indicators / Both. Bot focus trades copy fresh bot signals (30 min or newer, price not more than 0.3R past the bot's entry, crypto only) with the bot's own stop and target; strategy "Bot: <name>" in the breakdowns. Your 1:1 setting still applies to App indicator trades.
* Do NOT upload this project's config.py / strategies.py to the bot repo: they set 1:1 and 4 strategies and would stop the bot from producing the record this rule depends on.

## Update 8: background running and the Experiment lab
* **Why in-app trades stop**: the app's background mode keeps running while the app is open or minimized. Swiping it away from recent apps closes the app's Dart engine (Android rule), so in-app scanning stops. This cannot be fixed inside the app without moving all trading code to a native background service.
* **What never stops (runs on GitHub)**:
  * **Bot focus account** (Paper and Signals tabs): replays the bot's own paper log in time order and keeps the trades that were FOCUS when they opened. On the uploaded log: 630 closed, +81.4R, 64 open. Needs nothing on the phone.
  * **Experiment lab** (new `experiments.py` + `.github/workflows/experiments.yml`, every 10 minutes): 40 indicators x top 30 OKX coins x 5m/15m/30m/1h/4h/1d. Each new signal opens a virtual trade at the next candle's open, followed to 1:1 and 1:2 targets (stop 1.5 ATR, 0.05R fee), one open trade per indicator/coin/timeframe. Results are published to the `exp-data` branch (a single commit replaced every run, so the repo does not grow) and shown in the new **Experiments** tab: by indicator, indicator + timeframe, coin, indicator + coin and timeframe, with PROVEN (50+ trades, PF > 1.1, profit in both halves) and LOSING labels.
* Tests (`tests/test_experiments.py`): target/stop maths, no look-ahead (indicators on data up to a candle equal the values computed with later data), runs after every candle give the same totals as delayed catch-up runs, halves add up. On random simulated prices the lab shows no edge (49% wins at 1:1, loss after fees), as it should.
* Not tested: real OKX responses from GitHub (same endpoint the bot already uses), and the Dart code was not compiled.

## Update 9: Lab reduced to 7 indicators (10 since Update 10), with full trade lists
* The app's Lab now records only RSI (2), CCI (20), Stochastic (14,3), Stochastic RSI, MFI (14), Bollinger %B (20,2) and Candle pattern. Older saved Lab data is trimmed to these 7 when the app starts. The OVERALL verdict rows are gone.
* Every Lab signal is shown as a trade: entry at the signal candle's close, target and stop 1.5 ATR (1:1), judged over the next 6 candles, 0.05R fee. Result WIN / LOSS / TIMEOUT (neither hit, closed at the last price, capped at +/-1R) / OPEN (not scored yet).
* Tap an indicator to see all its trades (newest first, 50 at a time), split by direction and timeframe, with a download button for that indicator's trades. Filters: style (Scalping / Intraday / Swing / Position) and BUY / SELL.
* Up to 6,000 scored candles are kept (was 1,500 with about 50 indicators each).
* Preview on the uploaded snapshots (98 rows, but only 3 candle times in one 45-minute dip, mostly SELL): RSI (2) +16.5R over 36, CCI (20) +18.5R over 54, Stochastic +13.6R over 43, Stochastic RSI +11.3R over 57, MFI +6.7R over 21, Bollinger %B +9.9R over 20, Candle pattern +7.6R over 50. One window, not evidence yet.
* The Experiments tab (GitHub) still tests all 40 indicators, so the 7 can be compared with the rest.

## Update 10: three more Lab indicators
* Added RSI (14), Z-score (20) and Ultimate Oscillator to the Lab, which now records 10 indicators. Same trade rules and trade lists.
* Preview on the same uploaded snapshots (one 45-minute window): RSI (14) +5.6R over 21, Z-score (20) +7.6R over 14, Ultimate Oscillator +0.8R over 3.

## Update 11: news auto-trades on all timeframes, and all logs in one ZIP
* **App, News tab, "Auto paper trades from news"** (on by default, own switch): a new headline (60 minutes or newer) with a bullish or bearish keyword score that names a coin opens a paper BUY / SELL on that coin on all 6 timeframes (5m, 15m, 30m, 1h, 4h, 1d). Stop 1.5 ATR(14) of each timeframe, target = the reward:risk setting (1:1 by default), normal time limit per timeframe, one news trade per coin and timeframe, up to 3 coins per headline. Coins are matched by curated names (bitcoin, ethereum, solana, chainlink, near protocol...), so plain words like "near" or "link" do not trigger trades. News trades are labelled "News headline", do not block the other auto trades and are left out of the Focus statistics. The card shows results overall, by direction and by timeframe, and the latest 20 trades (tap to see on the chart). Runs while the app is open or minimized.
* **Experiment lab (GitHub, 24/7)**: new experiment "News headline" with the same keyword score and coin names (CoinDesk, Cointelegraph, Decrypt). Entry at the current price after the headline; only candles that start after the entry can hit the stop or target (no look-ahead). Each headline counts once even if several sites publish it. Shown in the Experiments tab like any indicator.
* **Download all logs (one ZIP)** (Paper, Lab and Experiments tabs): one file with app_paper_trades, app_trade_indicators, app_profit_analysis, news_trades, news_headlines, bot_paper_log, bot_focus_account, lab_indicator_accuracy, lab_signal_snapshots, lab_trades, experiments_summary, experiments_daily, experiments_open_trades and a README listing anything that could not be included. The ZIP is written by the app itself (no new package); its byte layout was checked with Python's zip reader.

## Update 12: logs of Nov 10 and a bot-signal guard
* Fix: bot focus signals with a target at or below 0, a stop at or below 0, or a stop more than 20% from the entry are skipped (seen: AKE 4h, stop 79% away, target -0.0009).
* Logs (Nov 9-10): app Bot focus trades 5 closed, 4 TP, +5.25R. Experiment lab 10,121 closed trades in its first day, -2,041R at 1:1: the market fell, BUY lost on every timeframe. The lab code was re-checked on simulated rising and falling markets (BUY wins 82% when rising, SELL 86% when falling, on every timeframe), so the result is the market, not a bug.
* Same pattern in both labs: selling overbought (mean-reversion SELL) made money, buying oversold lost. Experiment lab: Z-score / Bollinger reversal SELL +47.7R (126 trades, 71% wins), RSI 2 SELL +36.7R, CCI reversal SELL +36.3R, Stochastic SELL +26.1R, Williams %R SELL +23.2R, MFI SELL +18.2R. App Lab: Stochastic SELL +21.4R, CCI SELL +11.0R, all 10 SELL sides positive, all BUY sides negative.
* Z-score 20 reversal and Bollinger reversal are the same signal (price crossing back inside 2 standard deviations); their results are identical on every coin.
* One day of data, all in one market direction: not proven yet (needs 50+ trades and profit in both halves).

## Update 13: "+ trend" versions in both labs, and what 8 earlier days say
* App Lab: each of the 10 indicators also has a "+ trend" version (BUY only while price is above EMA 200 of the same timeframe, SELL only while below). Filter chips All / Plain / With trend. Experiment lab: "+ trend" versions of the 8 mean-reversion signals (RSI 2, RSI 14, CCI reversal, Stochastic, Williams %R, MFI, Z-score, Ultimate oscillator).
* Check on older Lab snapshots that still contained EMA 200 (8,840 snapshots, Oct 30 - Nov 9, 8 days with rising and falling days, 5m/15m/1h/4h):
| Version | Trades | Net R | R per trade | Older half | Newer half |
|---|---|---|---|---|---|
| Plain (10 indicators) | 20,028 | -2,619 | -0.131 | -1,380 | -1,239 |
| + trend | 6,489 | -806 | -0.124 | -185 | -621 |
  Every indicator lost in both versions, and SELL lost too on those days. The trend filter cuts trades by two thirds but does not turn the signals profitable. The SELL profits of Nov 10 came from one falling day.
* The only result so far that held up when tested on data it was not built from is the bot focus rule (walk-forward +81.4R over 630 trades; app copies +5.25R over the first 5).

## Update 14: logs of Nov 11
* **Bot focus rule on outcomes not seen when it was built** (bot trades that closed after Nov 9 18:06): focus 64 trades, 64% wins, +54.5R, PF 3.26; non-focus 54 trades, 63% wins, +38.7R, PF 2.84. Almost all SELL in a falling market, so most of the gain is the market; focus still did better per trade (+0.85R vs +0.72R). Cloud Bot focus account: 694 closed, +133.0R.
* **App indicator auto trades** ("App auto", trade source set to App indicators or Both): 139 closed, 24.5% wins, -77.5R (104 stops, 34 targets), all opened in one evening (Nov 10 18:00-24:00 UTC), both directions, every timeframe. App copies of bot focus signals: 6 closed, +5.07R.
* **Experiment lab, 3 days (25,373 trades)**: -3,208R at 1:1. Best: Stochastic SELL +57.4R / 313 (positive 2 of 3 days), CCI reversal SELL +32.8R, Z-score SELL +31.0R; all mean-reversion SELL lost on Nov 11 so far. "+ trend" versions lost more than the plain ones (CCI + trend SELL -67.0R, RSI 2 + trend SELL -61.2R), in line with the 8-day check: the trend filter does not help.
* **App Lab**: plain SELL +128.7R over 610, plain BUY 0.0R over 1,276, "+ trend" SELL -21.5R over 118.
* **News**: app traded one headline (BTC SELL on 6 timeframes, 1 closed at TP +0.95R); the keyword score read "resume withdrawals after $49M hack" as bearish. The cloud News headline experiment opened no trade in 3 days. Change: the lab now records each news feed's status (items or HTTP error) and adds Google News as a backup feed; the Experiments tab and experiments_last_run.json in the logs ZIP show it.
