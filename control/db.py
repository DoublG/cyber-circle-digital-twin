"""The Cyber Circle database. The control server is its only owner: the game
master, the app and the web interface all go through the control server's
HTTP API. SQLAlchemy (Core): MySQL / MariaDB on the installation
(mysql+pymysql://user:password@host/cybercircle), or a SQLite file (a plain
path: tests, trying things out). The tables match ../game/data/schema.sql
(the game's standalone SQLite mode and tools/ops/cybercircle_db.py)."""

import datetime
import json
import os
import uuid

from sqlalchemy import (Column, DateTime, Float, ForeignKey, Index, Integer, MetaData, String, Table, Text,
                        create_engine, func, inspect, select, text, update, insert, delete, event)

QUESTION_FIELDS = ("slug", "category", "min_age", "max_age", "question", "text", "answer1", "answer2",
                   "answer3", "answer4", "correct", "explanation", "video", "video_when", "image", "time", "active")

FLOOR_TILES = 13                          # places around the robot
PLACES = 18                               # + 5 mobile players (M1-M5 = 14-18)

meta = MetaData()
# (MySQL: an indexed / unique column must be a VARCHAR, not TEXT)
players = Table(
    "players", meta,
    Column("id", Integer, primary_key=True, autoincrement=True),
    Column("name", String(255), nullable=False),
    Column("color", String(16), nullable=False, server_default="#ffcc00"),     # the colour picked in the app
    Column("age", Integer, nullable=False, server_default="0"),                # 0 = unknown
    Column("card", String(191)),                                               # the QR card's code
    Column("email", String(255)),                                              # optional
    Column("created_at", DateTime, nullable=False, server_default=func.now()),
    Index("players_card", "card", unique=True))
questions = Table(
    "questions", meta,
    Column("id", Integer, primary_key=True, autoincrement=True),
    Column("slug", String(191), unique=True),                  # optional readable id
    Column("category", String(191), nullable=False, server_default=""),
    Column("min_age", Integer, nullable=False, server_default="0"),
    Column("max_age", Integer, nullable=False, server_default="99"),
    Column("question", Text, nullable=False),
    Column("text", Text, nullable=False),                      # longer text under the question
    Column("answer1", Text, nullable=False),                   # answer 1..4 = Square, Triangle, Cross, Circle
    Column("answer2", Text, nullable=False),
    Column("answer3", Text, nullable=False),
    Column("answer4", Text, nullable=False),
    Column("correct", Integer, nullable=False),                # 0..3
    Column("explanation", Text, nullable=False),
    Column("video", String(255), nullable=False, server_default=""),
    Column("video_when", String(16), nullable=False, server_default="before"),
    Column("image", String(255), nullable=False, server_default=""),
    Column("time", Float, nullable=False, server_default="0"),  # seconds to answer, 0 = game default
    Column("active", Integer, nullable=False, server_default="1"))
events = Table(                                                # an event (a fair, a festival: 1-2 days)
    "events", meta,                                            # the ranking is per event; old ones are kept
    Column("id", Integer, primary_key=True, autoincrement=True),
    Column("name", String(255), nullable=False),
    Column("started_at", DateTime, nullable=False, server_default=func.now()),
    Column("ended_at", DateTime))                              # NULL: the current one
games = Table(
    "games", meta,
    Column("id", Integer, primary_key=True, autoincrement=True),
    Column("event_id", Integer, ForeignKey("events.id")),      # the event it was played at
    Column("started_at", DateTime, nullable=False, server_default=func.now()),
    Column("ended_at", DateTime))
round_scores = Table(
    "round_scores", meta,
    Column("id", Integer, primary_key=True, autoincrement=True),
    Column("game_id", Integer, ForeignKey("games.id"), nullable=False),
    Column("round", Integer, nullable=False),
    Column("round_type", String(32), nullable=False),
    Column("player_id", Integer, ForeignKey("players.id")),   # NULL: joined without the app
    Column("tile", Integer, nullable=False),
    Column("points", Integer, nullable=False),                 # points in this round (the round's places)
    Column("score", Integer, nullable=False),                  # rounds survived so far in this play
    Column("lives", Integer, nullable=False),
    Column("created_at", DateTime, nullable=False, server_default=func.now()))
