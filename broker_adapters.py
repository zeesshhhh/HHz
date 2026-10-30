"""Optional market-data adapters for MetaTrader 5, Bybit, OKX, OANDA and Interactive Brokers.

This module only downloads OHLC candles for signal analysis. It does NOT submit orders.
Set MARKET_DATA_PROVIDER to yahoo (default), mt5, bybit, okx, oanda, or ibkr.
Credentials are read from environment variables; never hard-code API secrets.
"""
import os
import time
from urllib.parse import urlencode

import pandas as pd
import requests

PROVIDER = os.getenv("MARKET_DATA_PROVIDER", "yahoo").strip().lower()
TIMEFRAME = {
    "5m": "5m", "15m": "15m", "30m": "30m",
    "1h": "1h", "4h": "4h", "1d": "1d",
}
BYBIT_INTERVAL = {"5m": "5", "15m": "15", "30m": "30", "1h": "60", "4h": "240", "1d": "D"}
OKX_BAR = {"5m": "5m", "15m": "15m", "30m": "30m", "1h": "1H", "4h": "4H", "1d": "1D"}
OANDA_GRANULARITY = {"5m": "M5", "15m": "M15", "30m": "M30", "1h": "H1", "4h": "H4", "1d": "D"}
# Symbols used by this bot -> common broker-native identifiers.
OANDA_SYMBOLS = {
    "EURUSD=X": "EUR_USD", "GBPUSD=X": "GBP_USD", "USDJPY=X": "USD_JPY",
    "AUDUSD=X": "AUD_USD", "NZDUSD=X": "NZD_USD", "USDCAD=X": "USD_CAD",
    "USDCHF=X": "USD_CHF", "GC=F": "XAU_USD", "GOLD": "XAU_USD",
    "SI=F": "XAG_USD", "SILVER": "XAG_USD",
}
BYBIT_SYMBOLS = {"BTC-USD": "BTCUSDT", "ETH-USD": "ETHUSDT", "SOL-USD": "SOLUSDT"}
OKX_SYMBOLS = {"BTC-USD": "BTC-USDT", "ETH-USD": "ETH-USDT", "SOL-USD": "SOL-USDT"}
MT5_SYMBOLS = {
    "EURUSD=X": "EURUSD", "GBPUSD=X": "GBPUSD", "USDJPY=X": "USDJPY",
    "AUDUSD=X": "AUDUSD", "NZDUSD=X": "NZDUSD", "USDCAD=X": "USDCAD",
    "USDCHF=X": "USDCHF", "GC=F": "XAUUSD", "GOLD": "XAUUSD",
    "SI=F": "XAGUSD", "SILVER": "XAGUSD", "BTC-USD": "BTCUSD",
}
IBKR_SYMBOLS = {
    "EURUSD=X": ("EUR", "CASH", "IDEALPRO", "USD"),
    "GBPUSD=X": ("GBP", "CASH", "IDEALPRO", "USD"),
    "USDJPY=X": ("USD", "CASH", "IDEALPRO", "JPY"),
    "GC=F": ("GC", "FUT", "COMEX", "USD"),
    "SI=F": ("SI", "FUT", "COMEX", "USD"),
    "ES=F": ("ES", "FUT", "CME", "USD"),
    "NQ=F": ("NQ", "FUT", "CME", "USD"),
    "CL=F": ("CL", "FUT", "NYMEX", "USD"),
}


def _frame(rows):
    """Convert [timestamp, open, high, low, close, volume] rows into OHLCV."""
    if not rows:
        return pd.DataFrame()
    df = pd.DataFrame(rows, columns=["timestamp", "open", "high", "low", "close", "volume"])
    df["timestamp"] = pd.to_datetime(df["timestamp"], unit="ms", utc=True, errors="coerce")
    df = df.dropna(subset=["timestamp", "open", "high", "low", "close"]).set_index("timestamp")
    for col in ("open", "high", "low", "close", "volume"):
        df[col] = pd.to_numeric(df[col], errors="coerce")
    return df.dropna(subset=["open", "high", "low", "close"]).sort_index()


