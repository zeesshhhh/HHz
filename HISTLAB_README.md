# Historical lab

1. Upload `histlab.py` to the root of your repo and `histlab.yml` to `.github/workflows/`.
2. Actions > Historical lab > Run workflow (defaults are fine). It takes roughly 20 to 60 minutes.
3. Read `docs/histlab/SUMMARY.md`. The other files in `docs/histlab/` hold the full tables
   (indicator_accuracy, strategy_results, monthly_baseline, regime_breakdown).

It downloads months of OKX candles for the top coins, scores each indicator after removing the market's own drift,
and simulates the verdict as trades (stop 1.5 ATR, targets 1R to 3R, costs included) next to a random-direction baseline.
Results are split into the first 60% and last 40% of history so you can see what holds out of sample.
