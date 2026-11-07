extends SceneTree
## Zwarte Piet with real tiles: a kick stamped just before the hidden countdown
## ran out, but arriving just after it, still counts - whoever had the light
## at that moment is caught. A kick stamped after the end, or one without a
## stamp, arriving after the end: too late, the holder is caught.
##   godot-4 --headless --path godot --script res://tests/check_piet_stamp.gd
var fails := 0


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		fails += 1


func _init() -> void:
	var arena: Node3D = load("res://scenes/arena.tscn").instantiate()
	root.add_child(arena)
	await process_frame
	arena.simulate_firmware = false                  # (real tiles: presses come in over MQTT)
	var game: GameManager = arena.game
	game.use_database("")
	game.set_mode(GameManager.Mode.OPEN)
	game.intro_time = 0.5
	for i in 4:
		arena.join(i + 1, "Speler %d" % (i + 1), 12)
	game.set_planned_round(0, "zwarte_piet")
	game.start_game()
	for n in 600:
		if game.state == GameManager.State.PLAYING and game.current is ZwartePietRound:
			break
		await process_frame
	var r := game.current as ZwartePietRound
	check(r != null, "a Zwarte Piet round is playing")
	if r == null:
		quit(1)
		return
	check(not r.tile_clock.is_empty(), "the tiles run the round's clock")

	# 1. the countdown runs out; a kick stamped 0.1 s before the end arrives during the wait
	var kicker := await _run_out(r)
	var to: int = r._neighbour(kicker, 1)
	var before := {kicker: r.points[kicker], to: r.points[to]}
	arena.apply_command({"tile": kicker, "press": "Square", "t": roundi((r._end_at - 0.1) * 1000.0), "program": r.tile_clock.id})
	check(r.holder == to and r.late_kicks == 1, "a kick stamped before the end, arriving after it: counts (light at %d)" % r.holder)
	await _until(func(): return r._end_at < 0.0)
	check(r.points[to] == before[to] - r.penalty and r.points[kicker] == before[kicker],
		"the one who had it at the end is caught, not the kicker")

	# 2. a kick stamped after the end: too late
	kicker = await _run_out(r)
	var p: int = r.points[kicker]
	arena.apply_command({"tile": kicker, "press": "Square", "t": roundi((r._end_at + 0.05) * 1000.0), "program": r.tile_clock.id})
	check(r.holder == kicker, "a kick stamped after the end: does not count")
	await _until(func(): return r._end_at < 0.0)
	check(r.points[kicker] == p - r.penalty, "... the holder is caught")

	# 3. no stamp, arriving after the end: too late (as before)
	kicker = await _run_out(r)
	p = r.points[kicker]
	arena.apply_command({"tile": kicker, "press": "Square"})
	check(r.holder == kicker, "a kick without a stamp after the end: does not count")
	await _until(func(): return r._end_at < 0.0)
	check(r.points[kicker] == p - r.penalty, "... the holder is caught")
	check(not game.arena.press_stamp().size(), "no stamp left over")

	game.stop_game()
	print("DONE: %d failure(s)" % fails)
	quit(1 if fails else 0)


## Wait for a burst, make its countdown run out now; returns the holder.
func _run_out(r: ZwartePietRound) -> int:
	await _until(func(): return r.holder != 0 and r._end_at < 0.0)
	r._left = 0.02
	await _until(func(): return r._end_at >= 0.0)
	return r.holder


func _until(cond: Callable) -> void:
	for n in 900:
		if cond.call():
			return
		await process_frame
	check(false, "timed out waiting")