def bybit_ohlc(symbol, tf, limit=300):
    inst = BYBIT_SYMBOLS.get(symbol, symbol if symbol.endswith("USDT") else symbol.replace("-USD", "USDT").replace("/", ""))
    url = "https://api.bybit.com/v5/market/kline"
    r = requests.get(url, params={"category": "linear", "symbol": inst,
                                  "interval": BYBIT_INTERVAL[tf], "limit": limit}, timeout=15)
    r.raise_for_status()
    payload = r.json()
    if payload.get("retCode") != 0:
        raise RuntimeError("Bybit: " + str(payload.get("retMsg", "market data error")))
    # Bybit returns newest first: [start, open, high, low, close, volume, turnover].
    rows = [[int(x[0]), x[1], x[2], x[3], x[4], x[5]] for x in payload["result"].get("list", [])]
    return _frame(rows)


def okx_provider_ohlc(symbol, tf, limit=300):
    inst = OKX_SYMBOLS.get(symbol, symbol if symbol.endswith("-USDT") else symbol.replace("-USD", "-USDT").replace("/", "-"))
    if not inst.endswith("-SWAP") and "-" in inst and inst.endswith("-USDT"):
        inst += "-SWAP"
    r = requests.get("https://www.okx.com/api/v5/market/candles",
                     params={"instId": inst, "bar": OKX_BAR[tf], "limit": str(limit)}, timeout=15)
    r.raise_for_status()
    payload = r.json()
    rows = [[int(x[0]), x[1], x[2], x[3], x[4], x[5]] for x in payload.get("data", [])]
    return _frame(rows)


def oanda_ohlc(symbol, tf, count=300):
    token = os.getenv("OANDA_API_TOKEN", "")
    account_mode = os.getenv("OANDA_ENV", "practice").lower()
    if not token:
        raise RuntimeError("OANDA_API_TOKEN is missing. Configure a practice/live token in environment secrets.")
    host = "https://api-fxpractice.oanda.com" if account_mode != "live" else "https://api-fxtrade.oanda.com"
    instrument = OANDA_SYMBOLS.get(symbol, symbol.replace("=X", "").replace("/", "_"))
    r = requests.get(f"{host}/v3/instruments/{instrument}/candles",
                     params={"granularity": OANDA_GRANULARITY[tf], "count": count, "price": "M"},
                     headers={"Authorization": f"Bearer {token}"}, timeout=15)
    r.raise_for_status()
    candles = r.json().get("candles", [])
    rows = []
    for c in candles:
        if not c.get("complete"):
            continue
        mid = c.get("mid", {})
        if not mid:
            continue
        rows.append([int(pd.Timestamp(c["time"]).timestamp() * 1000),
                     mid.get("o"), mid.get("h"), mid.get("l"), mid.get("c"), c.get("volume", 0)])
    return _frame(rows)


def mt5_ohlc(symbol, tf, count=300):
    try:
        import MetaTrader5 as mt5
    except ImportError as exc:
        raise RuntimeError("MetaTrader5 connector is available only where the official MT5 Python package and terminal are installed (normally Windows).") from exc
    if not mt5.initialize():
        raise RuntimeError(f"MT5 initialize failed: {mt5.last_error()}")
    try:
        if os.getenv("MT5_LOGIN") and os.getenv("MT5_PASSWORD") and os.getenv("MT5_SERVER"):
            ok = mt5.login(int(os.environ["MT5_LOGIN"]), password=os.environ["MT5_PASSWORD"],
                           server=os.environ["MT5_SERVER"])
            if not ok:
                raise RuntimeError(f"MT5 login failed: {mt5.last_error()}")
        mt_symbol = MT5_SYMBOLS.get(symbol, symbol.replace("=X", "").replace("=F", "").replace("-", ""))
        if not mt5.symbol_select(mt_symbol, True):
            raise RuntimeError(f"MT5 symbol {mt_symbol} unavailable on this broker.")
        rates = mt5.copy_rates_from_pos(mt_symbol, getattr(mt5, {"5m":"TIMEFRAME_M5","15m":"TIMEFRAME_M15","30m":"TIMEFRAME_M30","1h":"TIMEFRAME_H1","4h":"TIMEFRAME_H4","1d":"TIMEFRAME_D1"}[tf]), 0, count)
        if rates is None or len(rates) == 0:
            raise RuntimeError(f"MT5 returned no candles for {mt_symbol}: {mt5.last_error()}")
        return _frame([[int(x["time"]) * 1000, x["open"], x["high"], x["low"], x["close"], x["tick_volume"]] for x in rates])
    finally:
        mt5.shutdown()


