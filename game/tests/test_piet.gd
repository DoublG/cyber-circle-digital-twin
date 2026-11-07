extends Node
## Zwarte Piet (headless): kicking left / right to the next player (skipping
## empty tiles), faster kicks speed the light up, whoever has it when the
## hidden countdown ends loses a point, places -> lives at the end.
## Run: godot --headless --path . --fixed-fps 60 res://tests/test_piet.tscn

const ARENA := preload("res://scenes/arena.tscn")

var failures := 0


func _ready() -> void:
	var arena: Node3D = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")
	game.intro_time = 1.0
	game.scoreboard_time = 30.0
	game.result_time = 3.0
	game.auto_start_delay = 0.0
	game.random_rounds = false
	game.round_types = [ZwartePietRound]
	for p in [[1, "Anna"], [2, "Bram"], [5, "Cleo"], [9, "Daan"]]:
		arena.join(p[0], p[1], 10)
	await _wait(0.5)
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	var piet: ZwartePietRound = game.current
	piet.countdown_min = 3.0
	piet.countdown_max = 4.0
	piet.duration = 40.0
	piet.time_left = 40.0

	print("--- kicking: left = next player clockwise, right = previous (empty tiles skipped)")
	await _until(func(): return piet.holder != 0)
	piet.holder = 2
	piet._got_at = piet._clock
	arena.tiles[1].press_button(&"Square")          # left from T02
	await _wait(0.1)
	check(piet.holder == 5, "T02 kicks left -> T05 (T03, T04 empty)")
	arena.tiles[4].press_button(&"Triangle")        # right from T05
	await _wait(0.1)
	check(piet.holder == 2, "T05 kicks right -> T02")
	arena.tiles[0].press_button(&"Cross")           # not the holder: nothing happens
	await _wait(0.1)
	check(piet.holder == 2, "only the player with the light can kick it")
	piet.holder = 9
	arena.tiles[8].press_button(&"Cross")           # left from T09 wraps around
	await _wait(0.1)
	check(piet.holder == 1, "T09 kicks left -> T01 (wraps around)")
	var slow_speed := piet.speed
	piet._got_at = piet._clock                      # an instant kick ...
	arena.tiles[0].press_button(&"Square")
	await _wait(0.1)
	check(piet.speed > slow_speed * 1.2, "a fast kick speeds the light up (%.1f -> %.1f)" % [slow_speed, piet.speed])

	print("--- bots play: Anna fast, Daan medium, Bram slow, Cleo never kicks")
	var delays := {1: 0.25, 9: 0.6, 2: 1.4}
	var t := 0.0
	var caught := {}
	while game.state == GameManager.State.PLAYING:
		if piet.holder in delays and piet._clock - piet._got_at >= delays[piet.holder]:
			arena.tiles[piet.holder - 1].press_button(&"Square" if randf() < 0.5 else &"Circle")
			await _wait(0.2)
		await get_tree().process_frame
	print("    %d bursts, points: %s" % [piet.bursts, piet.points])
	check(piet.bursts >= 4, "several bursts (%d)" % piet.bursts)
	check(piet.points[5] < 0 and piet.points[5] <= piet.points.values().min(), "Cleo (never kicks) lost the most points")
	check(piet.points[1] >= piet.points[5], "Anna (fast) did better than Cleo")
	var lives := {}
	for id in [1, 2, 5, 9]:
		lives[id] = arena.tiles[id - 1].health
	await _until(func(): return game.state == GameManager.State.SCOREBOARD)
	await _wait(1.0)
	check([1, 2, 5, 9].all(func(id): return arena.tiles[id - 1].health == lives[id]), "places first: lives unchanged until the scoreboard")
	await _until(func(): return game._lives_shown and not arena.attacks_busy(), 30.0)   # the scoreboard: lives
	await _wait(1.0)
	check(arena.tiles[4].health == lives[5] - 1, "last place (Cleo): -1 life")
	var best: int = piet.points.values().max()
	var firsts := [1, 2, 9].filter(func(id): return piet.points[id] == best)
	check(firsts.all(func(id): return arena.tiles[id - 1].health == mini(lives[id] + 1, 5)), "1st place(s) %s: +1 life" % [firsts])

	print("\nDONE: %d failure(s)" % failures)
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
