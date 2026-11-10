extends Node
## Exterminated is the end state: no new round for that player - and when
## everyone is exterminated, no new round at all: the scoreboard waits until
## their tiles are free (death animation, their clip), then the lobby.
## Run: godot --headless --path . --fixed-fps 60 res://tests/test_exterminated.tscn

const ARENA := preload("res://scenes/arena.tscn")

var arena: Arena
var game: GameManager
var failures := 0
var intros := 0


func _ready() -> void:
	arena = ARENA.instantiate()
	add_child(arena)
	game = arena.game
	game.use_database("")
	game.state_changed.connect(func(s):
		print("[state] ", GameManager.State.keys()[s], "  round=", game.round_number)
		if s == GameManager.State.INTRO:
			intros += 1)
	_run()


func _run() -> void:
	await _wait(0.5)
	print("--- two players (age unknown: never shielded), both on their last life")
	arena.apply_command({"tile": 1, "register": "Anna", "color": "#ff8800"})
	arena.apply_command({"tile": 2, "register": "Bram", "color": "#00ffcc"})
	await _wait(0.3)
	for id in [1, 2]:
		for b in CyberTile.BUTTONS:
			arena.tiles[id - 1].press_button(b)
			await _wait(0.2)
	await _wait(0.5)
	check(arena.players.player_ids() == [1, 2], "Anna and Bram playing")

	game.settings.apply({"quiz": {"question_time": 3, "read_time": 1}})
	game.intro_time = 1.0
	game.scoreboard_time = 1.0
	game.result_time = 0.0
	game.picker.random_rounds = false
	game.picker.round_types = [QuizRound]
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	for id in [1, 2]:
		arena.tiles[id - 1].health = 1
	print("--- nobody answers: both lose their last life")
	await _until(func(): return game.state == GameManager.State.SCOREBOARD)
	await _until(func(): return arena.tiles[0].is_dead and arena.tiles[1].is_dead, 30.0)
	check(arena.tiles[0].is_dead and arena.tiles[1].is_dead, "both exterminated")
	check(game._waiting_overlay(1).source.call() == "", "an exterminated player's view: no 'wait for the next round'")
	var intros_then := intros
	print("--- no new round: the scoreboard waits until the tiles are free, then the lobby")
	await _until(func(): return game.state == GameManager.State.LOBBY, 90.0)
	check(intros == intros_then,
		"no new round started after everyone was exterminated (%d intros)" % (intros - intros_then))
	check(game.state == GameManager.State.LOBBY and arena.players.player_ids().is_empty(),
		"back to the lobby, the tiles free")
	check(game.game_id == 0, "the game ended")
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