def ibkr_ohlc(symbol, tf, count=300):
    """Optional TWS/IB Gateway connection. Requires ib_insync and a running local gateway."""
    try:
        from ib_insync import IB, Forex, Future, Stock
    except ImportError as exc:
        raise RuntimeError("Install optional ib_insync and run IB Gateway/TWS before selecting IBKR.") from exc
    host = os.getenv("IBKR_HOST", "127.0.0.1")
    port = int(os.getenv("IBKR_PORT", "7497"))  # paper TWS default
    client_id = int(os.getenv("IBKR_CLIENT_ID", "17"))
    ib = IB()
    try:
        ib.connect(host, port, clientId=client_id, timeout=10, readonly=True)
        if symbol in IBKR_SYMBOLS:
            ticker, sec_type, exchange, currency = IBKR_SYMBOLS[symbol]
            if sec_type == "CASH":
                contract = Forex(ticker + currency)
            else:
                # Expiry must be configured for futures; use front-month contract details.
                candidates = ib.reqContractDetails(Future(ticker, exchange=exchange, currency=currency))
                if not candidates:
                    raise RuntimeError(f"IBKR has no contract details for {symbol}; check market-data permissions.")
                contract = candidates[0].contract
        elif symbol.endswith("-USD"):
            contract = Stock(symbol.split("-")[0], "SMART", "USD")
        else:
            raise RuntimeError(f"IBKR contract mapping not configured for {symbol}.")
        ib.qualifyContracts(contract)
        bar_size = {"5m":"5 mins","15m":"15 mins","30m":"30 mins","1h":"1 hour","4h":"4 hours","1d":"1 day"}[tf]
        duration = "30 D" if tf in ("5m", "15m", "30m", "1h") else "1 Y"
        bars = ib.reqHistoricalData(contract, endDateTime="", durationStr=duration,
                                    barSizeSetting=bar_size, whatToShow="MIDPOINT" if getattr(contract, "secType", "") == "CASH" else "TRADES",
                                    useRTH=False, formatDate=2, keepUpToDate=False)
        rows = []
        for b in bars[-count:]:
            ts = pd.Timestamp(b.date)
            if ts.tzinfo is None:
                ts = ts.tz_localize("UTC")
            rows.append([int(ts.timestamp() * 1000), b.open, b.high, b.low, b.close, b.volume or 0])
        return _frame(rows)
    finally:
        if ib.isConnected():
            ib.disconnect()


def get_provider_ohlc(symbol, tf, period="60d"):
    """Return candles from the configured provider; Yahoo remains the default/fallback."""
    provider = os.getenv("MARKET_DATA_PROVIDER", "yahoo").strip().lower()
    if tf not in TIMEFRAME:
        raise ValueError(f"Unsupported timeframe: {tf}")
    if provider == "bybit":
        return bybit_ohlc(symbol, tf)
    if provider == "okx":
        return okx_provider_ohlc(symbol, tf)
    if provider == "oanda":
        return oanda_ohlc(symbol, tf)
    if provider == "mt5":
        return mt5_ohlc(symbol, tf)
    if provider in ("ibkr", "interactive_brokers"):
        return ibkr_ohlc(symbol, tf)
    if provider in ("yahoo", "default", ""):
        from data import get_ohlc
        interval = {"5m":"5m","15m":"15m","30m":"30m","1h":"1h","4h":"1h","1d":"1d"}[tf]
        df = get_ohlc(symbol, interval, period)
        if tf == "4h" and len(df):
            from data import resample
            df = resample(df, "4h")
        return df
    raise ValueError("Unknown MARKET_DATA_PROVIDER. Choose yahoo, mt5, bybit, okx, oanda, or ibkr.")
