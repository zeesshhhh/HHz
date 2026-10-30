import requests
from config import TELEGRAM_TOKEN, TELEGRAM_CHAT_ID

def send(text):
    if not (TELEGRAM_TOKEN and TELEGRAM_CHAT_ID):
        print(text)
        return
    for i in range(0, len(text), 4000):
        requests.post(f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage", timeout=20,
                      json={"chat_id": TELEGRAM_CHAT_ID, "text": text[i:i + 4000],
                            "parse_mode": "HTML", "disable_web_page_preview": True})
