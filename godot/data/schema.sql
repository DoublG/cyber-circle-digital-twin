-- Cyber Circle database (SQLite). Used by the game (scripts/data/game_db.gd)
-- and tools/cybercircle_db.py; every statement is safe to run again.

CREATE TABLE IF NOT EXISTS players (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL,
    color      TEXT    NOT NULL DEFAULT '#ffcc00',   -- the colour picked in the app
    age        INTEGER NOT NULL DEFAULT 0,           -- 0 = unknown
    created_at TEXT    NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS questions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    slug        TEXT UNIQUE,                 -- optional readable id
    category    TEXT    NOT NULL DEFAULT '',
    min_age     INTEGER NOT NULL DEFAULT 0,  -- younger players are protected (shield)
    max_age     INTEGER NOT NULL DEFAULT 99,
    question    TEXT    NOT NULL,
    text        TEXT    NOT NULL DEFAULT '', -- longer text under the question
    answer1     TEXT    NOT NULL,            -- answer 1..4 = Square, Triangle, Cross, Circle
    answer2     TEXT    NOT NULL,
    answer3     TEXT    NOT NULL,
    answer4     TEXT    NOT NULL,
    correct     INTEGER NOT NULL,            -- 0..3
    explanation TEXT    NOT NULL DEFAULT '',
    video       TEXT    NOT NULL DEFAULT '', -- file in godot/data/videos/ (or absolute path)
    video_when  TEXT    NOT NULL DEFAULT 'before',
    time        REAL    NOT NULL DEFAULT 0,  -- seconds to answer, 0 = game default
    active      INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS games (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at TEXT NOT NULL DEFAULT (datetime('now')),
    ended_at   TEXT
);
CREATE TABLE IF NOT EXISTS round_scores (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    game_id    INTEGER NOT NULL REFERENCES games(id),
    round      INTEGER NOT NULL,
    round_type TEXT    NOT NULL,
    player_id  INTEGER REFERENCES players(id),   -- NULL: player joined without the app
    tile       INTEGER NOT NULL,
    points     INTEGER NOT NULL,                 -- points in this round (decide the round's places)
    score      INTEGER NOT NULL,                 -- rounds survived so far in this play
    lives      INTEGER NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS results (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    game_id      INTEGER NOT NULL REFERENCES games(id),
    player_id    INTEGER REFERENCES players(id),
    tile         INTEGER NOT NULL,
    name         TEXT    NOT NULL,
    score        INTEGER NOT NULL,               -- rounds survived (the ranking: best per player)
    lives        INTEGER NOT NULL,
    exterminated INTEGER NOT NULL DEFAULT 0,
    rank         INTEGER,                        -- NULL for exterminated players
    created_at   TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS tiles (
    number  INTEGER PRIMARY KEY,                  -- 1..13: the place around the robot
    device  TEXT UNIQUE,                          -- the physical tile on that place (its own id)
    enabled INTEGER NOT NULL DEFAULT 1            -- 0 = out of service: not used in the game
);
CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,                       -- e.g. "mode": setup / closed / open / paused
    value TEXT NOT NULL
);
