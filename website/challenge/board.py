"""The scoreboard's bars: per player their rounds survived next to the best's,
and how far everyone got at an event (how many players reached 0, 1, 2 ...
rounds as their best) - plain HTML / CSS, no script."""
import datetime
import math

DAY_NAMES = ["ma", "di", "wo", "do", "vr", "za", "zo"]
MAX_COLUMNS = 24                       # the chart's bars at most (more rounds: in groups)


def with_bars(scores, event=None):
    """The rows with .bar: their best in % of the event's best (the top's: 100; at least 2 when > 0)."""
    rows = list(scores)
    top = max((r.best for r in rows), default=0)
    if event is not None:                  # (a part, the top 10: against the event's best)
        top = max(top, event.scores.order_by("-best").values_list("best", flat=True).first() or 0)
    for r in rows:
        r.bar = 0 if top <= 0 or r.best <= 0 else max(2, round(r.best * 100 / top))
    return rows


def histogram(rows, mine=None):
    """How far everyone got: [{label (its lowest), range ("10–11"), size, count, height (% of the
    tallest), mine}] per number of rounds (0, 1, 2 ...), in groups of `size` when the best got far
    (MAX_COLUMNS bars at most)."""
    if not rows:
        return []
    top = max(r.best for r in rows)
    size = max(1, math.ceil((top + 1) / MAX_COLUMNS))
    counts = [0] * (top // size + 1)
    for r in rows:
        counts[r.best // size] += 1
    tallest = max(counts)
    out = []
    for i, n in enumerate(counts):
        lo, hi = i * size, min(i * size + size - 1, top)
        out.append({"label": str(lo), "range": str(lo) if lo == hi else f"{lo}–{hi}", "size": size, "count": n,
                    "height": round(n * 100 / tallest) if n else 0,
                    "mine": bool(mine and lo <= mine.best <= hi)})
    return out


def event_numbers(rows):
    """{players, plays, best} of an event's scoreboard."""
    return {"players": len(rows), "plays": sum(r.plays for r in rows), "best": max((r.best for r in rows), default=0)}


def event_days(event):
    """The event's days as text: [{label: "za 21/11", hours: "10:00–18:00", today}]."""
    today = datetime.date.today()
    out = []
    for d in event.days or []:
        try:
            date = datetime.date.fromisoformat(d["date"])
        except (KeyError, TypeError, ValueError):
            continue
        out.append({"label": f"{DAY_NAMES[date.weekday()]} {date.day}/{date.month}",
                    "hours": f"{d.get('start', '')}–{d.get('end', '')}", "today": date == today})
    return out
