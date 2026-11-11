extends SceneTree
## The randomizer's steering (web interface: Spel › Randomizer): a game out of
## the randomizer is never drawn, a planned random slot with it is drawn again,
## the operator can still plan it; back in: its chance again.
##   godot-4 --headless --path godot --script res://tests/check_randomizer.gd
var fails := 0


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		fails += 1


func _init() -> void:
	var arena: Arena = load("res://scenes/arena.tscn").instantiate()
	root.add_child(arena)
	await process_frame
	var game: GameManager = arena.game
	game.use_database("")
	game.modes.change(GameManager.Mode.OPEN)
	for i in 6:
		arena.players.join(i + 1, "Speler %d" % (i + 1), 12)
	game.settings.apply({"randomizer": {"use_quiz": 0}})
	var quiz_seen := false
	for n in 60:                                   # draw the plan again and again
		game.picker.clear_planned()
		quiz_seen = quiz_seen or game.picker.upcoming.any(func(e): return RoundPicker.type_name(e.type) == "quiz")
	check(not quiz_seen, "quiz out: never drawn (60 plans)")
	var st: Dictionary = game.status().round_types.filter(func(t): return t.type == "quiz")[0]
	check(st.random == false and st.chance == 0.0, "status: quiz out, chance 0 (%s)" % st)
	check(game.picker.get_setting("use_quiz") == 0, "the setting reads back 0")
	game.picker.set_planned(0, "quiz")
	check(RoundPicker.type_name(game.picker.upcoming[0].type) == "quiz" and game.picker.upcoming[0].forced,
		"the operator can still plan it (a new game for a chosen audience)")
	game.settings.apply({"randomizer": {"use_quiz": 1}})
	game.picker.clear_planned()
	st = game.status().round_types.filter(func(t): return t.type == "quiz")[0]
	check(st.random == true and st.chance > 0.0, "back in: a chance again (%.0f %%)" % (st.chance * 100))
	var all_out := {}
	for t in RoundPicker.ROUND_TYPES:
		all_out["use_" + RoundPicker.type_name(t)] = 0
	game.settings.apply({"randomizer": all_out})
	game.picker.clear_planned()
	check(game.picker.upcoming.size() == game.picker.queue_length, "everything out: still a plan (any allowed game)")
	print("DONE: %d failure(s)" % fails)
	quit(1 if fails else 0)