results = Table(
    "results", meta,
    Column("id", Integer, primary_key=True, autoincrement=True),
    Column("game_id", Integer, ForeignKey("games.id"), nullable=False),
    Column("player_id", Integer, ForeignKey("players.id")),
    Column("tile", Integer, nullable=False),
    Column("name", String(255), nullable=False),
    Column("score", Integer, nullable=False),                  # rounds survived (the ranking: best per player)
    Column("lives", Integer, nullable=False),
    Column("exterminated", Integer, nullable=False, server_default="0"),
    Column("rank", Integer),                                   # NULL for exterminated players
    Column("created_at", DateTime, nullable=False, server_default=func.now()))
tiles_t = Table(
    "tiles", meta,
    Column("number", Integer, primary_key=True, autoincrement=False),   # the place: 1-13 floor, 14-18 mobile
    Column("device", String(64), unique=True),                 # the physical tile on it (its MAC address)
    Column("enabled", Integer, nullable=False, server_default="1"))     # 0 = out of service
gamemasters_t = Table(
    "gamemasters", meta,
    Column("id", Integer, primary_key=True, autoincrement=True),
    Column("name", String(255), nullable=False),
    Column("color", String(16), nullable=False),               # the tiles they assign light up in it
    Column("active", Integer, nullable=False, server_default="1"))
settings_t = Table(
    "settings", meta,
    Column("key", String(191), primary_key=True),              # e.g. "mode": setup / closed / open / paused
    Column("value", Text(16_000_000), nullable=False))           # (MySQL: MEDIUMTEXT - the game's checkpoint)

# columns added after the first installations: (table, column, SQL type) - added when missing
LATER_COLUMNS = (("questions", "image", "VARCHAR(255) NOT NULL DEFAULT ''"),
                 ("players", "card", "VARCHAR(191)"), ("players", "email", "VARCHAR(255)"),
                 ("games", "event_id", "INTEGER"))


def engine_url(db):
    """--db: a SQLAlchemy URL, or a plain path = a SQLite file."""
    return db if "://" in db else "sqlite:///" + os.path.abspath(db)


def _plain(row):
    """A row as JSON-friendly dict (times as 'YYYY-MM-DD HH:MM:SS', as SQLite stores them)."""
    return {k: (v.strftime("%Y-%m-%d %H:%M:%S") if isinstance(v, datetime.datetime) else v)
            for k, v in row._mapping.items()}


