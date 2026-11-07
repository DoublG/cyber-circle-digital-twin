extends Node
## Rhythm round: the chart (slow and one at a time first, faster and two at
## once later), the judging (line / band / wrong / missed) and screenshots of
## the lanes in a 3-way and a 2-way split.
## Run (with a display): godot --path . --disable-vsync res://tests/test_rhythm_shot.tscn

const ARENA := preload("res://scenes/arena.tscn")

var failures := 0


func check(ok: bool, what: String) -> void:
	print(("ok    " if ok else "FAIL  ") + what)
	if not ok:
		failures += 1


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	# the chart on its own
	var chart_round := RhythmRound.new()
	var chart := chart_round.make_chart()
	var early := chart.filter(func(n): return n.t < chart_round.parallel_from * chart_round.duration)
	var times := {}
	for n in chart:
		times[n.t] = times.get(n.t, 0) + 1
	var early_times := early.map(func(n): return n.t)
	check(early_times.size() == times.keys().filter(func(t): return t in early_times).size(),
		"one at a time in the first part (%d symbols)" % early.size())
	check(times.values().any(func(c): return c == 2), "two at once later in the round")
	check(chart[0].fall > chart[-1].fall and chart[0].t >= chart[0].fall, "falls faster later, the first falls the whole way")
	var gaps := []
	var keys := times.keys()
	for i in range(1, keys.size()):
		gaps.append(keys[i] - keys[i - 1])
	check(gaps.slice(0, 3).max() > gaps.slice(-4).max(), "closer together at the end")
	for t in times:
		var lanes := chart.filter(func(n): return n.t == t).map(func(n): return n.lane)
		if lanes.size() == 2 and lanes[0] == lanes[1]:
			check(false, "two at once on the same icon")

	var arena: Node3D = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")
	game.intro_time = 1.0
	game.auto_start_delay = 0.0
	game.round_types = [RhythmRound]
	for p in [[1, "Anna", 12], [2, "Bram", 7], [3, "Cleo", 10], [10, "Daan", 13], [11, "Eva", 8]]:
		arena.apply_command({"tile": p[0], "join": p[1], "age": p[2]})
	await get_tree().create_timer(1.0).timeout
	game.start_game()
	while game.state != GameManager.State.PLAYING:
		await get_tree().process_frame
	var round: RhythmRound = game.current
	check(round.on_tile == false, "players look at the robot (the lanes are on the screen)")
	# Anna on the line, Bram in the band, Cleo presses once on nothing then
	# never, Daan and Eva only the first few on the line
	var shot := false
	var pressed := {}
	arena.tiles[2].press_button(&"Square")
	while round.clock < 20.0:
		for i in round.notes.size():
			var n: Dictionary = round.notes[i]
			for id in [1, 2, 10, 11]:
				var at: float = n.t + (0.0 if id != 2 else 0.7 * round.band * n.fall)
				if id >= 10 and i >= 4:
					continue
				if round.clock >= at and not pressed.has([id, i]):
					pressed[[id, i]] = true
					arena.tiles[id - 1].press_button(CyberTile.BUTTONS[n.lane], 0.05)
		if not shot and round.clock > 14.0:
			shot = true
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://tests/shots/45_rhythm_round.png")
		await get_tree().process_frame
	var passed := range(round._first)
	var hits := func(id): return passed.filter(func(i): return round.state[id].judged.get(i, 0) > 0).size()
	var lines := func(id): return passed.filter(func(i): return round.state[id].judged.get(i, 0) == round.points_line).size()
	print("passed %d symbols; Anna %d pts, Bram %d, Cleo %d" % [passed.size(), round.points[1], round.points[2], round.points[3]])
	check(passed.size() >= 8, "symbols passed the line")
	check(lines.call(1) == passed.size(), "Anna: every symbol on the line (%d/%d)" % [lines.call(1), passed.size()])
	check(hits.call(2) == passed.size() and lines.call(2) == 0, "Bram: every symbol in the band, none on the line")
	check(round.points[3] == round.points_wrong and hits.call(3) == 0, "Cleo: pressed on nothing (-1), missed the rest")
	check(round.state[1].combo == passed.size() and round.state[3].combo == 0, "combo counts on, a miss ends it")
	check(round.points[1] > round.points[2] and round.points[2] > round.points[3], "places follow the points")
	await get_tree().create_timer(0.2).timeout
	print("FAILURES: %d" % failures)
	get_tree().quit(1 if failures else 0)
