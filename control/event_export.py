"""One event as a zip (marketing, a backup that outlives the database):
  event.json     the event: name, from - to, games, players, plays, best
  players.csv    who played at it: name, age, email, QR card, first seen
  results.csv    every play: player, rounds survived, lives left, exterminated, rank
  games.csv      the games: start, end
  rounds.csv     every round of every play: type, points, rounds survived so far, lives
CSV with ';' and a UTF-8 BOM: opens as columns in Excel (Belgian / Dutch settings) too.
"""
import csv
import io
import json
import os
import re
import zipfile

COLUMNS = {
    "players": ["id", "name", "age", "email", "card", "color", "created_at"],
    "results": ["id", "game_id", "player_id", "name", "tile", "score", "lives", "exterminated", "rank", "created_at"],
    "games": ["id", "started_at", "ended_at"],
    "rounds": ["id", "game_id", "round", "round_type", "player_id", "tile", "points", "score", "lives", "created_at"],
}


def _csv(rows, columns):
    out = io.StringIO()
    out.write("﻿")
    w = csv.writer(out, delimiter=";", lineterminator="\r\n")
    w.writerow(columns)
    for r in rows:
        w.writerow(["" if r.get(c) is None else r.get(c) for c in columns])
    return out.getvalue().encode("utf-8")


def file_name(event):
    """cybercircle-event-<id>-<name>-<first day>.zip"""
    slug = re.sub(r"[^a-z0-9]+", "-", str(event.get("name", "")).lower()).strip("-")[:40] or "event"
    day = str(event.get("started_at", ""))[:10]
    return "cybercircle-event-%d-%s-%s.zip" % (event["id"], slug, day)


def event_zip(data):
    """data: Database.export_event(id). Returns the zip's bytes."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("event.json", json.dumps(data["event"], indent=2, ensure_ascii=False, default=str))
        for name, columns in COLUMNS.items():
            z.writestr(name + ".csv", _csv(data[name], columns))
    return buf.getvalue()


def save(data, folder):
    """The zip in folder (made when missing); returns its path."""
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, file_name(data["event"]))
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(event_zip(data))
    os.replace(tmp, path)
    return path
