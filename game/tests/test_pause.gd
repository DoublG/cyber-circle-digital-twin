extends Node
## The operator's pause freezes the game's timed steps too: the UITSLAG board,
## the scoreboard's lives change and the time to the next round stand still
## until the game is open again (they used to run on behind the pause).
## Run: godot --headless --path . --fixed-fps 60 res://tests/test_pause.tscn

const ARENA := preload("res://scenes/arena.tscn")

var arena: Arena
var game: GameManager
var failures := 0


func _ready() -> void:
	arena = ARENA.instantiate()
	add_child(arena)
	game = arena.game
	game.use_database("")
	_run()


func _run() -> void:
	await _wait(0.5)
	for id in [1, 2, 3, 4]:
		arena.players.join(id, "Speler %d" % id)
	game.settings.apply({"reaction": {"duration": 3}})
	game.intro_time = 1.0
	game.result_time = 2.0
	game.lives_delay = 1.0
	game.scoreboard_time = 2.0
	game.picker.random_rounds = false
	game.picker.round_types = [ReactionRound]
	game.start_game()
	await _until(func(): return game.state == GameManager.State.SCOREBOARD)

	print("--- paused on the UITSLAG board: it stays")
	check(game.status().uitslag, "the round's places are shown (UITSLAG)")
	game.set_mode(GameManager.Mode.PAUSED)
	await _wait(4.0)                          # (longer than result_time + lives_delay)
	check(game.status().uitslag, "paused 4 s: still the UITSLAG board")
	check(not game._lives_shown, "paused: the lives have not changed")
	game.set_mode(GameManager.Mode.OPEN)
	await _until(func(): return not game.status().uitslag, 10.0)

	print("--- paused on the scoreboard, before the lives change: they wait")
	check(not game._lives_shown, "the scoreboard: the lives as they were")
	game.set_mode(GameManager.Mode.PAUSED)
	await _wait(4.0)                          # (longer than lives_delay + scoreboard_time)
	check(not game._lives_shown, "paused 4 s: the lives have not changed")
	check(game.state == GameManager.State.SCOREBOARD and game.round_number == 1, "paused: no next round")
	game.set_mode(GameManager.Mode.OPEN)
	await _until(func(): return game._lives_shown, 10.0)
	check(game._lives_shown, "open again: the lives change")
	await _until(func(): return game.state == GameManager.State.INTRO, 10.0)
	check(game.round_number == 2, "... and the next round comes")
	print("DONE: %d failure(s)" % failures)
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
