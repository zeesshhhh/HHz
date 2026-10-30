import html, json, re, sys, os
import pandas as pd
from config import *
from data import get_ohlc, resample, okx_ohlc, okx_top_swaps
from broker_adapters import get_provider_ohlc
from signals import build
from indicators import add_indicators
from strategies import REGISTRY
import special, news, ai, telegram, flow_live, paper, fundamentals, feed

STATE = "state.json"
INTRADAY_FX = {"Scalping", "Day trading", "Day trading 30m", "Trend 30m", "Breakout 30m", "Intraday ORB"}

def load_sent():
    try:
        return set(json.load(open(STATE))["sent"])
    except Exception:
        return set()

def fmt(p):
    if p > 50:
        return f"{p:,.2f}"
    return f"{p:.5f}" if p >= 0.1 else f"{p:.8f}"

def full_watchlist():
    """Select instruments compatible with the configured market-data provider."""
    provider = os.getenv("MARKET_DATA_PROVIDER", "yahoo").strip().lower()
    if provider in ("bybit", "okx"):
        w = {s: "crypto" for s in ("BTC-USD", "ETH-USD", "SOL-USD")}
        if provider == "okx" and FUTURES_TOP_N:
            try:
                for s in okx_top_swaps(FUTURES_TOP_N, FUTURES_EXCLUDE):
                    w[s] = "crypto"
            except Exception as e:
                print("OKX futures list error", e)
        return w
    if provider == "oanda":
        return {s: kind for s, kind in WATCHLIST.items()
                if kind == "forex" or s in ("GC=F", "SI=F")}
    if provider == "mt5":
        return {s: kind for s, kind in WATCHLIST.items()
                if s in ("EURUSD=X", "GBPUSD=X", "USDJPY=X", "AUDUSD=X", "USDCAD=X",
                         "USDCHF=X", "GC=F", "SI=F", "BTC-USD")}
    if provider in ("ibkr", "interactive_brokers"):
        return {s: kind for s, kind in WATCHLIST.items()
                if s in ("EURUSD=X", "GBPUSD=X", "USDJPY=X", "GC=F", "SI=F",
                         "ES=F", "NQ=F", "CL=F")}
    w = dict(WATCHLIST)
    if FUTURES_TOP_N:
        try:
            for s in okx_top_swaps(FUTURES_TOP_N, FUTURES_EXCLUDE):
                w[s] = "crypto"
        except Exception as e:
            print("futures list error", e)
    return w

def load_rows(sym, tf, period):
    provider = os.getenv("MARKET_DATA_PROVIDER", "yahoo").strip().lower()
    if provider == "yahoo" and sym.endswith("-USDT"):   # existing OKX crypto-futures route
        df = okx_ohlc(sym, tf)
    else:
        df = get_provider_ohlc(sym, tf, period)
    if len(df) < (210 if tf == "1d" else 250):
        return None
    return list((build(df) if tf == "1h" else add_indicators(df)).itertuples())

def card(s):
    side = "BUY" if s["side"] == 1 else "SELL"
    tag = "" if s.get("grade", "proven") == "proven" else " ⚠️ experimental"
    return (f"<b>{html.escape(s['strategy'])}</b> {side} ({s['tf']}, {s['style']}){tag}\n"
            f"  {fmt(s['entry'])} | SL {fmt(s['sl'])} | TP {fmt(s['tp'])}\n  {html.escape(s['why'])}")

def htf_trend(R4):
    """+1 / -1 when the 4h trend is clear, else 0."""
    if not R4 or len(R4) < 3:
        return 0
    r = R4[-2]
    if r.ema50 > r.ema200 and r.close > r.ema50:
        return 1
    if r.ema50 < r.ema200 and r.close < r.ema50:
        return -1
    return 0

