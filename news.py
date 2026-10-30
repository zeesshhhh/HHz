import datetime as dt
import feedparser
import requests
from config import NEWS_KEYWORDS, MACRO_WORDS, CURRENCIES

FEEDS = ["https://www.coindesk.com/arc/outboundfeeds/rss/", "https://cointelegraph.com/rss",
         "https://www.fxstreet.com/rss/news", "https://www.forexlive.com/feed/news", "https://decrypt.co/feed",
         "https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=10000664",
         "https://feeds.bbci.co.uk/news/business/rss.xml"]
CALENDAR = "https://nfs.faireconomy.media/ff_calendar_thisweek.json"
BULL = ["surge", "rally", "soar", "approve", "inflow", "adoption", "rate cut", "beats", "record high", "gains", "bullish", "jumps"]
BEAR = ["crash", "plunge", "hack", "ban", "lawsuit", "sues", "rate hike", "liquidat", "fears", "selloff", "bearish", "slump", "drops"]

def headlines(limit=40):
    out = []
    for url in FEEDS:
        try:
            for e in feedparser.parse(url).entries[:15]:
                out.append({"title": e.get("title", ""), "link": e.get("link", "")})
        except Exception:
            pass
    return out[:limit * 2]

def score_title(t):
    t = t.lower()
    return sum(w in t for w in BULL) - sum(w in t for w in BEAR)

def symbol_sentiment(symbol, items):
    keys = NEWS_KEYWORDS.get(symbol, [])
    rel = [i for i in items if any(k in i["title"].lower() for k in keys)]
    macro = [i for i in items if any(k in i["title"].lower() for k in MACRO_WORDS)]
    total = sum(score_title(i["title"]) for i in rel) + 0.5 * sum(score_title(i["title"]) for i in macro)
    top = (rel or macro or [{"title": ""}])[0]["title"]
    return total, top

def calendar():
    try:
        r = requests.get(CALENDAR, timeout=15, headers={"User-Agent": "Mozilla/5.0"})
        ev = r.json()
        return [e for e in ev if e.get("impact") == "High"]
    except Exception:
        return []

def _when(e):
    return dt.datetime.fromisoformat(e["date"]).astimezone(dt.timezone.utc)

def near_high_impact(symbol, events, minutes):
    now = dt.datetime.now(dt.timezone.utc)
    cur = CURRENCIES.get(symbol, ["USD"])
    for e in events:
        try:
            if e["country"] in cur and abs((_when(e) - now).total_seconds()) <= minutes * 60:
                return e["title"]
        except Exception:
            pass
    return None

def today_events(events):
    now = dt.datetime.now(dt.timezone.utc)
    out = []
    for e in events:
        try:
            w = _when(e)
            if w.date() == now.date():
                out.append(f"{w:%H:%M} UTC {e['country']} {e['title']}")
        except Exception:
            pass
    return out

def fear_greed():
    """Crypto Fear & Greed index: (value, label) or None."""
    try:
        d = requests.get("https://api.alternative.me/fng/?limit=1", timeout=10).json()["data"][0]
        return int(d["value"]), d["value_classification"]
    except Exception:
        return None
