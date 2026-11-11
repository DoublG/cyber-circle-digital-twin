extends Node
## Database flow (headless): the app puts players in the database and sends
## {"assign": id}; questions come from the database; round types are picked at
## random (only the quiz with few players); scores and results are saved,
## also for an exterminated player.
## Run: godot --headless --path . --fixed-fps 60 res://tests/test_db.tscn

const ARENA := preload("res://scenes/arena.tscn")
const DB_FILE := "res://tests/_test.db"

var failures := 0


func _ready() -> void:
	for f in [DB_FILE, DB_FILE + "-wal", DB_FILE + "-shm"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database(DB_FILE)
	arena.clip_wait = 1.0                       # (the death clip has no split view to wait for here)
	game.intro_time = 1.0
	game.scoreboard_time = 1.0
	game.auto_start_delay = 0.0
	var db: GameDb = game.db
	check(db != null and db.is_open(), "database opened (schema created)")

	print("--- the app puts players in the database")
	var anna := db.add_player("Anna", "#ff3399", 12)
	var bram := db.add_player("Bram", "#33ccff", 7)
	for i in 3:
		db.add_question({"id": "db_q%d" % i, "category": "test", "min_age": 6, "question": "DB vraag %d?" % i,
			"answers": ["a", "b", "c", "d"], "correct": i % 4})
	check(db.questions().size() == 3, "3 questions in the database")

	print("--- MQTT {\"assign\": id}: name, colour, age from the database")
	arena.apply_command({"assign": anna, "tile": 3})
	arena.apply_command({"assign": bram})
	arena.apply_command({"assign": 999})
	check(arena.players.is_pending(3) and arena.players.pending_info(3).name == "Anna"
		and arena.players.pending_info(3).color.is_equal_approx(Color("#ff3399")) and arena.players.pending_info(3).age == 12,
		"Anna assigned to T03 with her colour and age")
	var bram_tile := 0
	for id in range(1, 14):
		if arena.players.is_pending(id) and arena.players.pending_info(id).name == "Bram":
			bram_tile = id
	check(bram_tile > 0, "Bram assigned to a free tile (T%02d)" % bram_tile)
	check(arena.tiles.filter(func(t): return arena.players.is_pending(t.tile_id)).size() == 2, "unknown player id ignored")
	for id in [3, bram_tile]:
		for b in CyberTile.BUTTONS:
			arena.tiles[id - 1].press_button(b)
			await _wait(0.2)
	check(arena.players.player_db_id(3) == anna and arena.players.player_db_id(bram_tile) == bram,
		"activated, linked to the database")

	print("--- random round types: few players -> only the quiz")
	var picks := []
	for n in 30:
		game.picker.last_type = game.picker.pick_type(game.picker.last_type, 0)
		picks.append(game.picker.last_type)
	check(picks.all(func(t): return t.new().mode != "personal"), "2 players: no personal rounds")
	var extras := []
	for id in [8, 11, 12]:
		if extras.size() < 2 and not arena.players.is_playing(id):   # (Bram got a random tile)
			arena.players.join(id, "Extra %d" % id, 10)
			extras.append(id)
	var types := {}
	var repeats := 0
	for n in 30:
		var t: Script = game.picker.pick_type(game.picker.last_type, 0)
		repeats += 1 if t == game.picker.last_type and t != QuizRound else 0
		game.picker.last_type = t
		types[t.new().title] = true
	check(types.size() >= 3, "4 players: personal rounds too (%s)" % ", ".join(types.keys()))
	check(repeats == 0, "never the same round type twice in a row (the quiz can)")
	for id in extras:
		arena.players.leave(id)

	print("--- a quiz game: questions from the database, scores saved")
	game.picker.round_types = [QuizRound]
	game.start_game()
	var gid := game.game_id
	check(gid > 0, "game %d in the database" % gid)
	await _until(func(): return game.state == GameManager.State.PLAYING)
	var quiz: QuizRound = game.current
	check(quiz._questions.all(func(q): return str(q.id).begins_with("db_q")), "quiz uses the database questions")
	print("--- answer streak: (here) 2 right in a row = +1 life; the 1st right answer was earlier")
	game.streak_bonus = 2
	game.streaks[3] = 1
	var anna_lives: int = arena.tiles[2].health
	await _until(func(): return quiz._phase == "question")
	var right := int(quiz._questions[quiz._index].correct)
	arena.tiles[2].press_button(QuizRound.ANSWER_BUTTONS[(right + 1) % 4])   # wrong first ...
	await _wait(0.5)
	check(quiz._phase == "question", "no reveal before the time is up")
	arena.tiles[2].press_button(QuizRound.ANSWER_BUTTONS[right])             # ... changed: the last counts
	await _until(func(): return quiz._phase == "reveal")
	check(quiz._questions.size() == 1, "a quiz round is one question")
	check(game.streaks[3] == 2, "Anna: 2 right in a row")
	# Bram is exterminated during the round
	arena.tiles[bram_tile - 1].health = 1
	arena.robot_attack([bram_tile])
	await _until(func(): return not arena.players.is_playing(bram_tile), 60.0)
	check(not arena.players.is_playing(bram_tile), "Bram exterminated, tile free")
	game.skip()                                     # end the round
	await _until(func(): return game.views.lives_shown and not arena.attacks_busy())   # (on the scoreboard)
	await _wait(1.0)
	check(arena.tiles[2].health == anna_lives + 1,
		"streak: Anna +1 life at the end of the round (%d -> %d)" % [anna_lives, arena.tiles[2].health])
	game.stop_game()                                # end the game: Anna's result with her rank
	check(game.state == GameManager.State.LOBBY, "game stopped, back to the lobby")

	var rounds := db.select("SELECT * FROM round_scores WHERE game_id = ?", [gid])
	var results := db.select("SELECT * FROM results WHERE game_id = ? ORDER BY tile", [gid])
	var games := db.select("SELECT * FROM games WHERE id = ?", [gid])
	print("    round_scores: ", rounds.map(func(r): return [r.round_type, r.tile, r.points, r.score, r.lives]))
	print("    results:      ", results.map(func(r): return [r.name, r.score, r.lives, r.exterminated, r.rank]))
	check(rounds.all(func(r): return r.round_type == "quiz" and r.points == 0)
		and rounds.any(func(r): return r.player_id == anna),
		"quiz round scores saved (one per question, no points)")
	var r_anna := results.filter(func(r): return r.player_id == anna)
	var r_bram := results.filter(func(r): return r.player_id == bram)
	check(r_anna.size() == 1 and r_anna[0].rank == 1 and r_anna[0].exterminated == 0, "Anna: rank 1")
	check(r_bram.size() == 1 and r_bram[0].exterminated == 1 and r_bram[0].rank == null and r_bram[0].lives == 0,
		"Bram: exterminated, no rank")
	check(games.size() == 1 and games[0].ended_at != null, "game marked as ended")

	print("--- overall ranking: most rounds survived in one play, live while playing")
	for r in [[anna, "Anna", 50], [anna, "Anna", 30], [bram, "Bram", 40]]:
		db.save_result(gid, {"player_id": r[0], "tile": 1, "name": r[1], "score": r[2], "lives": 0,
			"exterminated": true})
	game.standings.load_records()
	var board := db.leaderboard()
	print("    leaderboard: ", board.map(func(r): return [r.name, r.best, r.plays]))
	check(board[0].player_id == anna and board[0].best == 50 and board[0].plays == 3,
		"Anna first with her record (50 rounds), 3 plays")
	check(board[1].player_id == bram and board[1].best == 40, "Bram second (40)")
	arena.players.join(4, "Bram", 7, bram)                  # Bram plays again ...
	arena.players.join(6, "Anna", 12, anna)
	game.survived[4] = 60                           # ... and is doing better than ever
	game.survived[6] = 10
	game.scores[4] = 0
	game.scores[6] = 0
	check(game.standings.rank(4) == 1 and game.standings.rank(6) == 2, "live: Bram #1 with 60, Anna #2 (her record 50)")
	check(game.standings.record(4) == 60 and game.standings.record(6) == 50,
		"record = most rounds survived, this play included")
	var rows := game._ranking({})
	check(rows[0].tile == 4 and rows[0].rank == 1 and rows[0].record == 60, "scoreboard rows carry record and rank")
	arena.players.join(9, "Gast", 10)                       # joined without the app
	check(game.standings.rank(9) == 0, "a player without a database id is not ranked")

	print("--- tie-breakers: equal rounds survived -> more lives left -> more points")
	var cleo := db.add_player("Cleo", "#aa00ff", 9)
	var daan := db.add_player("Daan", "#88ff00", 10)
	arena.players.join(2, "Cleo", 9, cleo)
	arena.players.join(3, "Daan", 10, daan)
	game.survived[2] = 60                           # the same rounds as Bram ...
	game.survived[3] = 60
	arena.tiles[3].health = 3                       # Bram 3 lives, Cleo the same, Daan one less
	arena.tiles[1].health = 3
	arena.tiles[2].health = 2
	game.scores[2] = 25                             # Cleo more points than Bram
	game.scores[3] = 99
	print("    ", game.standings.ranking().map(func(r): return [r.name, r.best, r.lives, r.points]))
	check(game.standings.rank(2) == 1 and game.standings.rank(4) == 2,
		"60 rounds, the same lives: Cleo (25 points) before Bram (0 points)")
	check(game.standings.rank(3) == 3, "60 rounds, one life less: Daan third (his 99 points don't count first)")
	game.scores[2] = 0
	check(game.standings.rank(2) == 1 and game.standings.rank(4) == 1, "all three equal: Cleo and Bram share #1")
	for r in [[cleo, 5, 3], [daan, 5, 1]]:                    # saved plays: the database's ranking the same way
		var g2 := db.start_game()
		db.save_round(g2, 1, "quiz", [{"player_id": r[0], "tile": 1, "points": 7, "score": 5, "lives": r[2]}])
		db.save_result(g2, {"player_id": r[0], "tile": 1, "name": "x", "score": r[1], "lives": r[2], "exterminated": false})
	var lb := db.leaderboard().filter(func(r): return r.player_id in [cleo, daan])
	check(lb.size() == 2 and lb[0].player_id == cleo and lb[0].lives == 3 and lb[0].points == 7,
		"the database's ranking: 5 rounds both, Cleo (3 lives) before Daan (1)")

	print("\nDONE: %d failure(s)" % failures)
	get_tree().quit(1 if failures else 0)


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		failures += 1


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _until(cond: Callable, timeout := 120.0) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()
	if t >= timeout:
		check(false, "timed out waiting")
