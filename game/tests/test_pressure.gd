extends Node
## Busy (Pressure, headless): the gamemasters' switch and a full floor make the
## game harder one level per round (up to the highest level), back down after
## rounds that were not full, normal at once when switched off; full = the
## usable floor tiles taken (a broken one doesn't count, an invite does, the
## mobile players don't); what a level does: the director's help, the quiz's
## weight, the tempo, the streak bonus, the life rule (nobody +1, at least N %
## -1); a new player is protected (shield) for their first round; the rules say it.
## Run: godot --headless --path . --fixed-fps 60 res://tests/test_pressure.tscn

const ARENA := preload("res://scenes/arena.tscn")

var failures := 0


func _ready() -> void:
	print("--- the table and the rule (no arena)")
	var lv := Pressure.clean_levels([{"mercy": 500, "tempo": 10, "bogus": 1}, "x"])
	check(lv.size() == 3, "always 3 levels")
	check(lv[0].mercy == 100 and lv[0].tempo == 50, "values within their limits")
	check(lv[1] == Pressure.DEFAULT_LEVELS[1] and lv[2] == Pressure.DEFAULT_LEVELS[2], "missing rows: the defaults")

	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")
	game.intro_time = 1.0
	game.scoreboard_time = 1.0
	game.result_time = 0.5
	game.auto_start_delay = 0.0
	var pr := game.pressure
	for id in range(1, 14):
		arena.players.join(id, "P%d" % id, 14)
	await _wait(0.3)

	var rule := {"from_pct": 0, "win_places": 1, "win_percent": 0, "lose_places": 1, "lose_percent": 0}
	pr.level = 0
	check(pr.apply_to_rule(rule, 13) == rule, "level 0: the life table's rule as it is")
	pr.level = 2
	var r2 := pr.apply_to_rule(rule, 13)
	check(r2.win_places == 1 and r2.lose_percent == 25, "level 2: still +1 for the 1st, at least 25 % -1")
	check(pr.apply_to_rule({"from_pct": 0, "win_places": 1, "win_percent": 0, "lose_places": 5, "lose_percent": 0}, 13)
		.lose_percent == 0, "... the last 5 places of 13 (38 %) are more already: as they are")
	pr.level = 3
	var r3 := pr.apply_to_rule(rule, 13)
	check(r3.win_places == 0 and r3.win_percent == 0 and r3.lose_percent == 40, "level 3: nobody +1, at least 40 % -1")
	pr.level = 0

	print("--- the operator's settings")
	game.settings.apply({"game": {"grace_rounds": 2, "pressure_max": 9}, "pressure_levels": [{"tempo": 130}]})
	check(pr.grace_rounds == 2 and pr.pressure_max == 3, "the game settings (Spel: Druk ...), within their limits")
	check(pr.levels[0].tempo == 130 and pr.levels[0].mercy == 50, "the levels' table from the settings")
	game.settings.apply({})
	check(pr.grace_rounds == 1 and pr.levels == Pressure.DEFAULT_LEVELS, "{}: the defaults")

	print("--- full: the usable floor tiles taken")
	check(pr.occupancy() == {"usable": 13, "taken": 13} and pr.is_full(), "13 of 13: full")
	arena.players.leave(13)
	check(not pr.is_full(), "12 of 13: not full")
	pr.pressure_full_at = 90
	check(pr.is_full(), "... full from 90 %: full")
	pr.pressure_full_at = 100
	arena.installation.set_broken([13])
	check(pr.occupancy().usable == 12 and pr.is_full(), "T13 broken: 12 of 12 - full")
	arena.installation.set_broken([])
	arena.players.register(13, "Wacht", Color.RED, 14)
	check(arena.players.is_pending(13) and pr.is_full(), "an invite on T13: taken - full")
	arena.players.join(13, "P13", 14)
	arena.players.join(15, "Drone", 14)
	check(pr.occupancy().taken == 13, "a mobile player: not counted")
	arena.players.leave(15)

	print("--- the levels: one up per round while busy and full")
	pr.update()
	check(pr.level == 0, "not busy: normal")
	pr.set_busy(true, "Erik")
	check(pr.update() == 1 and pr.level == 1, "busy and full: level 1")
	pr.update()
	pr.update()
	check(pr.level == 3, "... 2, 3")
	pr.update()
	check(pr.level == 3, "... and no higher than 3")
	pr.pressure_max = 2
	pr.update()
	check(pr.level == 2, "highest level 2: 2")
	pr.pressure_max = 3
	arena.players.leave(13)
	pr.update()
	check(pr.level == 2, "not full for 1 round: stays (a tile comes free for a moment)")
	pr.update()
	check(pr.level == 1, "not full for 2 rounds: a level down")
	arena.players.join(13, "P13", 14)
	pr.update()
	check(pr.level == 2, "full again: up")
	pr.set_busy(false)
	check(pr.level == 0, "the gamemaster switches it off: normal at once")
	check(pr.status().busy == false and game.status().pressure.level == 0, "the game's state says it")

	print("--- what a level does")
	game.picker.random_rounds = true
	var quiz0: float = game.picker.round_chances(SimonRound)[QuizRound]
	var tempo0 := game.pace()
	pr.busy = true
	pr.level = 3
	var quiz3: float = game.picker.round_chances(SimonRound)[QuizRound]
	print("    the quiz's chance: %.2f -> %.2f" % [quiz0, quiz3])
	check(quiz3 > quiz0 + 0.1, "level 3: the quiz more often")
	game.picker.mercy = 1.0
	for id in [1, 2, 3, 4, 5, 6, 7, 8]:
		arena.tiles[id - 1].health = 1           # lives running out: the director helps ...
	pr.level = 0
	var low0: float = game.picker.round_chances(SimonRound)[QuizRound]
	pr.level = 1
	var low1: float = game.picker.round_chances(SimonRound)[QuizRound]
	print("    lives low, the quiz: %.2f -> %.2f" % [low0, low1])
	check(low1 > low0, "... level 1: half the help (the quiz less rare)")
	for id in [1, 2, 3, 4, 5, 6, 7, 8]:
		arena.tiles[id - 1].health = arena.tiles[id - 1].max_health
	pr.level = 3
	check(is_equal_approx(game.pace(), tempo0 * 1.2), "level 3: 20 % faster")
	check(not pr.streak_ok(), "no streak bonus")
	check(not game.picker.gives_lives(SimonRound), "the director: no round wins a life")
	var q := QuizRound.new()
	q.prepare(game, [])
	check(not q.rules.contains("op rij"), "the quiz's rules: no streak line")
	pr.level = 0
	q.prepare(game, [])
	check(q.rules.contains("op rij"), "... (normal: there)")

	print("--- a round at level 3, 13 players: by score - new: shielded, low: the normal rules, high: the level's")
	game.picker.random_rounds = false
	game.picker.round_types = [ReactionRound]
	pr.level = 2                                  # (the round's start: a level up -> 3)
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	var rr: ReactionRound = game.current
	check(pr.level == 3, "level 3")
	check(rr.win_places == 0 and rr.win_percent == 0 and rr.lose_percent == 40, "the round's rule")
	print("    ", rr.rules.split("\n")[-1])
	check(rr.rules.contains("DRUK (niveau 3)") and rr.rules.contains("nieuwe spelers 1 ronde beschermd"),
		"the rules say it")
	for id in range(1, 9):
		game.survived[id] = 10                    # P1 - P8: long in the game (high scores)
	for id in range(9, 13):
		game.survived[id] = 3                     # P9 - P12: low scores (3 < half of 10)
	game.survived[13] = 0                         # P13: just came from the line
	check(pr.eased(9) and not pr.eased(1) and pr.in_grace(13) and not pr.in_grace(9),
		"by score: P9 low (3 of the best's 10) - the normal rules; P1 high; P13 new")
	var ps: Dictionary = game.status().pressure
	check(ps.grace == [13] and ps.eased == [9, 10, 11, 12], "the state: who is new, who has the normal rules")
	var order := [9, 10, 11, 12, 13, 1, 2, 3, 4, 5, 6, 7, 8]      # places 1 .. 13: the high scores at the bottom
	for i in order.size():
		rr.stats[order[i]].best_streak = 30 - i
	game.skip()
	await _until(func(): return game.state == GameManager.State.SCOREBOARD)
	var plan: Dictionary = game._pending_lives
	print("    lives: ", plan)
	check(plan.get(9, 0) == 1, "P9 1st with a low score: the normal rule - +1 (nobody else wins at level 3)")
	check([1, 2, 3, 10, 11, 12].all(func(id): return plan.get(id, 0) == 0), "P10 - P12, P1 - P3: 0")
	check([4, 5, 6, 7, 8].all(func(id): return plan.get(id, 0) == -1), "P4 - P8 (high scores, the worst 40 %): -1")
	check(plan.get(13, 0) == 0, "P13 new: protected")
	check(pr.streak_ok(9) and not pr.streak_ok(1), "the quiz's streak bonus: still for a low score")
	pr.pressure_ease = 0
	check(not pr.eased(9), "Druk: gewone regels onder 0 %: off")
	pr.pressure_ease = 50

	print("DONE: %d failure(s)" % failures)
	get_tree().quit(1 if failures else 0)


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		failures += 1


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _until(cond: Callable, timeout := 60.0) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()
