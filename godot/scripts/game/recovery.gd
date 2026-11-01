class_name Recovery
extends Node
## Crash / power cut: the game comes back where it was.
##
## At every stable moment (a player invited / activated / leaving, a round
## starting, the end of a round, the lives given and taken) the game marks a
## checkpoint; it is written at most every SAVE_GAP s:
##   * to the control server (PUT /api/checkpoint): the keeper of the game
##     state - in its database, so it survives the control server restarting,
##     and a replaced screen PC gets it too;
##   * to a local file (written to .tmp, then renamed: never half a file) -
##     the fallback while the control server can't be reached.
## At the start the game asks the control server for the state (and reads the
## local file) and continues from the newest. A checkpoint belongs to one
## database (the control server's db id / the SQLite file): a test server's
## never comes back in the installation. Older than max_age: a previous day's
## game - a fresh start.
##
## What comes back: the players on their tiles with their lives, the invites,
## the game in the database (its id: the plays go on there), the rounds
## survived, the plan of the coming rounds and the question memory. A round that
## was interrupted never counted (lives only change at its end): it is played
## again from its intro. Interrupted on the scoreboard: the lives that were
## about to change change now (exterminations too), then the next round.

const VERSION := 1
const SAVE_GAP := 0.5

@export var enabled := true
@export var max_age := 3600.0              # s
var game                                   # GameManager
var _dirty := false
var _wait := 0.0
var _restoring := false


## Write a checkpoint soon (the game is at a stable moment).
func mark() -> void:
	_dirty = true


func _process(delta: float) -> void:
	_wait -= delta
	if _dirty and _wait <= 0.0 and enabled and not _restoring and _active():
		_dirty = false
		_wait = SAVE_GAP
		save()


## Only the game itself (not a test scene that builds an arena of its own).
func _active() -> bool:
	return get_tree().current_scene == game.arena


func local_file() -> String:
	var key: String = game.control_url if game.control_url != "" else game.db_path
	return "user://checkpoint_%s.json" % key.md5_text().left(12)


func _db_key() -> String:
	if game.db and game.db.has_method("db_id"):
		return game.db.db_id()
	return game.db_path


func snapshot() -> Dictionary:
	var a = game.arena
	var players := []
	for id in a.player_ids():
		var t: CyberTile = a.tiles[id - 1]
		var lives: int = game._target_lives.get(id, a.lives_after_hits(id))
		players.append({"tile": id, "name": a.player_name(id), "age": a.player_age(id),
			"player_id": a.player_db_id(id), "lives": lives, "max_lives": t.max_health,
			"dead": t.is_dead or lives <= 0, "started": game._started.has(id),
			"score": game.scores.get(id, 0), "survived": game.survived.get(id, 0),
			"streak": game.streaks.get(id, 0), "saved": game._result_saved.has(id)})
	var invites := []
	for id in a._pending:
		var p: Dictionary = a._pending[id]
		invites.append({"tile": id, "name": p.name, "color": p.color.to_html(false), "age": p.age,
			"player_id": p.player_id})
	var cur := {}
	if game.current and not game._current_entry.is_empty():
		cur = {"type": game.round_type_name(game._current_entry.type),
			"options": game._current_entry.get("options", {}), "forced": game._current_entry.get("forced", false)}
	var gid: int = game.game_id
	if gid < 0 and game.db and game.db.has_method("server_game_id"):
		gid = game.db.server_game_id(gid)       # (the server's id once known)
	return {"version": VERSION, "time": Time.get_unix_time_from_system(), "db": _db_key(),
		"state": GameManager.State.keys()[game.state], "game_id": gid, "round": game.round_number,
		"current": cur, "pending_lives": game._pending_lives, "players": players, "invites": invites,
		"upcoming": game.upcoming.map(func(e): return {"type": game.round_type_name(e.type),
			"forced": e.get("forced", false), "options": e.get("options", {})}),
		"planned": game._planned, "history": game._history.map(func(t): return game.round_type_name(t)),
		"question_memory": game.question_memory}


func save() -> void:
	var data := snapshot()
	var text := JSON.stringify(data)
	var path := local_file()
	var f := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if f:
		f.store_string(text)
		f.flush()
		f.close()
		DirAccess.rename_absolute(ProjectSettings.globalize_path(path + ".tmp"), ProjectSettings.globalize_path(path))
	if game.db and game.db.has_method("save_checkpoint"):
		game.db.save_checkpoint(data)


