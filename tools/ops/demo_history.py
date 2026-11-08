#!/usr/bin/env python3
"""Earlier visitors for a demo database: N players who played earlier at this
event (an event lasts 1-2 days: yesterday and today, opening hours 10-18,
always before now), in groups (games) of 4-13, so the overall ranking looks
like an event under way (the movies: a new visitor ranks somewhere among
them, not #1 of an empty list).

Rounds survived (the ranking) mostly 1-6, a few long runs up to 20; most
players end exterminated, some were still in when the game closed (their
lives left, a rank in that game). About 1 in 6 came back (2-3 plays).
Deterministic (--seed). Writes straight into the control server's database
(control/db.py): a SQLite file or a SQLAlchemy URL - run it before the server.

    control/.venv/bin/python tools/ops/demo_history.py --db game.db [--players 300] [--days 2] [--seed 7]
"""
import argparse, datetime, os, random, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "control"))
from sqlalchemy import insert                                       # noqa: E402
import db as dbm                                                    # noqa: E402

NAMES = ["Lotte", "Noah", "Emma", "Liam", "Olivia", "Louis", "Mila", "Arthur", "Lina", "Jules", "Nora", "Lucas",
         "Ella", "Adam", "Marie", "Victor", "Lou", "Finn", "Fleur", "Mats", "Elise", "Vic", "Julie", "Seppe", "Hanne",
         "Wout", "Febe", "Lars", "Amber", "Warre", "Ines", "Kobe", "Saar", "Jasper", "Lore", "Mathis", "Roos", "Thor",
         "Yasmine", "Rayan", "Amira", "Youssef", "Sofia", "Milan", "Lena", "Robbe", "Zoë", "Tuur", "Nina", "Stan",
         "Eline", "Bas", "Lien", "Daan", "Tess", "Ruben", "Jana", "Siebe", "Axelle", "Matteo", "Aya", "Ibrahim", "Kato",
         "Brent", "Margot", "Cas", "Jill", "Rune", "Fien", "Wannes", "Mona", "Tibo", "Silke", "Lowie", "Bo", "Arne",
         "Anouk", "Nathan", "Esra", "Senne"]
COLORS = ["#ff8800", "#00ccff", "#ff00aa", "#88ff00", "#ffee00", "#aa55ff", "#00ffcc", "#ff4444", "#4488ff",
          "#ff66cc", "#66ff99", "#ffaa33"]


def rounds_survived(rng):
    """Mostly 1-6, a long tail (a strong group, a good day) up to 20."""
    return min(1 + int(rng.expovariate(1 / 3.2)), 20)


OPEN, CLOSE = 10, 18                 # the event's opening hours
ROUND_TYPES = ["quiz", "quiz", "cyclone", "rhythm", "simon", "reaction", "zwarte_piet", "code"]


def _db_now(d):
    """Now on the database's clock, in its own time zone (what its now() writes), so
    the history lines up with what the server records; the opening hours stay local
    (shifted by the same whole hours)."""
    local = datetime.datetime.now().replace(microsecond=0)
    with d.engine.connect() as con:
        db_now = con.execute(dbm.select(dbm.func.now())).scalar()
    if isinstance(db_now, str):
        db_now = datetime.datetime.fromisoformat(db_now)
    shift = datetime.timedelta(hours=round((db_now - local).total_seconds() / 3600))
    return local + shift, shift


def _when(rng, now, days):
    """A moment during the event's opening hours, on one of its days (today
    included), before now."""
    for _ in range(100):
        day = (now - datetime.timedelta(days=rng.randrange(days))).replace(hour=OPEN, minute=0, second=0)
        t = day + datetime.timedelta(seconds=int(rng.uniform(0, (CLOSE - OPEN) * 3600 - 1800)))
        if t < now - datetime.timedelta(minutes=30):
            return t
    return now - datetime.timedelta(days=days - 1, hours=2)          # (early in the morning of day 1)


