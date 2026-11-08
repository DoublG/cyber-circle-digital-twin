extends Node
## Rhythm round: the chart (slow and one at a time first, hold notes in the
## second step, faster and two at once later), the judging (line / band /
## wrong / missed; hold notes: let go on time, too early, too late) and
## screenshots of the lanes (tapping, a hold note being held).
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
	var holds := chart.filter(func(n): return n.hold > 0.0)
	check(not holds.is_empty() and holds.all(func(n): return n.t >= chart_round.hold_from * chart_round.duration),
		"hold notes, only from the second step on (%d, first at %.1f s)" % [holds.size(), holds[0].t if holds else -1.0])
	check(holds.all(func(n): return times[n.t] == 1), "a hold note never comes with another at once")
	check(holds.all(func(h): return chart.all(func(n): return n == h or n.t < h.t or n.t > h.t + h.hold)),
		"nothing else falls while a hold note lasts")
	check(holds.all(func(n): return n.hold >= chart_round.hold_min - 0.26 and n.hold <= chart_round.hold_max + 0.26),
		"hold notes last hold_min .. hold_max (on the music's grid)")
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
	# Anna on the line (hold notes: lets go on the line), Bram in the band (lets
	# go in the band), Cleo presses once on nothing then never; Daan and Eva the
	# first few on the line, then only the hold notes: Daan lets go too early,
	# Eva too late
	var shot := false
	var hold_shot := false
	var pressed := {}
	var letting_go := {}                            # [id, lane] -> when
	arena.tiles[2].press_button(&"Square")
	while round.clock < 30.0:
		for key in letting_go.keys():
			if round.clock >= letting_go[key]:
				arena.tiles[key[0] - 1].release_button(CyberTile.BUTTONS[key[1]])
				letting_go.erase(key)
		for i in round.notes.size():
			var n: Dictionary = round.notes[i]
			for id in [1, 2, 10, 11]:
				var at: float = n.t + (0.0 if id != 2 else 0.7 * round.band * n.fall)
				if id >= 10 and i >= 4 and n.hold == 0.0:
					continue
				if round.clock >= at and not pressed.has([id, i]):
					pressed[[id, i]] = true
					var b: StringName = CyberTile.BUTTONS[n.lane]
					if n.hold > 0.0:
						arena.tiles[id - 1].hold_button(b)
						var end: float = n.t + n.hold
						letting_go[[id, n.lane]] = {1: end, 2: end + 0.7 * round.band * n.fall,
							10: end - n.hold * 0.5, 11: end + 2.0 * round.band * n.fall}[id]
					else:
						arena.tiles[id - 1].press_button(b, 0.05)
		if not shot and round.clock > 9.0:
			shot = true
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://tests/shots/45_rhythm_round.png")
		if not hold_shot and round.state[1].holds.values().has("on"):
			var i: int = round.state[1].holds.find_key("on")
			if round.clock - round.notes[i].t > 0.2:     # (held a moment: the band slides into the line)
				hold_shot = true
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png("res://tests/shots/46_rhythm_hold.png")
		await get_tree().process_frame
	var passed := range(round._first)
	var hits := func(id): return passed.filter(func(i): return round.state[id].judged.get(i, 0) > 0).size()
	var lines := func(id): return passed.filter(func(i): return round.state[id].judged.get(i, 0) == round.points_line).size()
	print("passed %d symbols; Anna %d pts, Bram %d, Cleo %d" % [passed.size(), round.points[1], round.points[2], round.points[3]])
	check(passed.size() >= 8, "symbols passed the line")
	check(lines.call(1) == passed.size(), "Anna: every symbol on the line (%d/%d)" % [lines.call(1), passed.size()])
	check(hits.call(2) == passed.size() and lines.call(2) == 0, "Bram: every symbol in the band, none on the line")
	check(round.points[3] == round.points_wrong and hits.call(3) == 0, "Cleo: pressed on nothing (-1), missed the rest")
	var held := passed.filter(func(i): return round.notes[i].hold > 0.0 and round.clock > round.notes[i].t + round.notes[i].hold + round.band * round.notes[i].fall)
	var holds_of := func(id, result): return held.filter(func(i): return round.state[id].holds.get(i, "") == result).size()
	print("hold notes done: %d; Anna ok %d, Bram ok %d, Daan fail %d, Eva fail %d" % [held.size(), holds_of.call(1, "ok"),
		holds_of.call(2, "ok"), holds_of.call(10, "fail"), holds_of.call(11, "fail")])
	check(held.size() >= 1, "hold notes came and ended (%d)" % held.size())
	check(holds_of.call(1, "ok") == held.size() and holds_of.call(2, "ok") == held.size(), "Anna and Bram: let go on time (every hold note)")
	check(holds_of.call(10, "fail") == held.size(), "Daan: let go too early (every hold note: 0, the combo ends)")
	check(holds_of.call(11, "fail") == held.size(), "Eva: held on too long (every hold note: 0)")
	check(round.state[1].combo == passed.size() + held.size() and round.state[3].combo == 0,
		"combo counts on (a hold note: twice), a miss ends it")
	check(round.points[1] > round.points[2] and round.points[2] > round.points[3], "places follow the points")
	await get_tree().create_timer(0.2).timeout
	print("FAILURES: %d" % failures)
	get_tree().quit(1 if failures else 0)
