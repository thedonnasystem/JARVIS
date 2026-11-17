"""Example auto-ship-zone skill: counts words in payload["text"]. Loaded only through hq_skills (restricted loader)."""
import re


def run(payload):
    words = re.findall(r"\w+", str(payload.get("text", "")))
    return {"words": len(words)}
