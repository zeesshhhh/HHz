import requests
from config import ANTHROPIC_API_KEY, CLAUDE_MODEL

def summarize(prompt):
    if not ANTHROPIC_API_KEY:
        return ""
    try:
        r = requests.post("https://api.anthropic.com/v1/messages", timeout=60,
            headers={"x-api-key": ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json"},
            json={"model": CLAUDE_MODEL, "max_tokens": 500,
                  "messages": [{"role": "user", "content": prompt}]})
        return r.json()["content"][0]["text"]
    except Exception:
        return ""
