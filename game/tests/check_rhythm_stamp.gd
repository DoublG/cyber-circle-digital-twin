extends SceneTree
## Ritme scores a real tile's press at the moment the tile stamped on it
## ({"press": .., "t": ms since the clock program's start, "program": id}),
## not when it arrives: a press that arrives 0.5 s late still hits the line.
## Without a stamp (or a stamp of another program) it counts on arrival.
##   godot-4 --headless --path godot --script res://tests/check_rhythm_stamp.gd
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
	game.set_mode(GameManager.Mode.OPEN)
	game.intro_time = 0.5
	var sent := {}                                 # tile -> the messages it got
	arena.tile_message.connect(func(id, msg): sent.get_or_add(id, []).append(msg))
	for i in 3:
		arena.players.join(i + 1, "Speler %d" % (i + 1), 12)
	game.set_planned_round(0, "rhythm")
	game.start_game()
	for n in 600:
		if game.state == GameManager.State.PLAYING and game.current is RhythmRound:
			break
		await process_frame
	var r := game.current as RhythmRound
	check(r != null, "a Ritme round is playing")
	if r == null:
		quit(1)
		return
	var msgs: Array = sent.get(1, [])
	check(msgs.any(func(m): return m.get("program", {}).get("game", "") == "clock"), "the tile got the clock program")
	check(msgs.any(func(m): return str(m.get("start", "")) == r.tile_clock.id), "... and its start")

	# the next note, and a press of its icon that arrives 0.5 s late
	var k := r._first
	var note: Dictionary = r.notes[k]
	var icon: StringName = CyberTile.BUTTONS[note.lane]
	r.clock = note.t + 0.5
	var stamp := roundi(note.t * 1000.0)
	arena.apply_command({"tile": 1, "press": str(icon), "t": stamp, "program": r.tile_clock.id})
	check(r.state[1].judged.get(k, null) == r.points_line,
		"stamped, 0.5 s late on the network: on the line (%s)" % r.state[1].last[note.lane])
	check(r.stamped == 1, "counted as stamped")
	arena.apply_command({"tile": 2, "press": str(icon)})
	check(r.state[2].judged.get(k, null) == null, "no stamp, 0.5 s late: not a hit (%s)" % r.state[2].last[note.lane])
	arena.apply_command({"tile": 3, "press": str(icon), "t": stamp, "program": "an-old-round"})
	check(r.state[3].judged.get(k, null) == null and r.stamped == 1, "another program's stamp: on arrival")
	check(arena.press_stamp().is_empty(), "the stamp is gone after the press")

	# a hold note: the tile's press says a release follows ({"hold": 1}), the
	# release counts at the tile's stamp too (its end on the line, 0.5 s late)
	for n in 120:                                  # (the taps above are over: an icon that is still
		if not CyberTile.BUTTONS.any(func(b): return arena.tiles[0].is_pressed(b)):   # down can't be pressed)
			break
		await process_frame
	var h := -1
	for i in range(r._first, r.notes.size()):
		if r.notes[i].hold > 0.0:
			h = i
			break
	check(h >= 0, "the chart has a hold note")
	if h >= 0:
		var hn: Dictionary = r.notes[h]
		var hicon := str(CyberTile.BUTTONS[hn.lane])
		r.clock = hn.t
		arena.apply_command({"tile": 1, "press": hicon, "hold": 1, "t": roundi(hn.t * 1000.0), "program": r.tile_clock.id})
		check(r.state[1].holds.get(h, "") == "on", "hold note pressed: holding")
		r.clock = hn.t + 0.4
		await process_frame
		check(arena.tiles[0].is_pressed(StringName(hicon)), "the icon stays down until the tile's release (not a tap)")
		r.clock = hn.t + hn.hold + 0.5
		arena.apply_command({"tile": 1, "release": hicon, "t": roundi((hn.t + hn.hold) * 1000.0), "program": r.tile_clock.id})
		check(r.state[1].holds.get(h, "") == "ok" and r.state[1].last[hn.lane].points == r.points_line,
			"stamped release, 0.5 s late on the network: let go on the line (%s)" % r.state[1].last[hn.lane])
		check(not arena.tiles[0].is_pressed(StringName(hicon)), "released")

	game.stop_game()
	await process_frame
	check((sent.get(1, []) as Array).any(func(m): return m.has("stop")), "the clock stopped at the end")
	print("DONE: %d failure(s)" % fails)
	quit(1 if fails else 0)