## At the start: the newest checkpoint of this database, if any.
func restore() -> void:
	if not enabled or not _active():
		return
	_restoring = true
	var local = null
	if FileAccess.file_exists(local_file()):
		local = JSON.parse_string(FileAccess.get_file_as_string(local_file()))
	var cp = local if local is Dictionary else null
	if game.db and game.db.has_method("fetch_checkpoint"):
		var remote = await game.db.fetch_checkpoint()   # {db, checkpoint} or null: not reachable
		if remote is Dictionary:
			if cp and cp.get("db") != remote.get("db"):
				cp = null                                 # another database's (a test server's)
			var r = remote.get("checkpoint")
			if r is Dictionary and r.get("db") == remote.get("db") and (cp == null or r.time >= cp.time):
				cp = r
	_restoring = false
	var key := _db_key()                 # ("" : the control server never seen - the local file is its own)
	if cp == null or int(cp.get("version", 0)) != VERSION or (key != "" and cp.get("db") != key):
		return
	var age := Time.get_unix_time_from_system() - float(cp.time)
	if age > max_age:
		print("recovery: the last checkpoint is %d min old - a fresh start" % int(age / 60))
		return
	if cp.players.is_empty() and cp.invites.is_empty():
		return
	apply(cp)


func apply(cp: Dictionary) -> void:
	_restoring = true
	var a = game.arena
	var st: String = cp.state
	print("recovery: back to %s, round %d, %d players, %d invites (%d s ago)" % [st, int(cp.round),
		cp.players.size(), cp.invites.size(), int(Time.get_unix_time_from_system() - float(cp.time))])
	game.upcoming = []
	for e in cp.upcoming:
		var t: Script = game._round_type(e.type)
		if t:
			game.upcoming.append({"type": t, "forced": e.forced, "options": e.options})
	game._planned = int(cp.planned)
	game._history.clear()
	for n in cp.history:
		var t: Script = game._round_type(n)
		if t:
			game._history.append(t)
	var qm: Dictionary = cp.question_memory
	game.question_memory = {"count": int(qm.get("count", 0)), "since": _ints(qm.get("since", {})),
		"asked": _ints(qm.get("asked", {}))}
	for p in cp.players:
		a.restore_player(int(p.tile), p.name, int(p.age), int(p.player_id), maxi(int(p.lives), 1), int(p.max_lives))
	for p in cp.invites:
		a.restore_invite(int(p.tile), p.name, Color(p.color), int(p.age), int(p.player_id))
	var in_game := st != "LOBBY"
	if in_game:
		var gid := int(cp.game_id)
		if gid < 0 and not (game.db and game.db.has_method("knows_game") and game.db.knows_game(gid)):
			gid = game.db.start_game() if game.db else 0   # (it never reached the database: a new one)
		game.game_id = gid
		game.round_number = int(cp.round)
		for p in cp.players:
			var id := int(p.tile)
			game.scores[id] = int(p.score)
			game.survived[id] = int(p.survived)
			game.streaks[id] = int(p.streak)
			if p.started:
				game._started[id] = true
			if p.saved:
				game._result_saved[id] = true
		game.state = GameManager.State.SCOREBOARD         # (a game is on: leaving saves the result)
	for p in cp.players:                                   # exterminated: their play ends now
		if p.dead:
			a.tiles[int(p.tile) - 1].is_dead = true
			a.leave(int(p.tile))
	var changes := {}
	if st == "INTRO" or st == "PLAYING":                   # interrupted: that round again
		game.round_number -= 1
		if not cp.current.is_empty():
			var t: Script = game._round_type(cp.current.type)
			if t:
				game.upcoming.push_front({"type": t, "forced": true, "options": cp.current.options})
	elif st == "SCOREBOARD":
		for k in cp.pending_lives:
			if a.is_playing(int(k)):
				changes[int(k)] = int(cp.pending_lives[k])
	game.on_players_changed()
	_restoring = false
	if in_game and not a.player_ids().is_empty():
		game.resume(changes)
	else:
		if in_game:
			game._finish_game()
		game.state = GameManager.State.LOBBY
		game._enter_lobby()
		game.on_players_changed()
	mark()


static func _ints(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d:
		out[k] = int(d[k])
	return out
