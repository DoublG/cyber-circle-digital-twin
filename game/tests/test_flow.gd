extends Node
## Plays a full game without user input and logs what happens.
## Run: godot --headless --path . --fixed-fps 60 res://tests/test_flow.tscn

const ARENA := preload("res://scenes/arena.tscn")

var arena: Arena
var game: GameManager
var failures := 0


func _ready() -> void:
	arena = ARENA.instantiate()
	add_child(arena)
	game = arena.game
	game.use_database("")                 # this test: questions from JSON, nothing saved
	game.state_changed.connect(func(s): print("[state] ", GameManager.State.keys()[s],
		"  round=", game.round_number, " ", game.current.title if game.current else ""))
	arena.registered.connect(func(id, who, c): print("[registered] tile ", id, " ", who, " ", c.to_html(false)))
	arena.activated.connect(func(id, who): print("[activated] tile ", id, " ", who))
	arena.robot.hit_taken.connect(func(side): print("[robot hit] side ", side))
	arena.robot.death_finished.connect(func(side): print("[death] side ", side))
	_run()


func _run() -> void:
	await _wait(0.5)

	print("--- registration: 3 players scan the QR code at the same time")
	arena.apply_command({"tile": 1, "register": "Anna", "color": "#ff8800", "age": 12})
	arena.apply_command({"tile": 5, "register": "Bram", "color": "#00ffcc"})  # age unknown
	arena.apply_command({"register": "Cleo", "color": "#aa00ff", "age": 7})  # free tile chosen
	await _wait(0.5)
	check(arena.players.player_ids().is_empty(), "nobody playing before activation")
	var cleo_tile := 0
	for t in arena.tiles:
		if arena.players.is_pending(t.tile_id) and t.tile_id not in [1, 5]:
			cleo_tile = t.tile_id
	check(cleo_tile > 0, "Cleo got a free tile")

	print("--- activation: press all 4 icons (Anna, Bram); Cleo only presses 2")
	for id in [1, 5]:
		for b in CyberTile.BUTTONS:
			arena.tiles[id - 1].press_button(b)
			await _wait(0.25)
	for b in CyberTile.BUTTONS.slice(0, 2):
		arena.tiles[cleo_tile - 1].press_button(b)
		await _wait(0.25)
	await _wait(1.0)
	check(arena.players.player_ids() == [1, 5], "Anna and Bram active, Cleo still pending")
	check(arena.players.is_pending(cleo_tile), "Cleo pending")

	print("--- game start")
	game.intro_time = 2.0
	game.scoreboard_time = 2.0
	game.picker.random_rounds = false            # the 4 round types in order
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	check(game.current is CycloneRound, "round 1 is Cyclone")

	print("--- Cleo activates during the round: plays from the next round")
	for b in CyberTile.BUTTONS.slice(2, 4):
		arena.tiles[cleo_tile - 1].press_button(b)
		await _wait(0.25)
	check(arena.players.is_playing(cleo_tile), "Cleo active")
	check(cleo_tile not in game.current.players, "Cleo not in the current round")

	print("--- Cyclone: press when the green light is on the red LED (tile firmware)")
	var cyc: CycloneRound = game.current
	var fw_anna: TileFirmware = arena.tiles[0].get_node("Firmware")
	var fw_bram: TileFirmware = arena.tiles[4].get_node("Firmware")
	await _wait(0.2)
	var yellow_at_start := _yellow_leds(arena.tiles[0])
	check(yellow_at_start >= 7, "level 1: 4 yellow LEDs on each side of red (%d lit)" % yellow_at_start)
	# Anna presses exactly on red; Bram always 6 LEDs too late (outside the yellow)
	var cyc_t := 0.0
	while cyc_t < 15.0:
		if fw_anna._phase == "run" and fw_anna._offset() == 0:
			arena.tiles[0].press_button(&"Cross")
		if fw_bram._phase == "run" and fw_bram._offset() == 6:
			arena.tiles[4].press_button(&"Triangle")
		await get_tree().process_frame
		cyc_t += get_process_delta_time()
	print("    Anna level %d, Bram level %d" % [cyc.state[1].level + 1, cyc.state[5].level + 1])
	check(cyc.state[1].level >= 5, "Anna moved up to level %d" % (cyc.state[1].level + 1))
	check(cyc.state[5].level == 0, "Bram (all misses) stays on level 1")
	check(fw_anna._phase != "run" or _yellow_leds(arena.tiles[0]) < yellow_at_start, "Anna's yellow bands got smaller")
	check(cyc.points[1] > 0, "red scores points")
	var anna_best: int = cyc.state[1].best
	while not (fw_anna._phase == "run" and fw_anna._offset() == 6):   # Anna misses once
		await get_tree().process_frame
	arena.tiles[0].press_button(&"Cross")
	await _wait(0.3)
	check(cyc.state[1].level == 0 and cyc.state[1].best == anna_best,
		"a miss: Anna back to level 1 (best stays %d)" % (anna_best + 1))
	check(cyc.state[5].last == "ERNAAST" and cyc.points[5] < 0, "Bram's presses are misses (round points below 0)")
	print("    round points: ", game.current.points)
	await _until(func(): return game.state == GameManager.State.SCOREBOARD)
	print("    scores: ", game.scores)
	await _wait(0.2)
	var uitslag = game.screen_wall.shared_views[0]
	check(uitslag is RankingView, "after Cyclone first the UITSLAG (places, lives to gain / lose)")
	if uitslag is RankingView:
		var badges: Array = uitslag._badges.map(func(b): return b.text)
		check(badges.front() == "+♥" and badges.back() == "-♥", "UITSLAG: 1st +♥, last -♥: %s" % [badges])
	await _until(func(): return game.screen_wall.shared_views[0] is ScoreboardView)
	check(game.screen_wall.shared_views[0] is ScoreboardView, "then the scoreboard")

	await _until(func(): return game.state == GameManager.State.PLAYING)
	check(game.current is QuizRound, "round 2 is Quiz")
	check(arena.tiles[4].health == 4, "lowest Cyclone score (Bram) lost a life (%d)" % arena.tiles[4].health)
	check(arena.tiles[0].max_health == 4 and arena.tiles[0].health == 4, "Anna (12, 3 lives) won Cyclone: +1 life")
	check(arena.tiles[4].max_health == 5, "Bram (no age) has 5 lives")
	check(arena.tiles[cleo_tile - 1].max_health == 5, "Cleo (7) has 5 lives")
	check(cleo_tile in game.current.players, "Cleo plays in round 2")

	var quiz: QuizRound = game.current
	# a fixed question with a video (a quiz round is one question)
	var all: Array = JSON.parse_string(FileAccess.get_file_as_string(QuizRound.QUESTIONS_FILE))
	quiz._questions = [all.filter(func(q): return q.has("video"))[0]]
	quiz._stop_video()
	quiz._index = -1
	quiz._next_question()
	print("--- the question has a video: answering starts when it ends")
	check(quiz.is_protected(cleo_tile) and arena.tiles[cleo_tile - 1].shielded,
		"Cleo (7) is shielded on a 10+ question")
	check(not quiz.is_protected(1) and not quiz.is_protected(5), "Anna (12) and Bram (no age) are not")
	check(quiz._phase == "video" and quiz._video != null, "video plays before the question")
	arena.tiles[0].press_button(&"Square")
	check(quiz._answers.is_empty(), "answers ignored during the video")
	# video plays in real time, while --fixed-fps runs the game faster
	var deadline := Time.get_ticks_msec() + 20000
	while quiz._phase in ["video", "read"] and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	check(quiz._phase == "question" and quiz._video == null, "answering starts after the video")
	check(is_equal_approx(quiz._phase_left, 20.0) or quiz._phase_left > 19.0, "question uses its own time (20 s)")

	print("--- Anna right, Bram wrong, Cleo no answer (shielded)")
	arena.tiles[4].health = 2
	var correct := int(quiz._questions[quiz._index].correct)
	arena.tiles[0].press_button(QuizRound.ANSWER_BUTTONS[correct])
	arena.tiles[4].press_button(QuizRound.ANSWER_BUTTONS[(correct + 1) % 4])
	await _until(func(): return quiz._phase == "reveal")
	await _wait(4.0)
	check(arena.tiles[4].health == 2, "Bram wrong: no life lost yet (lives change on the scoreboard)")
	check(arena.tiles[cleo_tile - 1].health == 5, "Cleo's shield blocked the hit")
	check(quiz.points.values().all(func(p): return p == 0), "the quiz gives no points: %s" % quiz.points)
	game.scoreboard_time = 20.0          # keep the scores up while checking
	await _until(func(): return game.state == GameManager.State.SCOREBOARD, 60.0)
	await _wait(6.0)                     # the robot's attack at the end of the round
	check(game.state == GameManager.State.SCOREBOARD, "one question, then the scoreboard")
	check(arena.tiles[4].health == 1 and not arena.tiles[4].is_dead, "end of the quiz: Bram (wrong) -1 life")
	check(game.screen_wall.shared_views[0] is ScoreboardView, "after the quiz straight to the scoreboard (no UITSLAG)")
	check(arena.tiles[0].health == 4 and arena.tiles[cleo_tile - 1].health == 5,
		"Anna right, Cleo shielded: lives unchanged")
	check(game.survived[1] == 2 and game.survived[5] == 2 and game.survived[cleo_tile] == 1,
		"rounds survived: Anna 2, Bram 2, Cleo 1 (joined in round 2)")
	game.scoreboard_time = 2.0
	game.skip()                          # on to the next round

	print("--- round 3: reaction, run by the (simulated) tile firmware")
	await _until(func(): return game.current is ReactionRound and game.state == GameManager.State.PLAYING)
	var react: ReactionRound = game.current
	check(react.players.has(1) and react.players.has(cleo_tile), "Anna and Cleo play the reaction round")
	# bots: Anna reacts fast and avoids red; Cleo is slow and presses everything
	var bot := func(id: int, _i: int, step: Dictionary, fast: bool):
		await get_tree().create_timer(0.25 if fast else 0.6).timeout
		var b := StringName(step.button)
		if fast and step.nogo:
			b = &"Square"            # another icon: allowed on red
		arena.tiles[id - 1].press_button(b)
	for id in [1, cleo_tile]:
		var fw: TileFirmware = arena.tiles[id - 1].get_node("Firmware")
		fw.step_started.connect(func(tid, i, step): bot.call(tid, i, step, tid == 1))
	await _until(func(): return game.state == GameManager.State.SCOREBOARD)
	var steps: int = react.program.steps.size()
	var reds: int = react.program.steps.filter(func(s): return s.nogo).size()
	print("    %d steps (%d red), round points: %s, Anna best %d ms" % [steps, reds,
		react.points, react.stats[1].best_ms])
	check(react._results[1].size() == steps, "a result for every step (Anna)")
	check(react._results[1].values().all(func(o): return o in ["hit", "nogo_ok"]),
		"Anna: all hits / good waits %s" % react._results[1])
	check(reds == 0 or react._results[cleo_tile].values().has("nogo_fail"), "Cleo pressed red")
	check(react.points[1] > react.points[cleo_tile], "Anna beats Cleo")
	print("    longest runs: Anna %d, Cleo %d, Bram %d" % [react.stats[1].best_streak,
		react.stats[cleo_tile].best_streak, react.stats[5].best_streak])
	check(react.stats[1].best_streak == steps, "Anna: every step a success in a row")
	check(reds == 0 or react.stats[cleo_tile].best_streak < react.stats[1].best_streak, "Cleo's mistakes reset her run")
	print("--- Bram (no presses, 1 life) has the lowest score: exterminated, tile free again")
	await _until(func(): return arena.tiles[4].is_dead, 30.0)
	check(arena.tiles[4].is_dead, "Bram's tile blinks red / death animation")
	await _until(func(): return not arena.players.is_playing(5), 60.0)
	check(not arena.players.is_playing(5) and arena.tiles[4].idle and not arena.tiles[4].is_dead,
		"Bram exterminated, T05 free again")

	print("--- round 4: Simon, run by the (simulated) tile firmware")
	await _until(func(): return game.current is SimonRound and game.state == GameManager.State.PLAYING)
	var simon: SimonRound = game.current
	check(simon.program.sequence.all(func(s):
		return s.color == "#" + CyberTile.BUTTON_COLORS[StringName(s.button)].to_html(false)),
		"every icon keeps its own colour")
	# bots: Anna repeats every sequence; Cleo is fine up to level 4, then
	# presses a wrong icon once, after that lets the timer run out
	var cleo_tries := [0]
	var simon_bot := func(id: int, level: int, seq: Array):
		var wrong := id == cleo_tile and level >= 5
		if wrong:
			cleo_tries[0] += 1
			if cleo_tries[0] >= 2:
				return                       # too slow
		for i in seq.size():
			await get_tree().create_timer(0.3).timeout
			var b := StringName(seq[i].button)
			if wrong and i == 1:
				b = CyberTile.BUTTONS[(CyberTile.BUTTONS.find(b) + 1) % 4]
			arena.tiles[id - 1].press_button(b)
			if wrong and i == 1:
				return
	for id in [1, cleo_tile]:
		var fw: TileFirmware = arena.tiles[id - 1].get_node("Firmware")
		fw.simon_turn.connect(func(tid, level, seq): simon_bot.call(tid, level, seq))
	await _until(func(): return simon.state[cleo_tile].fails >= 2)
	check(simon.state[cleo_tile].level == simon.start_level and simon.state[cleo_tile].phase != "done",
		"a mistake: Cleo back to %d icons, still playing" % simon.start_level)
	check(simon.state[cleo_tile].best == 4, "Cleo's best: 4 icons")
	var lives_before := {1: arena.tiles[0].health, cleo_tile: arena.tiles[cleo_tile - 1].health}
	await _until(func(): return game.state == GameManager.State.SCOREBOARD)
	print("    Anna best level %d, round points: %s" % [simon.state[1].best, simon.points])
	check(simon.state[1].best >= 8, "Anna got far (level %d)" % simon.state[1].best)
	check(simon.points[1] > simon.points[cleo_tile], "Anna beats Cleo")
	check(not arena.tiles[0].get_node("Firmware")._running, "tiles stopped after the round")
	await _until(func(): return arena.tiles[cleo_tile - 1].health < lives_before[cleo_tile], 15.0)
	check(arena.tiles[0].health == mini(lives_before[1] + 1, 5), "1st place (Anna): +1 life")
	check(arena.tiles[cleo_tile - 1].health == lives_before[cleo_tile] - 1, "last place (Cleo): -1 life")

	print("--- the game goes on: next round after the scores")
	await _until(func(): return game.state == GameManager.State.INTRO, 30.0)
	check(game.current is ZwartePietRound, "round 5: Zwarte Piet (no fixed number of rounds)")
	print("    scores: ", game.scores)
	game.stop_game()                     # operator: end the game
	await _wait(1.0)
	check(game.state == GameManager.State.LOBBY, "stopped: back to the lobby")
	check(arena.players.player_ids().is_empty(), "everyone left after the game")
	check(arena.tiles.all(func(t): return t.idle), "all tiles idle again")
	check(arena.tiles.all(func(t): return not t.shielded), "no shields left")

	print("--- commands: combined attacks")
	arena.apply_command({"attack": [2, 3, 4]})
	arena.apply_command({"attacked": [7, 8]})
	await _wait(3.0)

	print("\nDONE: %d failure(s)" % failures)
	get_tree().quit(1 if failures else 0)


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		failures += 1


func _yellow_leds(t: CyberTile) -> int:
	return t.ring.colors.filter(func(c): return c.is_equal_approx(Color(1.0, 0.8, 0.0))).size()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _until(cond: Callable, timeout := 300.0) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()
	if t >= timeout:
		check(false, "timed out waiting")
