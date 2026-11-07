class_name GameDb
extends RefCounted
## The Cyber Circle database (SQLite via the godot-sqlite extension), shared
## with the external app (see data/schema.sql and tools/ops/cybercircle_db.py):
##   players       put in by the app; the game reads name, colour and age when
##                 the app sends {"assign": <id>} over MQTT
##   questions     managed in the database; read at the start of every game
##   games, round_scores, results   written by the game
## Without the extension or the file the game still runs: questions come from
## data/questions.json and nothing is saved.

const SCHEMA_FILE := "res://data/schema.sql"

var _db: Object                   # SQLite (created through ClassDB: no hard dependency)


## Open (and create if needed) the database file. false = not available.
func open(path: String) -> bool:
	if not ClassDB.class_exists("SQLite"):
		push_warning("database: godot-sqlite extension not found - questions from JSON, scores not saved")
		return false
	_db = ClassDB.instantiate("SQLite")
	_db.path = ProjectSettings.globalize_path(path)
	_db.verbosity_level = 0       # quiet
	_db.foreign_keys = true
	if not _db.open_db():
		push_warning("database: cannot open %s" % path)
		_db = null
		return false
	_db.query("PRAGMA journal_mode = WAL")      # the app can write while the game reads
	_db.query("PRAGMA busy_timeout = 2000")
	var sql := FileAccess.get_file_as_string(SCHEMA_FILE)
	var lines := PackedStringArray()
	for l in sql.split("\n"):
		lines.append(l.get_slice("--", 0))        # drop comments (they may contain ';')
	for statement in "\n".join(lines).split(";"):
		if statement.strip_edges() != "":
			_db.query(statement)
	_db.query("PRAGMA table_info(questions)")
	if not _db.query_result.any(func(c): return c.name == "image"):   # from before the picture column
		_db.query("ALTER TABLE questions ADD COLUMN image TEXT NOT NULL DEFAULT ''")
	return true


func is_open() -> bool:
	return _db != null


## Active questions, in the format QuizRound uses.
func questions() -> Array:
	if not _run("SELECT * FROM questions WHERE active = 1 ORDER BY id", []):
		return []
	var out := []
	for r in _db.query_result:
		var q := {"id": r.slug if r.slug else str(r.id), "category": r.category,
			"min_age": r.min_age, "max_age": r.max_age, "question": r.question,
			"answers": [r.answer1, r.answer2, r.answer3, r.answer4], "correct": r.correct}
		for key in ["text", "explanation", "video", "image"]:
			if str(r[key]) != "":
				q[key] = r[key]
		if str(r.video) != "":
			q.video_when = r.video_when
		if float(r.time) > 0.0:
			q.time = float(r.time)
		out.append(q)
	return out


## Same as player(); ControlApi has to ask the server, so callers await this.
func fetch_player(id: int) -> Dictionary:
	return player(id)


## {"id", "name", "color", "age"} or {} when unknown.
func player(id: int) -> Dictionary:
	if not _run("SELECT id, name, color, age FROM players WHERE id = ?", [id]) or _db.query_result.is_empty():
		return {}
	return _db.query_result[0]


## What the external app does (also used by the demo and tests): returns the id.
func add_player(name: String, color: String, age := 0) -> int:
	if not _run("INSERT INTO players (name, color, age) VALUES (?,?,?)", [name, color, age]):
		return 0
	return _db.last_insert_rowid


## Add a question in the QuizRound format (demo and tests; normally managed in the database).
func add_question(q: Dictionary) -> void:
	var a: Array = q.answers
	_run("INSERT INTO questions (slug, category, min_age, max_age, question, text, answer1, answer2,"
		+ " answer3, answer4, correct, explanation, video, video_when, image, time) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
		[q.get("id", null), q.get("category", ""), q.get("min_age", 0), q.get("max_age", 99), q.question,
		q.get("text", ""), a[0], a[1], a[2], a[3], q.correct, q.get("explanation", ""), q.get("video", ""),
		q.get("video_when", "before"), q.get("image", ""), q.get("time", 0)])


## Rows of any query (tests, tools).
func select(sql: String, bindings := []) -> Array:
	return _db.query_result.duplicate() if _run(sql, bindings) else []


## The ranking (standalone: all plays in this file): per player their best play -
## most rounds survived, then most lives left, then the most points (the
## tie-breakers, as the control server): [{player_id, name, best, lives, points, plays}].
func leaderboard() -> Array:
	return select("SELECT player_id, name, best, lives, points, plays FROM ("
		+ " SELECT p.id AS player_id, p.name AS name, r.score AS best, r.lives AS lives,"
		+ " COALESCE((SELECT SUM(s.points) FROM round_scores s WHERE s.game_id = r.game_id AND s.player_id = r.player_id), 0) AS points,"
		+ " COUNT(*) OVER (PARTITION BY p.id) AS plays,"
		+ " ROW_NUMBER() OVER (PARTITION BY p.id ORDER BY r.score DESC, r.lives DESC,"
		+ " (SELECT SUM(s.points) FROM round_scores s WHERE s.game_id = r.game_id AND s.player_id = r.player_id) DESC) AS n"
		+ " FROM results r JOIN players p ON p.id = r.player_id)"
		+ " WHERE n = 1 ORDER BY best DESC, lives DESC, points DESC")


## A new game; returns its id (0 without a database).
func start_game() -> int:
	if not _run("INSERT INTO games DEFAULT VALUES", []):
		return 0
	return _db.last_insert_rowid


func end_game(game_id: int) -> void:
	_run("UPDATE games SET ended_at = datetime('now') WHERE id = ?", [game_id])


## rows: [{player_id, tile, points, score, lives}]
func save_round(game_id: int, round: int, round_type: String, rows: Array) -> void:
	for r in rows:
		_run("INSERT INTO round_scores (game_id, round, round_type, player_id, tile, points, score, lives)"
			+ " VALUES (?,?,?,?,?,?,?,?)", [game_id, round, round_type, _id_or_null(r.player_id),
			r.tile, r.points, r.score, r.lives])


## End result of one player: survivors with their rank, exterminated without.
func save_result(game_id: int, r: Dictionary) -> void:
	_run("INSERT INTO results (game_id, player_id, tile, name, score, lives, exterminated, rank)"
		+ " VALUES (?,?,?,?,?,?,?,?)", [game_id, _id_or_null(r.player_id), r.tile, r.name, r.score,
		r.lives, 1 if r.exterminated else 0, r.get("rank")])


func _id_or_null(id):
	return null if int(id) <= 0 else int(id)


func _run(sql: String, bindings: Array) -> bool:
	if _db == null:
		return false
	var ok: bool = _db.query_with_bindings(sql, bindings)
	if not ok:
		push_warning("database: %s (%s)" % [_db.error_message, sql.left(60)])
	return ok