def seed(db_path, players=300, seed_value=7, days=2, event=""):
    rng = random.Random(seed_value)
    d = dbm.Database(db_path)
    now, shift = _db_now(d)                         # (the database's clock: SQLite UTC, MySQL local)
    now -= shift                                    # (the opening hours: local time; written + shift)
    eid = d.current_event_id()                      # (the history: the current event's)
    first_day = (now - datetime.timedelta(days=days - 1)).replace(hour=OPEN, minute=0, second=0)
    with d.engine.begin() as con:                   # it started on the event's first morning
        values = {"started_at": first_day + shift, **({"name": event} if event else {})}
        con.execute(dbm.update(dbm.events).where(dbm.events.c.id == eid).values(**values))
    people = []
    with d.engine.begin() as con:
        for n in range(players):
            name = rng.choice(NAMES)
            pid = con.execute(insert(dbm.players).values(name=name, color=rng.choice(COLORS), age=rng.randint(8, 15),
                                                         card="CC-H%04d" % (n + 1))).inserted_primary_key[0]
            plays = 1 if rng.random() > 1 / 6 else rng.choice([2, 2, 3])
            people += [(pid, name)] * plays
    rng.shuffle(people)
    games = results = 0
    with d.engine.begin() as con:
        while people:
            size = min(rng.randint(4, 13), len(people))
            group, people = people[:size], people[size:]
            if len({p for p, _ in group}) < len(group):           # (one person twice in a game: the next game)
                seen, keep, later = set(), [], []
                for p in group:
                    (later if p[0] in seen else keep).append(p)
                    seen.add(p[0])
                group, people = keep, people + later
            start = _when(rng, now, days)
            gid = con.execute(insert(dbm.games).values(started_at=start + shift, event_id=eid,
                                                       ended_at=start + shift + datetime.timedelta(minutes=rng.randint(6, 25)))
                              ).inserted_primary_key[0]
            games += 1
            rows, rounds = [], []
            for tile, (pid, name) in enumerate(group, 1):
                score = rounds_survived(rng)
                out = rng.random() < 0.85                          # most end exterminated
                lives = 0 if out else rng.randint(1, 5)
                rows.append({"game_id": gid, "player_id": pid, "tile": tile, "name": name, "score": score,
                             "lives": lives, "exterminated": int(out), "rank": None,
                             "created_at": start + shift + datetime.timedelta(minutes=2 + score)})
                left = 3                                           # the play, round by round (the points: a tie-break)
                for n in range(1, score + 1 + int(out)):
                    left = max(min(left + rng.choice([-1, 0, 0, 1]), 5), 1) if n <= score else 0
                    rounds.append({"game_id": gid, "round": n, "round_type": rng.choice(ROUND_TYPES), "player_id": pid,
                                   "tile": tile, "points": rng.randint(0, 12), "score": min(n, score),
                                   "lives": left if n < score or out else lives,
                                   "created_at": start + shift + datetime.timedelta(minutes=1 + n)})
            still_in = sorted((r for r in rows if not r["exterminated"]), key=lambda r: (-r["score"], -r["lives"]))
            for i, r in enumerate(still_in, 1):
                r["rank"] = i
            con.execute(insert(dbm.results), rows)
            if rounds:
                con.execute(insert(dbm.round_scores), rounds)
            results += len(rows)
    return games, results


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", required=True, help="the control server's database: a SQLite file or a SQLAlchemy URL")
    ap.add_argument("--players", type=int, default=300)
    ap.add_argument("--days", type=int, default=2, help="the event so far: 1 (today) or 2 (yesterday and today)")
    ap.add_argument("--event", default="", help="the current event's name (default: as it is)")
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    games, results = seed(a.db, a.players, a.seed, a.days, a.event)
    print("demo history: %d players, %d games, %d results" % (a.players, games, results))


if __name__ == "__main__":
    main()