def message(sym, sigs, sentiment, top, fnotes, micro, extra=""):
    buys, sells = [s for s in sigs if s["side"] == 1], [s for s in sigs if s["side"] == -1]
    lead, side = (buys, "BUY") if len(buys) >= len(sells) else (sells, "SELL")
    other = sells if side == "BUY" else buys
    n = len(lead)
    out = [f"{'🟢' if side == 'BUY' else '🔴'} <b>{side} {sym}</b>  {'⭐' * min(n, 5)} {n} strateg{'y' if n == 1 else 'ies'} agree\n"]
    out += [card(s) for s in lead]
    if other:
        out += ["\n⚠️ <b>Opposing signals</b>"] + [card(s) for s in other]
    mood = "bullish" if sentiment >= 1 else "bearish" if sentiment <= -1 else "neutral"
    out.append(f"\nNews mood: {mood}" + (f"\n📰 {html.escape(top)}" if top else ""))
    if fnotes:
        out += ["\n📈 <b>Order flow</b>"] + ["• " + x for x in fnotes]
    if extra:
        out.append(extra)
    if micro:
        out.append(f"Order book: depth imbalance {micro['imbalance']:+.2f}, spread {micro['spread_bps']:.1f} bps")
    if n >= 3:
        out.append("\nOptions idea: " + ("bull call spread or long call" if side == "BUY" else "bear put spread or long put") + ", defined risk only.")
    out.append("\n<i>Analysis only, not financial advice. Risk 1% or less per trade.</i>")
    return "\n".join(out)

