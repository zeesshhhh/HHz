# Paper-trade diagnosis and conservative patch

## Findings from the supplied CSV files

- `tempoo.csv`: 124 closed trades, 13 winners and 111 losers (10.5% win rate), with recorded P&L of -$8,588.54.
- BUY trades: 111 trades, 7 winners (6.3%). SELL trades: 13 trades, 6 winners (46.2%); the SELL sample is too small to infer a reliable edge.
- By timeframe: 5m 47 trades / 23.4% wins; 15m 55 / 1.8%; 30m 18 / 0%; 1h 4 / 25%.
- The CSV contains many `quality=5` trades despite `htf_agree=0`. In the previous code, unavailable higher-timeframe analyses and missing relative volume could still earn quality points. That made the quality score overly optimistic.
- `tempo.csv` and `tempooo.csv` contain indicator/race summaries, not the same thing as realized trade profitability. The high directional percentages in some indicator/style combinations should not be treated as proven live accuracy; the sample is short and may be regime-specific.

## Changes in this package

- Missing higher-timeframe data no longer earns a quality point; where a higher timeframe exists, unavailable or non-confirming data rejects the auto-paper setup.
- Missing relative volume and missing funding/news context no longer count as positive confirmation.
- More conservative anti-chasing checks: maximum 1.5 ATR extension from EMA20, RSI exhaustion levels 70/30, and rejection of extreme volume spikes above 3x.
- Auto-paper entries now use the fully closed candle for the signal and the next candle's open for entry, rather than using indicators from a still-forming candle.
- Reduced default auto-paper exposure to 20 coins and 8 simultaneous trades; require score 0.50 and quality 4/5.
- A one-time settings migration pauses automatic entries on 15m, 30m, and 1d until those timeframes are revalidated. Manual market scanning remains available. Default auto-paper timeframes are 5m, 1h, and 4h.
- Avoids holding multiple open auto-paper positions in the same coin across timeframes and caps same-direction concurrent positions.

## Important

These changes are risk controls and fixes for optimistic/missing-data scoring, not proof that future win rate will improve. There is no honest way to promise 99% accuracy. Run fresh paper trades and a walk-forward/backtest with fees and slippage before considering live execution. Existing trades in the saved paper log are not rewritten.
