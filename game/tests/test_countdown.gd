extends Node
## The round's countdown LED (headless): one violet LED once round the OUTER
## ring of every player's tile (not the inner ring), moving on with the time;
## the real tiles get one {"countdown"} at the start and {"countdown": false}
## at the end; Cyclone (its own green light) has none.
## Run: godot --headless --path . --fixed-fps 60 res://tests/test_countdown.tscn

const ARENA := preload("res://scenes/arena.tscn")

var failures := 0
var sent := []                      # [tile_id, msg] of every countdown message


func _ready() -> void:
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")
	game.intro_time = 1.0
	game.scoreboard_time = 1.0
	game.result_time = 0.5
	game.auto_start_delay = 0.0
	game.picker.random_rounds = false
	game.picker.round_types = [ReactionRound, CycloneRound]
	arena.tile_message.connect(func(id: int, msg: Dictionary):
		if msg.has("countdown"):
			sent.append([id, msg]))
	var ids := [1, 2, 5, 9]
	for id in ids:
		arena.players.join(id, "P%d" % id, 10)
	await _wait(0.5)
	game.start_game()

	print("--- Reactie: the countdown LED")
	await _until(func(): return game.state == GameManager.State.PLAYING)
	await _wait(0.3)
	var r := game.current
	var ring := arena.tiles[0].ring
	var led := _expected(r)
	check(ring._countdown == led, "T01: the countdown LED is %d (%.1f of %.1f s left)" % [led, r.time_left, r.duration])
	check(ring.shown(led) == TileRing.COUNTDOWN_COLOR, "... violet on the outer ring")
	check(ring.shown(led, true) == ring.colors[led], "... the inner ring shows the ring's own colour there")
	check(arena.tiles[2].ring._countdown == -1, "T03 (no player): no countdown LED")
	var starts := sent.filter(func(s): return s[1].countdown is Dictionary)
	check(starts.size() == ids.size(), "one start message per player (%d)" % starts.size())
	if not starts.is_empty():
		var m: Dictionary = starts[0][1].countdown
		check(absi(int(m.length) - roundi(r.duration * 1000.0)) <= 1, "... its length: the round's time (%d ms)" % m.length)
	await _wait(2.5)
	check(ring._countdown > led, "the LED moved on with the time (%d -> %d)" % [led, ring._countdown])
	check(ring._countdown == _expected(r), "... to where the time is (%d)" % _expected(r))
	var last := ring._countdown
	sent.clear()
	game.skip()                                          # the round is over
	await _wait(0.2)
	check(ring._countdown == -1, "round over: the LED is gone")
	check(ring.shown(last) == ring.colors[last], "... the ring shows its own colour there again")
	var stops := sent.filter(func(s): return s[1].countdown is bool and not s[1].countdown)
	check(stops.size() == ids.size(), "one stop message per player (%d)" % stops.size())

	print("--- Cyclone: no countdown LED (its own green light runs round)")
	sent.clear()
	await _until(func(): return game.state == GameManager.State.PLAYING and game.current is CycloneRound)
	await _wait(1.0)
	check(arena.tiles[0].ring._countdown == -1, "no countdown LED in Cyclone")
	check(sent.is_empty(), "no countdown messages to the tiles (%d)" % sent.size())

	print("DONE: %d failure(s)" % failures)
	get_tree().quit(1 if failures else 0)


func _expected(r: GameRound) -> int:
	return clampi(int((1.0 - r.countdown.x / r.countdown.y) * CyberTile.LED_COUNT), 0, CyberTile.LED_COUNT - 1)


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