def scan():
    sent, ps, fd = load_sent(), paper.load(), feed.load()
    events, items = news.calendar(), news.headlines()
    now = pd.Timestamp.now(tz="UTC")
    rows, found, mood = {}, {}, {}
    watch = full_watchlist()
    fg = news.fear_greed()

    def add(sym, name, tf, R, s, max_age, hold, style, extra=""):
        if not s:
            return
        r = R[-2]
        closed = special.utc(r.Index) + pd.Timedelta(minutes=BAR_MIN[tf])
        key = f"{name}|{sym}|{r.Index}{extra}"
        if (now - closed).total_seconds() / 60 > max_age or key in sent:
            return
        live = float(R[-1].close)  # latest price; strategy levels were calculated from the signal candle close
        side = int(s["side"])
        risk = abs(float(r.close) - float(s["sl"]))
        reward = abs(float(s["tp"]) - float(r.close))
        if risk <= 0 or reward <= 0:
            return
        move = (live - float(r.close)) * side  # + = price already ran our way, - = against
        if move > 0.5 * risk or move < -0.5 * risk:  # chased or already failing: stale signal
            return
        # Re-anchor SL/TP to the actual intended entry while preserving the strategy's
        # original price-risk and reward distances. This keeps paper-trade R consistent.
        live_sl = live - side * risk
        live_tp = live + side * reward
        if (live_tp - live) * side < 1.2 * abs(live - live_sl):
            return
        found.setdefault(sym, []).append({**s, "strategy": name, "tf": tf, "entry": live,
                                          "sl": float(live_sl), "tp": float(live_tp), "key": key,
                                          "hold_h": hold, "style": style,
                                          "grade": "proven" if name in PROVEN and sym in WATCHLIST else "experimental"})

    for sym, asset in watch.items():
        rows[sym] = {}
        for tf in (INTERVAL if sym in WATCHLIST else FUTURES_TIMEFRAMES):
            try:
                R = load_rows(sym, tf, LIVE_PERIOD[tf])
                R and rows[sym].__setitem__(tf, R)
            except Exception as e:
                print(sym, tf, "data error", e)
        mood[sym] = news.symbol_sentiment(sym, items)
        for name, tf, fn, max_age, hold, style in REGISTRY:
            R = rows[sym].get(tf)
            if not R or (ENABLED_STRATEGIES and name not in ENABLED_STRATEGIES):
                continue
            try:
                add(sym, name, tf, R, fn(R, len(R) - 2), max_age, hold, style)
            except Exception as e:
                print(sym, name, "error", e)
        try:
            if rows[sym].get("1h"):
                R = rows[sym]["1h"]
                add(sym, "News", "1h", R, special.news_trade(R, len(R) - 2, mood[sym][0]), 120, 24, "hours")
            if rows[sym].get("15m"):
                R = rows[sym]["15m"]
                s = special.event_driven(R, len(R) - 2, events, sym)
                s and add(sym, "Event-driven", "15m", R, s, 60, 12, "hours", s["event_key"])
        except Exception as e:
            print(sym, "news/event error", e)

    daily = {s: r["1d"] for s, r in rows.items() if "1d" in r and s in WATCHLIST}
    wk = now.isocalendar()
    for sym, s, r in special.momentum_rank(daily):
        key = f"Momentum|{sym}|{wk.year}-{wk.week}|{s['side']}"
        if key not in sent:
            found.setdefault(sym, []).append({**s, "strategy": "Momentum", "tf": "1d", "entry": float(r.close), "key": key,
                                              "hold_h": 720, "style": "weeks", "grade": "experimental"})

    paper.update(ps, rows)
    for sym, sigs in found.items():
        asset = watch[sym]
        ev = news.near_high_impact(sym, events, NEWS_BLACKOUT_MIN)
        sc, top = mood[sym]
        keep = []
        for s in sigs:
            sent.add(s["key"])
            if ev and s["strategy"] != "Event-driven":
                continue
            if asset == "forex" and s["strategy"] in INTRADAY_FX and not FOREX_SESSION[0] <= now.hour < FOREX_SESSION[1]:
                continue
            if NEWS_FILTER and s["strategy"] != "News" and ((s["side"] == 1 and sc <= -2) or (s["side"] == -1 and sc >= 2)):
                continue
            if HTF_FILTER and s["tf"] in ("5m", "15m", "30m", "1h") and not s["strategy"].startswith(HTF_EXEMPT):
                t4 = htf_trend(rows[sym].get("4h"))
                if t4 and t4 != s["side"]:
                    continue                           # fighting the 4h trend
            keep.append(s)
        flow_notes, f = {}, (flow_live.live_flow(sym) if asset == "crypto" else None)
        if f:
            for side in (1, -1):
                ok, notes = flow_live.verdict("BUY" if side == 1 else "SELL", f)
                if FLOW_FILTER and not ok:
                    keep = [s for s in keep if s["side"] != side]
                else:
                    flow_notes[side] = notes
        nb, ns = sum(s["side"] == 1 for s in keep), sum(s["side"] == -1 for s in keep)
        if nb == ns:                                    # equal BUY and SELL (or none): no edge, stay out
            continue
        fnotes = flow_notes.get(1 if nb > ns else -1, [])
        extra = f"Fear & Greed: {fg[0]} ({fg[1]})" if fg and asset == "crypto" else ""
        telegram.send(message(sym, keep, sc, top, fnotes, special.order_book(sym) if asset == "crypto" else None, extra))
        feed.add(fd, sym, keep)
        for s in keep:
            R = rows[sym].get(s["tf"])
            r = R[-2] if R and len(R) > 2 else None
            num = lambda v: None if v is None or v != v else round(float(v), 3)
            ctx = {"asset": asset, "agree": sum(x["side"] == s["side"] for x in keep), "mood": sc,
                   "htf": htf_trend(rows[sym].get("4h")), "hour": now.hour, "weekday": now.weekday()}
            if r is not None:
                try:
                    ctx.update({"adx": num(getattr(r, "adx", None)), "rsi": num(getattr(r, "rsi", None)),
                                "atr_pct": num(r.atr / r.close * 100)})
                except Exception:
                    pass
            paper.open_pos(ps, sym, {**s, "ctx": ctx})

    for a, b in PAIRS:
        try:
            ra, rb = rows[a].get("1h"), rows[b].get("1h")
            if not (ra and rb):
                continue
            ser = lambda R: pd.Series([x.close for x in R], index=[x.Index for x in R])
            p = special.pair_signal(a, b, ser(ra), ser(rb))
            key = f"Pairs|{a}/{b}|{p and (p['z'] > 0)}|{now:%Y%m%d}"
            if p and key not in sent:
                sent.add(key)
                telegram.send(f"🔀 <b>Pairs trade {p['pair']}</b>\n{p['text']}\n\n<i>Market-neutral idea. Size both legs equally in risk. Not financial advice.</i>")
        except Exception as e:
            print("pairs error", e)

    for sym, asset in watch.items():
        a = special.arbitrage(sym) if asset == "crypto" else None
        key = a and f"Arb|{sym}|{a['buy']}|{a['sell']}|{now:%Y%m%d%H}"
        if a and a["hit"] and key not in sent:
            sent.add(key)
            telegram.send(f"⚖️ <b>Arbitrage {sym}</b>: buy {a['buy']}, sell {a['sell']}, spread {a['spread']:.2f}%\n"
                          + ", ".join(f"{k} {v:,.2f}" for k, v in a["prices"].items())
                          + "\n<i>Check withdrawal time, fees and USD vs USDT premium before acting. Alert only.</i>")

    for c in special.copy_signals():
        key = "Copy|" + json.dumps(c, sort_keys=True)
        if key in sent:
            continue
        sent.add(key)
        side = 1 if str(c.get("side", "")).upper() == "BUY" else -1
        telegram.send(f"👥 <b>Copy trade from {html.escape(str(c.get('trader', 'source')))}</b>\n{'BUY' if side == 1 else 'SELL'} {c.get('symbol')} "
                      f"entry {c.get('entry')} SL {c.get('sl')} TP {c.get('tp')}")
        try:
            paper.open_pos(ps, c["symbol"], {"strategy": f"Copy:{c.get('trader', 'source')}", "side": side, "entry": float(c["entry"]),
                                             "sl": float(c["sl"]), "tp": float(c["tp"]), "hold_h": 168})
        except Exception:
            pass

    soon = []
    for e in events:
        try:
            t = special.utc(pd.Timestamp(e["date"]))
            key = f"Heads|{e['title']}|{e['date']}"
            if pd.Timedelta(0) < t - now <= pd.Timedelta(minutes=60) and key not in sent:
                sent.add(key)
                soon.append(f"• {t:%H:%M} UTC {e['country']} {e['title']}")
        except Exception:
            pass
    soon and telegram.send("⚠️ <b>High-impact news within 1 hour</b>\n" + "\n".join(soon) + "\nSignals on affected pairs are paused around the release.")

    json.dump({"sent": sorted(sent)[-3000:]}, open(STATE, "w"))
    paper.save(ps)
    fd["paper"] = paper.summary(ps)
    feed.save(fd)