class Database:
    def __init__(self, db):
        self.url = engine_url(db)
        sqlite = self.url.startswith("sqlite")
        # MySQL closes idle connections: check them before use, renew them hourly
        self.engine = create_engine(self.url, pool_pre_ping=True, **({} if sqlite else {"pool_recycle": 3600}))
        if sqlite:
            @event.listens_for(self.engine, "connect")
            def _pragmas(con, _):
                con.execute("PRAGMA journal_mode = WAL")
                con.execute("PRAGMA foreign_keys = ON")
        meta.create_all(self.engine)
        cols = {t: {c["name"] for c in inspect(self.engine).get_columns(t)} for t in ("questions", "players", "games")}
        with self.engine.begin() as con:
            for table, column, sqltype in LATER_COLUMNS:       # databases from before these columns
                if column not in cols[table]:
                    con.execute(text(f"ALTER TABLE {table} ADD COLUMN {column} {sqltype}"))
        if self.engine.dialect.name == "mysql":
            vtype = next(c["type"] for c in inspect(self.engine).get_columns("settings") if c["name"] == "value")
            if type(vtype).__name__ == "TEXT":          # (a database from before the checkpoint)
                with self.engine.begin() as con:
                    con.execute(text("ALTER TABLE settings MODIFY value MEDIUMTEXT NOT NULL"))
        if "card" not in cols["players"]:          # (and its index, before the QR cards)
            with self.engine.begin() as con:
                con.execute(text("CREATE UNIQUE INDEX players_card ON players (card)"))
        self._first_event()

    def _all(self, stmt):
        with self.engine.connect() as con:
            return [_plain(r) for r in con.execute(stmt)]

    def _one(self, stmt):
        rows = self._all(stmt)
        return rows[0] if rows else None

    def _write(self, stmt):
        with self.engine.begin() as con:
            res = con.execute(stmt)
            return res.inserted_primary_key[0] if res.is_insert and res.inserted_primary_key else None

    # ------------------------------------------------------------ settings

    def setting(self, key, default=None):
        row = self._one(select(settings_t.c.value).where(settings_t.c.key == key))
        return row["value"] if row else default

    def set_setting(self, key, value):
        with self.engine.begin() as con:
            if con.execute(update(settings_t).where(settings_t.c.key == key).values(value=str(value))).rowcount == 0:
                if con.execute(select(settings_t.c.key).where(settings_t.c.key == key)).first() is None:
                    con.execute(insert(settings_t).values(key=key, value=str(value)))

    def instance_id(self):
        """This database's own id: the game's checkpoints belong to it (a test
        database's never come back in the installation)."""
        v = self.setting("db_id")
        if not v:
            v = uuid.uuid4().hex
            self.set_setting("db_id", v)
        return v

    # ------------------------------------------------------------ tiles (places around the robot)

    def tiles(self):
        """The 18 places: 1-13 the floor tiles around the robot, 14-18 the mobile
        players' handheld tiles (M1-M5, their drones in the game): which physical
        tile (device id) is there, in service or not."""
        with self.engine.begin() as con:
            have = {r[0] for r in con.execute(select(tiles_t.c.number))}
            missing = [{"number": n} for n in range(1, PLACES + 1) if n not in have]
            if missing:
                con.execute(insert(tiles_t), missing)
        return self._all(select(tiles_t.c.number, tiles_t.c.device, tiles_t.c.enabled).order_by(tiles_t.c.number))

    def set_tile(self, number, device=..., enabled=None):
        """device: a device id, None (no device) or ... (unchanged)."""
        self.tiles()
        with self.engine.begin() as con:
            if device is not ...:
                if device:                       # a device stands on one place only
                    con.execute(update(tiles_t).where(tiles_t.c.device == device).values(device=None))
                con.execute(update(tiles_t).where(tiles_t.c.number == number).values(device=device or None))
            if enabled is not None:
                con.execute(update(tiles_t).where(tiles_t.c.number == number).values(enabled=int(bool(enabled))))

    # ------------------------------------------------------------ gamemasters

    def gamemasters(self):
        g = gamemasters_t.c
        return self._all(select(g.id, g.name, g.color).where(g.active == 1).order_by(g.name))

    def gamemaster(self, gid):
        g = gamemasters_t.c
        return self._one(select(g.id, g.name, g.color).where(g.id == gid, g.active == 1))

    def save_gamemaster(self, name, color, gid=None):
        if gid is None:
            return self._write(insert(gamemasters_t).values(name=name, color=color))
        self._write(update(gamemasters_t).where(gamemasters_t.c.id == gid).values(name=name, color=color))
        return gid

    def remove_gamemaster(self, gid):
        self._write(update(gamemasters_t).where(gamemasters_t.c.id == gid).values(active=0))

    # ------------------------------------------------------------ players

    def add_player(self, name, color="#ffcc00", age=0, card=None):
        """card: the QR card's code. A card belongs to one player for good: a
        card that is linked already gives that player (they come back and play
        again - their plays add up), no new one."""
        if card:
            p = self.player_by_card(card)
            if p:
                return p["id"]
        with self.engine.begin() as con:
            res = con.execute(insert(players).values(name=name, color=color, age=int(age), card=card or None))
            return res.inserted_primary_key[0]

    def _player_cols(self):
        p = players.c
        return select(p.id, p.name, p.color, p.age, p.card)

    def player(self, pid):
        return self._one(self._player_cols().where(players.c.id == pid))

    def upsert_card(self, card, name, age=0, email=None):
        """The registration website's sync (or a gamemaster for a visitor without
        a phone): the player behind a card, created or updated (a card
        registered again: the same player, new name / age / email)."""
        p = self.player_by_card(card)
        pid = p["id"] if p else self.add_player(name, age=age, card=card)
        self._write(update(players).where(players.c.id == pid).values(name=name, age=int(age), email=email or None))
        return pid

    def player_by_card(self, card):
        """The player registered with this QR card, or None."""
        return self._one(self._player_cols().where(players.c.card == card))

    def players(self, search="", limit=50):
        p, r = players.c, results.c
        return self._all(
            select(p.id, p.name, p.color, p.age, p.card, func.max(r.score).label("best"), func.count(r.id).label("plays"))
            .select_from(players.outerjoin(results, r.player_id == p.id))
            .where(p.name.like(f"%{search}%"))
            .group_by(p.id, p.name, p.color, p.age, p.card).order_by(p.id.desc()).limit(limit))

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
        return [self.question_json(r) for r in
                self._all(select(questions).where(questions.c.active == 1).order_by(questions.c.id))]

    def question_rows(self):
        return self._all(select(questions).order_by(questions.c.id))

    def save_question(self, q, qid=None):
        values = {f: q.get(f) for f in QUESTION_FIELDS}
        for f in ("text", "explanation", "video", "image", "category"):     # (NOT NULL text columns)
            if values[f] is None:
                values[f] = ""
        for f, default in (("video_when", "before"), ("min_age", 0), ("max_age", 99), ("time", 0), ("active", 1)):
            if values[f] is None:
                values[f] = default
        if qid is None:
            return self._write(insert(questions).values(**values))
        self._write(update(questions).where(questions.c.id == qid).values(**values))
        return qid

    def delete_question(self, qid):
        self._write(delete(questions).where(questions.c.id == qid))

    # ------------------------------------------------------------ games and scores

    def start_game(self):
        return self._write(insert(games).values(started_at=func.now(), event_id=self.current_event_id()))

    # ------------------------------------------------------------ events (the ranking is per event)

    def _first_event(self):
        """There is always a current event: a new database starts one; a database
        from before the events puts all its games in one (from its first game on)."""
        if self.setting("event_id"):
            return
        with self.engine.begin() as con:
            first = con.execute(select(func.min(games.c.started_at))).scalar()
            eid = con.execute(insert(events).values(
                name="Eerste event", **({"started_at": first} if first else {}))).inserted_primary_key[0]
            con.execute(update(games).where(games.c.event_id.is_(None)).values(event_id=eid))
        self.set_setting("event_id", str(eid))

    def current_event_id(self):
        return int(self.setting("event_id", "0") or 0) or None

    def _event_stats(self, ev):
        g, r = games.c, results.c
        with self.engine.begin() as con:
            ids = select(g.id).where(g.event_id == ev["id"])
            n_games = con.execute(select(func.count()).select_from(games).where(g.event_id == ev["id"])).scalar()
            row = con.execute(select(func.count(func.distinct(r.player_id)), func.count(r.id), func.max(r.score))
                              .where(r.game_id.in_(ids))).one()
        return {**ev, "games": n_games, "players": row[0], "plays": row[1], "best": row[2] or 0,
                "current": ev["id"] == self.current_event_id()}

    def event(self, event_id=None):
        ev = self._one(select(events).where(events.c.id == (event_id or self.current_event_id())))
        return self._event_stats(ev) if ev else None

    def events(self):
        """Every event, the newest first, with its numbers (games, players, plays, best)."""
        return [self._event_stats(e) for e in self._all(select(events).order_by(events.c.id.desc()))]

    def new_event(self, name):
        """Closes the current event (it is kept, with all its games) and starts a new
        one: from now on the ranking starts empty. Returns (the old id, the new id)."""
        old = self.current_event_id()
        with self.engine.begin() as con:
            if old:
                con.execute(update(events).where(events.c.id == old).values(ended_at=func.now()))
            eid = con.execute(insert(events).values(name=name)).inserted_primary_key[0]
        self.set_setting("event_id", str(eid))
        return old, eid

    def export_event(self, event_id):
        """Everything of one event (for marketing, a backup): the event, the players
        who played at it (name, age, email, card), its games, results and rounds."""
        ids = select(games.c.id).where(games.c.event_id == event_id)
        pids = select(results.c.player_id).where(results.c.game_id.in_(ids)).distinct()
        return {"event": self.event(event_id),
                "players": self._all(select(players).where(players.c.id.in_(pids)).order_by(players.c.id)),
                "games": self._all(select(games).where(games.c.event_id == event_id).order_by(games.c.id)),
                "results": self._all(select(results).where(results.c.game_id.in_(ids)).order_by(results.c.id)),
                "rounds": self._all(select(round_scores).where(round_scores.c.game_id.in_(ids))
                                    .order_by(round_scores.c.id))}

    def end_game(self, game_id):
        self._write(update(games).where(games.c.id == game_id).values(ended_at=func.now()))

    def save_round(self, game_id, rnd, round_type, rows):
        if not rows:
            return
        with self.engine.begin() as con:
            con.execute(insert(round_scores), [
                {"game_id": game_id, "round": rnd, "round_type": round_type, "player_id": r.get("player_id") or None,
                 "tile": r["tile"], "points": r["points"], "score": r["score"], "lives": r["lives"]} for r in rows])

    def save_result(self, game_id, r):
        self._write(insert(results).values(
            game_id=game_id, player_id=r.get("player_id") or None, tile=r["tile"], name=r["name"], score=r["score"],
            lives=r["lives"], exterminated=int(bool(r.get("exterminated"))), rank=r.get("rank")))

    def leaderboard(self, limit=1000, event_id=None):
        """The ranking of an event (default: the current one), best first: per player
        their best play at it - most rounds survived, then most lives left, then the
        most points in that play (the tie-breakers). "rank": shared only when all
        three are equal. [{player_id, name, best, lives, points, plays, rank}]"""
        r, p, rs = results.c, players.c, round_scores.c
        pts = (select(rs.game_id, rs.player_id, func.sum(rs.points).label("points"))
               .group_by(rs.game_id, rs.player_id).subquery())
        rows = self._all(
            select(p.id.label("player_id"), p.name.label("name"), r.score, r.lives,
                   func.coalesce(pts.c.points, 0).label("points"))
            .select_from(results.join(players, p.id == r.player_id).join(games, games.c.id == r.game_id)
                         .outerjoin(pts, (pts.c.game_id == r.game_id) & (pts.c.player_id == r.player_id)))
            .where(games.c.event_id == (event_id or self.current_event_id())))
        best, plays = {}, {}
        for row in rows:
            pid = row["player_id"]
            key = (int(row["score"]), int(row["lives"]), int(row["points"]))
            plays[pid] = plays.get(pid, 0) + 1
            if pid not in best or key > best[pid][0]:
                best[pid] = (key, row["name"])
        out = sorted(({"player_id": pid, "name": name, "best": k[0], "lives": k[1], "points": k[2],
                       "plays": plays[pid]} for pid, (k, name) in best.items()),
                     key=lambda x: (-x["best"], -x["lives"], -x["points"], x["name"]))
        for i, row in enumerate(out):
            same = i > 0 and (row["best"], row["lives"], row["points"]) == (out[i - 1]["best"], out[i - 1]["lives"],
                                                                         out[i - 1]["points"])
            row["rank"] = out[i - 1]["rank"] if same else i + 1
        return out[:limit]

    def recent_results(self, limit=30):
        return self._all(select(results, games.c.started_at).select_from(results.join(games, games.c.id == results.c.game_id))
                         .order_by(results.c.id.desc()).limit(limit))

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
            existing = self._one(select(questions.c.id).where(questions.c.slug == row["slug"]))
            self.save_question(row, existing["id"] if existing else None)
        return len(items)
