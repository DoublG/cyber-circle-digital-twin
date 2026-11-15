extends Node
## The closing time in the game (headless): the control server's phases
## (MQTT `closing`) - before the last entry players join as always; after it
## nobody new (register / join refused), the players in it play on, the free
## tiles show GESLOTEN with the time, the intro says it, the state has it.
## Run: godot --headless --path . --fixed-fps 60 res://tests/test_closing.tscn

const ARENA := preload("res://scenes/arena.tscn")

var failures := 0


func _ready() -> void:
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")
	game.intro_time = 1.0
	game.auto_start_delay = 0.0
	var modes := game.modes
	arena.players.join(1, "Noor", 12)
	arena.players.join(2, "Lars", 12)
	await _wait(0.3)

	modes.set_closing({"phase": "open", "close_at": "18:00", "last_entry_at": "17:45"})
	check(modes.accepting_players() and modes.closing_line() == "", "before the last entry: as always")
	check(arena.players.register(3, "Zoë", Color.RED, 10) == 3, "a new player is invited")
	arena.players.leave(3)

	modes.set_closing({"phase": "last_entry", "close_at": "18:00", "last_entry_at": "17:45"})
	check(not modes.accepting_players(), "after the last entry: nobody new")
	check(arena.players.register(3, "Zoë", Color.RED, 10) == 0, "... an invite refused")
	check(game.status().closing_time.phase == "last_entry", "the state says it (closing_time, for the apps)")
	var slot: TileSlot = arena.screen_wall._tile_slot(5)
	check(slot.mode == "closed" and slot.closed_text.contains("18:00"), "a free tile: GESLOTEN - het spel sluit om 18:00")
	slot.free()
	check(game.replica_fields().closing.phase == "last_entry", "the display nodes get it too")

	game.picker.random_rounds = false
	game.picker.round_types = [ReactionRound]
	game.start_game()
	await _until(func(): return game.state == GameManager.State.INTRO)
	check(game.current.rules.contains("Het spel sluit om 18:00"), "the intro says it")
	check(arena.players.is_playing(1) and arena.players.is_playing(2), "the players in it play on")

	modes.set_closing({"phase": "none"})
	check(modes.accepting_players(), "no time (opened again after it): as always")

	print("DONE: %d failure(s)" % failures)
	get_tree().quit(1 if failures else 0)


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		failures += 1


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _until(cond: Callable, timeout := 30.0) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()