def report():
    events, items = news.calendar(), news.headlines()
    lines = ["📊 <b>Daily market report</b>\n"]
    for sym, asset in WATCHLIST.items():
        try:
            R = load_rows(sym, "1h", LIVE_PERIOD["1h"])
            r = R[-2]
            tr = {1: "uptrend", -1: "downtrend", 0: "sideways"}[int(r.trend)]
            sc, _ = news.symbol_sentiment(sym, items)
            lf = (flow_live.live_flow(sym) or {}) if asset == "crypto" else {}
            fl = f" | buyers {lf['taker_buy_pct']:.0f}%" if "taker_buy_pct" in lf else ""
            lines.append(f"<b>{sym}</b> {fmt(r.close)} ({(r.close / R[-26].close - 1) * 100:+.1f}% 24h) | 4H {tr} | RSI {r.rsi:.0f} | ADX {r.adx:.0f} | news {sc:+.1f}{fl}")
        except Exception as e:
            print(sym, "error", e)
    ev = news.today_events(events)
    ev and lines.extend(["\n⚠️ <b>High-impact events today</b>"] + ["• " + e for e in ev])
    opt = [special.options_sentiment(c) for c in ("BTC", "ETH")] + [special.options_equity(t) for t in OPTIONS_EQUITY]
    opt = [o["text"] for o in opt if o]
    opt and lines.extend(["\n🧮 <b>Options</b>"] + ["• " + o for o in opt])
    arb = [special.arbitrage(s) for s, a in WATCHLIST.items() if a == "crypto"]
    arb = [f"• {a['symbol']}: {a['spread']:.2f}% ({a['buy']} → {a['sell']})" for a in arb if a]
    arb and lines.extend(["\n⚖️ <b>Exchange spreads</b>"] + arb)
    lines += ["", paper.report(paper.load())]
    top = "\n".join("- " + i["title"] for i in items[:15])
    summary = ai.summarize("Summarize the key market-moving themes from these headlines for crypto and forex traders in 5 short bullets. Be neutral.\n\n" + top)
    lines += ["\n🧠 <b>AI summary</b>\n" + html.escape(summary)] if summary else ["\n📰 <b>Headlines</b>"] + ["• " + html.escape(i["title"]) for i in items[:6]]
    text = "\n".join(lines)
    telegram.send(text)
    fd = feed.load()
    fd["report"], fd["paper"] = html.unescape(re.sub(r"<[^>]+>", "", text)), paper.summary(paper.load())
    feed.save(fd)

if __name__ == "__main__":
    {"scan": scan, "report": report, "invest": lambda: telegram.send(fundamentals.report())}[sys.argv[1] if len(sys.argv) > 1 else "scan"]()
