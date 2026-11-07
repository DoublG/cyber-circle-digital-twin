extends Node
## Settings (headless): the schema per group, values clamped to their range,
## the game ones at once, a round type's from its next round, the tempo
## shortening every time, back to the defaults with {}.
## Run: godot --headless --path . --fixed-fps 60 res://tests/test_settings.tscn

const ARENA := preload("res://scenes/arena.tscn")

var failures := 0


func _ready() -> void:
	var arena: Node3D = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")
	game.auto_start_delay = 0.0
	game.random_rounds = false
	game.round_types = [QuizRound, CycloneRound]
	var schema := game.settings_schema()
	var groups: Array = schema.map(func(g): return g.group)
	print("    groups: ", groups)
	check(groups == ["game", "cyclone", "quiz", "reaction", "rhythm", "simon", "zwarte_piet", "randomizer", "questions", "sound", "light", "voice"], "a group for the game and every round type")
	var quiz_items: Array = schema[2].items
	var qt: Dictionary = quiz_items.filter(func(t): return t.key == "question_time")[0]
	check(qt.default == 15.0 and qt.value == 15.0 and qt.unit == "s", "quiz answer time: default 15 s")

	game.apply_settings({"game": {"tempo": 2.0, "scoreboard_time": 99999, "queue_length": 2, "streak_bonus": 4},
		"quiz": {"question_time": 20, "reveal_time": 8, "bogus": 3},
		"cyclone": {"points_miss": -4, "light_speed": 1.5}, "nonsense": {"x": 1}})
	check(game.tempo == 2.0 and game.streak_bonus == 4, "game settings at once")
	check(game.scoreboard_time == 30.0, "clamped to the range (scoreboard max 30 s)")
	check(game.upcoming.size() == 2, "shorter round queue")
	check(not game.settings.has("nonsense") and not game.settings.quiz.has("bogus"), "unknown groups / keys ignored")
	qt = game.settings_schema()[2].items.filter(func(t): return t.key == "question_time")[0]
	check(qt.value == 20.0 and qt.default == 15.0, "schema shows value and default")

	arena.join(1, "Anna", 10)
	arena.join(2, "Bram", 10)
	game.start_game()
	await _until(func(): return game.state == GameManager.State.INTRO)
	var quiz: QuizRound = game.current
	check(is_equal_approx(quiz.question_time, 10.0), "quiz: 20 s answer time at tempo 2 = 10 s (%s)" % quiz.question_time)
	check(is_equal_approx(quiz.reveal_time, 4.0), "quiz: 8 s reveal at tempo 2 = 4 s")
	check("4 juiste antwoorden" in quiz.rules, "rules text follows the settings")
	check(is_equal_approx(game._timer, 3.5), "intro 7 s at tempo 2 = 3.5 s")
	game.skip()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	game.skip()
	await _until(func(): return game.state == GameManager.State.SCOREBOARD and game._timer < 1000.0)
	check(game._timer <= 15.0 and game._timer > 13.0, "scoreboard (30 s) at tempo 2 = 15 s (after the lives)")
	game.skip()
	await _until(func(): return game.state == GameManager.State.INTRO and game.current is CycloneRound)
	var cyc: CycloneRound = game.current
	check(cyc.points_miss == -4 and is_equal_approx(cyc.duration, 20.0), "cyclone: -4 per miss, 40 s at tempo 2 = 20 s")
	check(is_equal_approx(float(cyc.program.levels[0].speed), 21.0), "cyclone: light 1.5x as fast in the program")

	var events := [&"charge", &"attack", &"hit", &"shield", &"death", &"zap", &"explosion", &"life",
		&"round_start", &"scoreboard", &"join", &"random", &"quiz_right", &"quiz_wrong", &"countdown", &"time_up",
		&"ranking", &"drone_hum", &"music_lobby", &"music_ritme"]
	check(events.all(func(e): return arena.sound.has_sounds(e)), "sounds for every event (data/sounds/)")
	check(arena.sound._sounds[&"random"].size() >= 5, "5+ random sounds (%d)" % arena.sound._sounds[&"random"].size())
	game.apply_settings({"sound": {"volume": 30, "random_min": 1, "random_max": 2}})
	check(arena.sound.volume == 30 and arena.sound.random_min == 5.0, "sound settings (clamped: min 5 s)")
	game.apply_settings({})
	check(game.tempo == 1.0 and game.scoreboard_time == 8.0 and game.streak_bonus == 10 and game.queue_length == 3 and arena.sound.volume == 80,
		"{} = all defaults again")

	print("--- randomizer: weights, drought protection, director")
	game.stop_game()
	game.random_rounds = true
	game.round_types = GameManager.ROUND_TYPES
	for id in [3, 4, 5, 6, 7]:
		arena.join(id, "Extra %d" % id, 10)
	print("    players: ", arena.player_ids())
	var quiz_t: Script = QuizRound
	var ch := game.round_chances(null)
	print("    chances: ", _names(game, ch))
	check(ch.size() == 6 and is_equal_approx(ch.values().reduce(func(a, b): return a + b, 0.0), 1.0), "6 types, chances add up to 1")
	game.apply_settings({"randomizer": {"weight_quiz": 0}})
	var picks := {}
	for n in 300:
		var t := game._pick_round_type(null, 0)
		picks[t] = picks.get(t, 0) + 1
	check(not picks.has(quiz_t) and picks.size() == 5, "weight 0: never a quiz")
	game.apply_settings({"randomizer": {"mercy": 0}})
	game._history.assign([CycloneRound, SimonRound, ReactionRound, ZwartePietRound, CycloneRound, SimonRound])
	game.upcoming.clear()
	var dry := game.round_chances(SimonRound)
	print("    after a long time without a quiz: ", _names(game, dry))
	check(dry[quiz_t] > 0.45, "drought: a long-missed quiz gets a big chance (%.2f)" % dry[quiz_t])
	check(not dry.has(SimonRound), "never the same type twice in a row")
	game.apply_settings({})
	game._history.clear()
	game.upcoming.clear()
	for id in arena.player_ids():
		arena.tiles[id - 1].health = arena.tiles[id - 1].max_health
	var healthy: float = game.round_chances(null)[quiz_t]
	for id in arena.player_ids():
		arena.tiles[id - 1].health = 1
	var low: float = game.round_chances(null)[quiz_t]
	print("    quiz chance: everyone healthy %.2f, everyone on 1 life %.2f" % [healthy, low])
	check(healthy > 0.4 and low < healthy / 3.0, "director: lives low -> hardly a quiz; all healthy -> more quiz")
	game._plan_rounds()
	check(game.planned_rounds().all(func(e): return e.has("chance")), "the plan shows each round's chance")

	print("--- questions: category weights, drought protection, no early repeats")
	game.db = null                                    # the JSON questions: 3 categories
	var qg: Dictionary = game.settings_schema().filter(func(g): return g.group == "questions")[0]
	var keys: Array = qg.items.map(func(t): return t.key)
	print("    ", keys)
	check(keys == ["category_drought", "cat:Computers", "cat:Online veiligheid", "cat:Programmeren"], "a weight per category")
	game.question_memory = {"count": 0, "since": {}, "asked": {}}   # (the quiz played above)
	var qr := QuizRound.new()
	qr.game = game
	var seen := {}
	var cats := {}
	for r in 12:                                                  # (one question per round)
		for q in qr._pick_questions(game.all_questions()):
			seen[qr._qid(q)] = true
			cats[q.category] = cats.get(q.category, 0) + 1
	print("    12 questions over 12 rounds: ", cats)
	check(seen.size() == 12, "no question twice while there are unasked ones (14 questions)")
	check(cats.size() == 3 and cats.values().min() >= 2, "every category comes up (drought protection)")
	game.question_memory = {"count": 6, "since": {"Computers": 0, "Programmeren": 1, "Online veiligheid": 6}, "asked": {}}
	var cc := game.category_chances(game.all_questions())
	print("    after 6 questions without Online veiligheid: ", cc)
	check(cc["Online veiligheid"] > 0.6, "a long-missed category gets a big chance")
	game.apply_settings({"questions": {"cat:Programmeren": 0}})
	var prog := 0
	for r in 10:
		prog += qr._pick_questions(game.all_questions()).filter(func(q): return q.category == "Programmeren").size()
	check(prog == 0, "weight 0: no Programmeren questions")
	game.apply_settings({})
	check(game.category_weights.get("Programmeren", 1.0) == 1.0, "back to weight 1")
	print("DONE: %d failure(s)" % failures)
	get_tree().quit(failures)


func _names(game: GameManager, chances: Dictionary) -> Dictionary:
	var out := {}
	for t in chances:
		out[game.round_type_name(t)] = snappedf(chances[t], 0.01)
	return out


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		failures += 1


func _until(cond: Callable, timeout := 60.0) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()
