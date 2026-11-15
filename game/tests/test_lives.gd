extends Node
## Life table (headless): who gains / loses a life at the end of a round - by
## the number of players a row: the best / last N places or the best / worst
## N % of the players (one table for all games, a game can have its own),
## equal players together, shields still block a -1;
## the rules text says other settings; a round type that can win no life
## counts as such for the randomizer's director; the quiz has none.
## Run: godot --headless --path . --fixed-fps 60 res://tests/test_lives.tscn

const ARENA := preload("res://scenes/arena.tscn")

var failures := 0


func _ready() -> void:
	print("--- the cut-off (places: tile -> place)")
	var p := {1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 7, 8: 8}
	check(_ids(GameRound._cut(p, 1, 0, true)) == [1], "best 1 place: the 1st")
	check(_ids(GameRound._cut(p, 3, 0, true)) == [1, 2, 3], "best 3 places")
	check(_ids(GameRound._cut(p, 1, 0, false)) == [8], "last place")
	check(_ids(GameRound._cut(p, 2, 0, false)) == [7, 8], "last 2 places")
	check(_ids(GameRound._cut(p, 0, 0, false)) == [], "0 places: nobody")
	check(_ids(GameRound._cut(p, 1, 50, false)) == [5, 6, 7, 8], "worst 50 %: the bottom half")
	check(_ids(GameRound._cut(p, 1, 25, false)) == [7, 8], "worst 25 %: half of the bottom half")
	check(_ids(GameRound._cut(p, 1, 25, true)) == [1, 2], "best 25 %")
	check(_ids(GameRound._cut({1: 1, 2: 2, 3: 3}, 0, 10, false)) == [3], "a % is at least 1 player")
	var tied := {1: 1, 2: 2, 3: 3, 4: 3, 5: 3}
	check(_ids(GameRound._cut(tied, 1, 20, false)) == [3, 4, 5], "equal at the cut-off: all of them")
	check(_ids(GameRound._cut(tied, 2, 0, false)) == [2, 3, 4, 5], "last 2 places with equals")

	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")
	game.intro_time = 1.0
	game.scoreboard_time = 1.0
	game.result_time = 0.5
	game.auto_start_delay = 0.0
	var ages := {1: 8, 2: 14, 3: 14, 4: 14, 5: 14, 6: 14, 7: 14, 8: 14}
	for id in ages:
		arena.players.join(id, "P%d" % id, ages[id])
	await _wait(0.3)

	print("--- the life table: by the number of players")
	var st := game.settings
	check(st.life_rule("reaction", 8) == GameSettings.LIFE_ROW, "no table: 1st +1, last -1")
	st.apply({"life_tables": {"all": [
		{"from": 9, "win_percent": 20, "lose_percent": 25},
		{"from": 1, "win_places": 1, "lose_places": 1},
		{"from": 5, "win_places": 2, "lose_places": 1, "bogus": 3},
		{"from": 0, "win_places": 99}], "reaction": [{"from": 1, "win_places": 0, "lose_places": 2}], "x": []}})
	print("    ", st.life_tables)
	check(st.life_tables.all.map(func(r): return r.from) == [1, 5, 9], "rows sorted by 'from', one per 'from' (0 -> 1)")
	check(st.life_tables.all[0].win_places == 13, "values within their limits (99 -> 13)")
	check(not st.life_tables.has("x"), "a table without rows: left out")
	check(st.life_rule("simon", 3).win_places == 13, "Simon, 3 players: the row from 1")
	check(st.life_rule("simon", 5).win_places == 2 and st.life_rule("simon", 8).win_places == 2, "5 - 8 players: from 5")
	check(st.life_rule("simon", 13).win_percent == 20 and st.life_rule("simon", 13).lose_percent == 25,
		"13 players: from 9 (best 20 %, worst 25 %)")
	check(st.life_rule("reaction", 13).lose_places == 2, "Reactie: its own table")
	check(st.of_round("reaction").is_empty(), "(no per-game life settings any more)")
	var items: Array = st.schema().filter(func(g): return g.group == "reaction")[0].items
	check(not items.any(func(t): return t.key.begins_with("win_") or t.key.begins_with("lose_")),
		"the game's settings: no life fields (the table)")

	var r := ReactionRound.new()
	r.adapt_rules()
	check(r.rules.contains("langste reeks treffers +1 leven"), "default: the round's own rules text")
	r.set_life_rule({"from": 1, "win_places": 2, "win_percent": 0, "lose_places": 1, "lose_percent": 50})
	r.adapt_rules()
	print("    ", r.rules.split("\n")[-1])
	check(r.rules.contains("Na de ronde: de beste 2 plaatsen +1 leven, de laatste 50% van de spelers -1 leven."),
		"other rules: the rules text says them")
	check(r.rules.count("Na de ronde:") == 1, "... once")

	print("--- the director")
	check(not game.picker.gives_lives(ReactionRound), "Reactie's table: nobody +1 - it cannot win a life")
	check(game.picker.gives_lives(SimonRound), "Simon (the table for all) can")
	check(not game.picker.gives_lives(QuizRound), "the quiz: not (only the streak)")

	print("--- a round with 8 players: the row from 5 ... from 8: best 25 %, worst 50 %; P1 (8) shielded")
	st.apply({"reaction": {"min_age": 10}, "life_tables": {"all": [
		{"from": 1, "win_places": 1, "lose_places": 1},
		{"from": 8, "win_percent": 25, "lose_percent": 50},
		{"from": 10, "win_places": 3, "lose_places": 3}]}})
	game.picker.random_rounds = false
	game.picker.round_types = [ReactionRound]
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	var rr: ReactionRound = game.current
	check(rr.win_percent == 25 and rr.lose_percent == 50, "8 players: the row from 8")
	check(rr.rules.contains("de beste 25% van de spelers +1 leven"), "... and its rules say so")
	var streak := {1: 0, 2: 9, 3: 8, 4: 7, 5: 6, 6: 5, 7: 4, 8: 4}   # P7 and P8 equal last
	for id in streak:
		rr.stats[id].best_streak = streak[id]
	game.skip()
	await _until(func(): return game.state == GameManager.State.SCOREBOARD)
	var plan: Dictionary = game._pending_lives
	print("    lives: ", plan)
	check(plan.get(2, 0) == 1 and plan.get(3, 0) == 1, "P2, P3: the best 25 %: +1")
	check(plan.get(4, 0) == 0 and plan.get(5, 0) == 0, "P4, P5: in the middle: 0")
	check(plan.get(6, 0) == -1 and plan.get(7, 0) == -1 and plan.get(8, 0) == -1,
		"P6, P7, P8 (P7 = P8): in the worst half (4 of 8, with P1): -1")
	check(plan.get(1, 0) == 0, "P1 last but shielded: 0")

	print("DONE: %d failure(s)" % failures)
	get_tree().quit(1 if failures else 0)


func _ids(a: Array) -> Array:
	var out := a.duplicate()
	out.sort()
	return out


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
