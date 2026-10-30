"""Live crypto order flow from OKX public API (no key needed): taker buy/sell volume,
funding rate, long/short account ratio. Live-only (not in the backtest). Fails safe."""
import requests

BASE = "https://www.okx.com/api/v5"
COIN = {"BTC-USD": "BTC", "ETH-USD": "ETH", "SOL-USD": "SOL"}

def _get(path, **params):
    r = requests.get(BASE + path, params=params, timeout=15)
    return r.json().get("data") or []

def live_flow(symbol):
    ccy = COIN.get(symbol)
    if not ccy:
        return None
    out = {}
    try:
        rows = _get("/rubik/stat/taker-volume", ccy=ccy, instType="SPOT", period="1H")[:6]
        sell, buy = sum(float(x[1]) for x in rows), sum(float(x[2]) for x in rows)
        out["taker_buy_pct"] = 100 * buy / (buy + sell)
    except Exception:
        pass
    try:
        out["funding_pct"] = 100 * float(_get("/public/funding-rate", instId=f"{ccy}-USDT-SWAP")[0]["fundingRate"])
    except Exception:
        pass
    try:
        out["long_short"] = float(_get("/rubik/stat/contracts/long-short-account-ratio", ccy=ccy, period="1H")[0][1])
    except Exception:
        pass
    return out or None

def verdict(side, f):
    """Returns (ok, notes). ok=False when buyers/sellers clearly oppose the trade."""
    if not f:
        return True, []
    buy, ok, notes = side == "BUY", True, []
    t = f.get("taker_buy_pct")
    if t is not None:
        notes.append(f"Taker buys {t:.0f}% of volume (6h)")
        if (buy and t < 45) or (not buy and t > 55):
            ok = False
            notes.append("aggressive flow opposes this trade")
    fr = f.get("funding_pct")
    if fr is not None:
        notes.append(f"Funding {fr:+.3f}%")
        if (buy and fr > 0.05) or (not buy and fr < -0.05):
            notes.append("crowded positioning, higher squeeze risk")
    ls = f.get("long_short")
    if ls is not None:
        notes.append(f"Long/short ratio {ls:.2f}")
    return ok, notes
