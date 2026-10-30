import time
import pandas as pd
import requests
import yfinance as yf

def get_ohlc(symbol, interval="1h", period="60d"):
    df = yf.download(symbol, interval=interval, period=period, progress=False, auto_adjust=True)
    if df is None or df.empty:
        return pd.DataFrame()
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    df = df.rename(columns=str.lower)[["open", "high", "low", "close", "volume"]].dropna()
    return df

def resample(df, rule="4h"):
    return df.resample(rule).agg(
        {"open": "first", "high": "max", "low": "min", "close": "last", "volume": "sum"}
    ).dropna()

OKX = "https://www.okx.com/api/v5"
OKX_BAR = {"5m": "5m", "15m": "15m", "30m": "30m", "1h": "1H", "4h": "4H", "1d": "1D"}

def okx_ohlc(symbol, tf):
    """Perpetual-swap candles from OKX (symbol like 'DOGE-USDT'). Last 300 bars, oldest first."""
    time.sleep(0.15)                                  # stay under OKX's 20 requests / 2 s limit
    r = requests.get(f"{OKX}/market/candles", params={"instId": symbol + "-SWAP", "bar": OKX_BAR[tf], "limit": "300"}, timeout=15)
    rows = r.json().get("data") or []
    if not rows:
        return pd.DataFrame()
    df = pd.DataFrame([x[:6] for x in rows], columns=["ts", "open", "high", "low", "close", "volume"])
    df.index = pd.to_datetime(df.pop("ts").astype("int64"), unit="ms", utc=True)
    return df.astype(float).sort_index().dropna()

def okx_top_swaps(n, exclude=()):
    """Top n USDT perpetuals by 24h USD volume, as ['DOGE-USDT', ...]."""
    rows = requests.get(f"{OKX}/market/tickers", params={"instType": "SWAP"}, timeout=20).json().get("data") or []
    out = []
    for t in rows:
        inst = t.get("instId", "")
        base = inst.split("-")[0]
        if not inst.endswith("-USDT-SWAP") or base in exclude:
            continue
        try:
            out.append((float(t["volCcy24h"]) * float(t["last"]), base))
        except Exception:
            pass
    out.sort(reverse=True)
    return [f"{b}-USDT" for _, b in out[:n]]
