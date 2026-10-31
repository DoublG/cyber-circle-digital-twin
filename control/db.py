"""The Cyber Circle database. The control server is its only owner: the game
master, the app and the web interface all go through the control server's
HTTP API. Schema: ../godot/data/schema.sql (shared with the game's standalone
mode and tools/cybercircle_db.py)."""

import json
import os
import sqlite3
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA = os.path.join(HERE, "..", "godot", "data", "schema.sql")
QUESTION_FIELDS = ("slug", "category", "min_age", "max_age", "question", "text", "answer1", "answer2",
                   "answer3", "answer4", "correct", "explanation", "video", "video_when", "image", "time", "active")


class Database:
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()          # one connection, requests come from a thread pool
        self.con = sqlite3.connect(path, check_same_thread=False)
        self.con.row_factory = sqlite3.Row
        self.con.execute("PRAGMA journal_mode = WAL")
        self.con.execute("PRAGMA foreign_keys = ON")
        with open(SCHEMA, encoding="utf-8") as f:
            self.con.executescript(f.read())
        cols = {r["name"] for r in self.con.execute("PRAGMA table_info(questions)")}
        if "image" not in cols:                  # databases from before the picture column
            self.con.execute("ALTER TABLE questions ADD COLUMN image TEXT NOT NULL DEFAULT ''")
            self.con.commit()

    def _all(self, sql, args=()):
        with self.lock:
            return [dict(r) for r in self.con.execute(sql, args)]

    def _one(self, sql, args=()):
        rows = self._all(sql, args)
        return rows[0] if rows else None

    def _write(self, sql, args=()):
        with self.lock:
            cur = self.con.execute(sql, args)
            self.con.commit()
            return cur.lastrowid

    # ------------------------------------------------------------ settings

    def setting(self, key, default=None):
        row = self._one("SELECT value FROM settings WHERE key = ?", (key,))
        return row["value"] if row else default

    def set_setting(self, key, value):
        self._write("INSERT INTO settings (key, value) VALUES (?, ?)"
                    " ON CONFLICT(key) DO UPDATE SET value = excluded.value", (key, str(value)))

    # ------------------------------------------------------------ tiles (places around the robot)

    def tiles(self):
        """The 13 places: which physical tile (device id) stands there, in service or not."""
        with self.lock:
            self.con.executemany("INSERT OR IGNORE INTO tiles (number) VALUES (?)", [(n,) for n in range(1, 14)])
            self.con.commit()
        return self._all("SELECT number, device, enabled FROM tiles ORDER BY number")

    def set_tile(self, number, device=..., enabled=None):
        """device: a device id, None (no device) or ... (unchanged)."""
        self.tiles()
        with self.lock:
            if device is not ...:
                if device:                       # a device stands on one place only
                    self.con.execute("UPDATE tiles SET device = NULL WHERE device = ?", (device,))
                self.con.execute("UPDATE tiles SET device = ? WHERE number = ?", (device or None, number))
            if enabled is not None:
                self.con.execute("UPDATE tiles SET enabled = ? WHERE number = ?", (int(bool(enabled)), number))
            self.con.commit()

    # ------------------------------------------------------------ players

    def add_player(self, name, color="#ffcc00", age=0):
        return self._write("INSERT INTO players (name, color, age) VALUES (?,?,?)", (name, color, int(age)))

    def player(self, pid):
        return self._one("SELECT id, name, color, age FROM players WHERE id = ?", (pid,))

    def players(self, search="", limit=50):
        return self._all(
            "SELECT p.id, p.name, p.color, p.age, MAX(r.score) AS best, COUNT(r.id) AS plays"
            " FROM players p LEFT JOIN results r ON r.player_id = p.id"
            " WHERE p.name LIKE ? GROUP BY p.id ORDER BY p.id DESC LIMIT ?", (f"%{search}%", limit))

    # ------------------------------------------------------------ questions

    @staticmethod
    def question_json(r):
        """A questions row in the format the game's QuizRound uses."""
        q = {"id": r["slug"] or str(r["id"]), "category": r["category"], "min_age": r["min_age"],
             "max_age": r["max_age"], "question": r["question"],
             "answers": [r["answer1"], r["answer2"], r["answer3"], r["answer4"]], "correct": r["correct"]}
        for key in ("text", "explanation", "video", "image"):
            if r[key]:
                q[key] = r[key]
        if r["video"]:
            q["video_when"] = r["video_when"]
        if r["time"]:
            q["time"] = r["time"]
        return q

    def questions(self):
        return [self.question_json(r) for r in self._all("SELECT * FROM questions WHERE active = 1 ORDER BY id")]

    def question_rows(self):
        return self._all("SELECT * FROM questions ORDER BY id")

    def save_question(self, q, qid=None):
        values = [q.get(f) for f in QUESTION_FIELDS]
        if qid is None:
            cols = ", ".join(QUESTION_FIELDS)
            return self._write(f"INSERT INTO questions ({cols}) VALUES ({','.join('?' * len(values))})", values)
        sets = ", ".join(f"{f} = ?" for f in QUESTION_FIELDS)
        self._write(f"UPDATE questions SET {sets} WHERE id = ?", values + [qid])
        return qid

    def delete_question(self, qid):
        self._write("DELETE FROM questions WHERE id = ?", (qid,))

    # ------------------------------------------------------------ games and scores

    def start_game(self):
        return self._write("INSERT INTO games DEFAULT VALUES")

    def end_game(self, game_id):
        self._write("UPDATE games SET ended_at = datetime('now') WHERE id = ?", (game_id,))

    def save_round(self, game_id, rnd, round_type, rows):
        for r in rows:
            self._write("INSERT INTO round_scores (game_id, round, round_type, player_id, tile, points, score, lives)"
                        " VALUES (?,?,?,?,?,?,?,?)", (game_id, rnd, round_type, r.get("player_id") or None,
                                                      r["tile"], r["points"], r["score"], r["lives"]))

    def save_result(self, game_id, r):
        self._write("INSERT INTO results (game_id, player_id, tile, name, score, lives, exterminated, rank)"
                    " VALUES (?,?,?,?,?,?,?,?)", (game_id, r.get("player_id") or None, r["tile"], r["name"],
                                                  r["score"], r["lives"], int(bool(r.get("exterminated"))),
                                                  r.get("rank")))

    def leaderboard(self, limit=1000):
        """Every player's highest score over all plays, best first."""
        return self._all("SELECT p.id AS player_id, p.name AS name, MAX(r.score) AS best, COUNT(r.id) AS plays"
                         " FROM results r JOIN players p ON p.id = r.player_id"
                         " GROUP BY p.id ORDER BY best DESC LIMIT ?", (limit,))

    def recent_results(self, limit=30):
        return self._all("SELECT r.*, g.started_at FROM results r JOIN games g ON g.id = r.game_id"
                         " ORDER BY r.id DESC LIMIT ?", (limit,))

    def import_questions(self, path):
        with open(path, encoding="utf-8") as f:
            items = json.load(f)
        for q in items:
            a = q["answers"]
            row = {"slug": q.get("id") or q["question"][:40], "category": q.get("category", ""),
                   "min_age": q.get("min_age", 0), "max_age": q.get("max_age", 99), "question": q["question"],
                   "text": q.get("text", ""), "answer1": a[0], "answer2": a[1], "answer3": a[2], "answer4": a[3],
                   "correct": q["correct"], "explanation": q.get("explanation", ""), "video": q.get("video", ""),
                   "video_when": q.get("video_when", "before"), "image": q.get("image", ""),
                   "time": q.get("time", 0), "active": 1}
            existing = self._one("SELECT id FROM questions WHERE slug = ?", (row["slug"],))
            self.save_question(row, existing["id"] if existing else None)
        return len(items)
