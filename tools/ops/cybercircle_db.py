#!/usr/bin/env python3
"""Cyber Circle database (SQLite): create it, import questions, add players.
Python standard library only. The game opens the same file itself (godot-sqlite).

The external app and the game share this database:
  * the app puts a player in `players`, then publishes on MQTT
      cybercircle/cmd  {"assign": <player id>, "tile": 3}      ("tile" optional)
    the game looks the player up here (name, colour, age) and lights the tile;
  * questions are managed in `questions` (edit them with any SQLite tool);
  * the game writes every round's points and the end result of every player
    (also exterminated players) to `games`, `round_scores` and `results`.

Usage:
  python3 tools/ops/cybercircle_db.py init  [--db FILE] [--questions FILE] [--demo-players]
  python3 tools/ops/cybercircle_db.py add-player NAME COLOR [AGE] [--db FILE]
      (what the external app does: prints the id and the MQTT message to send)
"""
import argparse, json, os, sqlite3, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DB = os.path.join(HERE, "..", "..", "game", "data", "cybercircle.db")
DEFAULT_QUESTIONS = os.path.join(HERE, "..", "..", "game", "data", "questions.json")
SCHEMA_FILE = os.path.join(HERE, "..", "..", "game", "data", "schema.sql")


def connect(path):
    db = sqlite3.connect(path, check_same_thread=False)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")
    with open(SCHEMA_FILE, encoding="utf-8") as f:
        db.executescript(f.read())
    return db


def import_questions(db, path):
    with open(path, encoding="utf-8") as f:
        questions = json.load(f)
    for q in questions:
        a = q["answers"]
        db.execute(
            "INSERT INTO questions (slug, category, min_age, max_age, question, text, answer1, answer2,"
            " answer3, answer4, correct, explanation, video, video_when, time)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
            " ON CONFLICT(slug) DO UPDATE SET category=excluded.category, min_age=excluded.min_age,"
            " max_age=excluded.max_age, question=excluded.question, text=excluded.text,"
            " answer1=excluded.answer1, answer2=excluded.answer2, answer3=excluded.answer3,"
            " answer4=excluded.answer4, correct=excluded.correct, explanation=excluded.explanation,"
            " video=excluded.video, video_when=excluded.video_when, time=excluded.time",
            (q.get("id") or q["question"][:40], q.get("category", ""), q.get("min_age", 0),
             q.get("max_age", 99), q["question"], q.get("text", ""), a[0], a[1], a[2], a[3],
             q["correct"], q.get("explanation", ""), q.get("video", ""),
             q.get("video_when", "before"), q.get("time", 0)))
    db.commit()
    return len(questions)


def add_player(db, name, color="#ffcc00", age=0):
    cur = db.execute("INSERT INTO players (name, color, age) VALUES (?,?,?)", (name, color, int(age)))
    db.commit()
    return cur.lastrowid


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["init", "add-player"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--questions", default=DEFAULT_QUESTIONS)
    ap.add_argument("--demo-players", action="store_true")
    a = ap.parse_args()
    db = connect(a.db)
    if a.command == "init":
        n = import_questions(db, a.questions)
        print("%s: %d questions imported" % (os.path.normpath(a.db), n))
        if a.demo_players:
            for p in [("Anna", "#ff3399", 12), ("Bram", "#33ccff", 7), ("Cleo", "#66ff66", 9),
                      ("Daan", "#ff8800", 13)]:
                print("player %d: %s" % (add_player(db, *p), p[0]))
    else:
        if len(a.args) < 2:
            sys.exit("add-player NAME COLOR [AGE]")
        pid = add_player(db, a.args[0], a.args[1], a.args[2] if len(a.args) > 2 else 0)
        print("player id %d - now publish on MQTT:  cybercircle/cmd  {\"assign\": %d}" % (pid, pid))


if __name__ == "__main__":
    main()
