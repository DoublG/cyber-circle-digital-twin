extends Node
## Right or wrong on the tile (headless): the success / error animation (as the
## first tiles had it) - at the quiz's reveal from the answer's quarter (no
## answer: from the robot side), and at the end of every other round (keeps or
## gains a life: success, loses one: error); sent to the real tiles as
## {"fx": "success" | "error", "from": icon}; the 3D tile shows it too.
## Run: godot --headless --path . --fixed-fps 60 res://tests/test_result.tscn

const ARENA := preload("res://scenes/arena.tscn")

var failures := 0
var sent := []                                    # [tile, name, data]


func _ready() -> void:
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")
	game.intro_time = 0.5
	game.scoreboard_time = 1.0
	game.result_time = 0.5
	game.auto_start_delay = 0.0
	for t in arena.tiles:
		t.fx.connect(func(id, name, _color, data): sent.append([id, name, data]))
	for id in [1, 2, 3]:
		arena.players.join(id, "P%d" % id, 14)
	await _wait(0.3)

	print("--- the quiz: right / wrong at the reveal, from the answer's quarter")
	game.picker.random_rounds = false
	game.picker.round_types = [QuizRound]
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING and game.current is QuizRound \
		and game.current._index >= 0 and game.current._phase == "question")
	var quiz: QuizRound = game.current
	var correct := int(quiz._questions[quiz._index].correct)
	var right_icon: StringName = QuizRound.ANSWER_BUTTONS[correct]
	var wrong_icon: StringName = QuizRound.ANSWER_BUTTONS[(correct + 1) % 4]
	arena.tiles[0].press_button(right_icon)          # P1 right
	arena.tiles[1].press_button(wrong_icon)          # P2 wrong, P3 no answer
	quiz._phase_left = 0.01
	await _until(func(): return _results().size() >= 3, 15.0)
	var r := _results()
	print("    ", r)
	check(r.has([1, "success", {"from": correct}]), "P1 right: success from the %s quarter" % right_icon)
	check(r.has([2, "error", {"from": (correct + 1) % 4}]), "P2 wrong: error from the %s quarter" % wrong_icon)
	check(r.has([3, "error", {"from": -1}]), "P3 no answer: error from the robot side")
	await _wait(0.2)
	var ring := arena.tiles[0].ring
	var q0: int = CyberTile.ICON_QUARTERS[right_icon]
	check(ring.colors[q0 + 3].g > 0.8 and ring.colors[(q0 + 30) % 48].v < 0.05,
		"the 3D tile: the answer's quarter green first, the rest still dark")
	await _wait(0.5)
	check(ring.colors[(q0 + 30) % 48].g > 0.5, "... then the green fills the ring")
	var at := sent.size()
	await _until(func(): return sent.slice(at).any(func(s): return s[1] in ["attack", "hit"]), 8.0)
	var first_attack := sent.slice(at).filter(func(s): return s[1] in ["attack", "hit"])
	check(not first_attack.is_empty(), "then the attacks (after the animation): %s" % [first_attack.slice(0, 1)])

	print("--- another round: at its end, keeps / gains a life: success, loses one: error")
	await _until(func(): return game.state == GameManager.State.LOBBY or game.state == GameManager.State.INTRO, 20.0)
	game.stop_game()
	await _wait(0.3)
	for id in [1, 2, 3]:
		arena.players.join(id, "P%d" % id, 14)
	sent.clear()
	game.picker.round_types = [ReactionRound]
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	var rr: ReactionRound = game.current
	for id in [1, 2, 3]:
		rr.stats[id].best_streak = [9, 5, 1][id - 1]     # P1 best, P3 last
	game.skip()
	await _until(func(): return game.state == GameManager.State.SCOREBOARD)
	await _wait(0.1)
	r = _results()
	print("    ", r)
	check(r.has([1, "success", {"from": -1}]) and r.has([2, "success", {"from": -1}]), "P1 (+1), P2 (0): success")
	check(r.has([3, "error", {"from": -1}]), "P3 last (-1): error")
	check(r.size() == 3, "once per player")

	print("DONE: %d failure(s)" % failures)
	get_tree().quit(1 if failures else 0)


func _results() -> Array:
	return sent.filter(func(s): return s[1] in ["success", "error"])


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
