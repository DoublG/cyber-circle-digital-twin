extends Node
## Ages (headless): AgeFit; the randomizer picks a round type whose age range
## (min_age / max_age, operator settings) does not suit the players less often;
## the quiz picks questions for the players' ages more often; in a personal
## round a player younger than its min_age gets a shield and the last place
## costs them no life (the others still lose one).
## Run: godot --headless --path . --fixed-fps 60 res://tests/test_ages.tscn

const ARENA := preload("res://scenes/arena.tscn")

var failures := 0


func _ready() -> void:
	print("--- AgeFit")
	check(AgeFit.fit(10, 8, 12) == 1.0, "inside the range: 1")
	check(is_equal_approx(AgeFit.fit(6, 10, 99), AgeFit.LOWEST), "4 years too young: the lowest (%.2f)" % AgeFit.fit(6, 10, 99))
	check(AgeFit.fit(9, 10, 99) < 1.0 and AgeFit.fit(9, 10, 99) > AgeFit.fit(8, 10, 99), "less the further outside")
	check(AgeFit.fit(16, 8, 12) < 1.0, "too old: less too")
	check(AgeFit.fit(0, 12, 16) == 1.0 and AgeFit.group([0, 0], 12, 16) == 1.0, "age unknown: 1")
	check(is_equal_approx(AgeFit.group([8, 12, 0], 10, 99), (AgeFit.fit(8, 10, 99) + 1.0) / 2.0), "group: the average of the known")
	check(AgeFit.factor([6], 10, 99, 0.0) == 1.0, "steer 0: off")

	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")
	game.intro_time = 1.0
	game.scoreboard_time = 1.0
	game.result_time = 0.5
	game.auto_start_delay = 0.0
	var ages := {1: 8, 2: 14, 5: 14, 9: 14}
	for id in ages:
		arena.players.join(id, "P%d" % id, ages[id])
	await _wait(0.3)

	print("--- the randomizer")
	var schema: Array = game.settings.schema()
	var code_items: Array = schema.filter(func(g): return g.group == "code")[0].items
	check(code_items.any(func(t): return t.key == "min_age") and code_items.any(func(t): return t.key == "max_age"),
		"every personal round type has min_age / max_age settings")
	var quiz_items: Array = schema.filter(func(g): return g.group == "quiz")[0].items
	check(not quiz_items.any(func(t): return t.key == "min_age"), "... the quiz not (its questions have them)")
	var before: float = game.picker.round_chances(null)[CodeRound]
	game.settings.apply({"code": {"min_age": 18}})
	var after: float = game.picker.round_chances(null)[CodeRound]
	check(after < before * 0.5, "code for 18+ with players of 8 and 14: much less often (%.3f -> %.3f)" % [before, after])
	game.settings.apply({"code": {"min_age": 18}, "randomizer": {"age_steer": 0}})
	check(is_equal_approx(game.picker.round_chances(null)[CodeRound], before), "age steering off: as before")
	game.settings.apply({"code": {"max_age": 10}})
	check(game.picker.round_chances(null)[CodeRound] < before, "code up to 10: less often with players of 14")

	print("--- the questions")
	game.settings.apply({})
	var young := {"id": "y", "category": "A", "min_age": 8, "max_age": 10}
	var old := {"id": "o", "category": "A", "min_age": 14, "max_age": 16}
	var n_young := 0
	for i in 2000:
		if game.questions.pick_question([young, old], [8, 9]).id == "y":
			n_young += 1
	check(n_young > 1500, "players of 8 and 9: the question for 8-10 much more often (%d of 2000)" % n_young)
	n_young = 0
	for i in 2000:
		if game.questions.pick_question([young, old], [15, 16]).id == "y":
			n_young += 1
	check(n_young < 500, "players of 15 and 16: the question for 14-16 much more often (%d of 2000 the other)" % n_young)
	var ch := game.questions.category_chances([young, {"id": "o2", "category": "B", "min_age": 14, "max_age": 16}], [8, 9])
	check(ch.A > ch.B * 2.0, "the category with questions for their age too (%.2f vs %.2f)" % [ch.A, ch.B])
	game.settings.apply({"questions": {"age_steer": 0}})
	ch = game.questions.category_chances([young, {"id": "o2", "category": "B", "min_age": 14, "max_age": 16}], [8, 9])
	check(is_equal_approx(ch.A, ch.B), "age steering off: equal")

	print("--- a personal round: the shield")
	game.settings.apply({"reaction": {"min_age": 10}})
	game.picker.random_rounds = false
	game.picker.round_types = [ReactionRound]
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	var r: ReactionRound = game.current
	check(r.min_age == 10, "the round has the operator's min_age")
	check(r.is_protected(1) and arena.tiles[0].shielded, "P1 (8): protected, shield on the tile")
	check(not r.is_protected(2) and not arena.tiles[1].shielded, "P2 (14): not")
	r.stats[1].best_streak = 0
	r.stats[2].best_streak = 5
	r.stats[5].best_streak = 3
	r.stats[9].best_streak = 0
	var hearts := {1: arena.tiles[0].health, 9: arena.tiles[8].health}
	game.skip()
	await _until(func(): return game.state == GameManager.State.SCOREBOARD)
	var plan: Dictionary = game._pending_lives
	print("    lives: ", plan)
	check(plan.get(1, 0) == 0, "P1 last but shielded: no life lost")
	check(plan.get(9, 0) == -1, "P9 last too, not protected: -1")
	check(plan.get(2, 0) == 1, "P2 first: +1")
	check(not arena.tiles[0].shielded, "the shield is off after the round")
	await _until(func(): return game.state == GameManager.State.INTRO, 20.0)
	check(arena.tiles[0].health == hearts[1] and arena.tiles[8].health == hearts[9] - 1,
		"hearts: P1 %d -> %d, P9 %d -> %d" % [hearts[1], arena.tiles[0].health, hearts[9], arena.tiles[8].health])

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
