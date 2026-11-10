extends Node
## Recovery: a checkpoint (snapshot) of one game, applied in a fresh one, gives
## the same game - players, lives, invites (that still activate), the plan.
## Run: godot --headless --path . res://tests/test_recovery.tscn

const ARENA := preload("res://scenes/arena.tscn")
var _fails := 0


func check(ok: bool, what: String) -> void:
	print(("  [ok] " if ok else "  [FAIL] ") + what)
	if not ok:
		_fails += 1


func _ready() -> void:
	var a: Arena = ARENA.instantiate()
	add_child(a)
	a.game.use_database("")
	await get_tree().process_frame
	a.players.register(3, "Anna", Color("#ff44cc"), 12, 11)
	for b in ["Square", "Triangle", "Cross", "Circle"]:
		a.tiles[2].press_button(StringName(b))
		await get_tree().create_timer(0.25).timeout
	a.players.register(5, "Bram", Color("#33ccff"), 9, 12)
	a.tiles[2].health = 2
	a.game.set_planned_round(0, "quiz")
	var cp: Dictionary = JSON.parse_string(JSON.stringify(a.game.recovery.snapshot()))   # (as stored)
	check(cp.players.size() == 1 and cp.invites.size() == 1, "snapshot: 1 player, 1 invite")
	a.queue_free()
	await get_tree().process_frame

	var b: Node3D = ARENA.instantiate()      # the game after the crash
	add_child(b)
	b.game.use_database("")
	await get_tree().process_frame
	b.game.recovery.apply(cp)
	check(b.players.is_playing(3) and b.players.player_name(3) == "Anna" and b.tiles[2].health == 2,
		"Anna on T03 with 2 lives")
	check(b.players.is_pending(5) and b.players.pending_info(5).name == "Bram", "Bram's invite on T05")
	check(b.game.picker.upcoming[0].type == RoundPicker.type_named("quiz"), "the plan: a quiz next")
	await get_tree().create_timer(0.5).timeout
	for btn in ["Square", "Triangle", "Cross", "Circle"]:
		b.tiles[4].press_button(StringName(btn))
		await get_tree().create_timer(0.25).timeout
	check(b.players.is_playing(5), "Bram activates his restored invite (pending=%s)" % b.tiles[4].pending)

	var c: Node3D = ARENA.instantiate()      # a crash right after an extermination, in a game
	add_child(c)
	c.game.use_database("")
	await get_tree().process_frame
	var cp2: Dictionary = cp.duplicate(true)
	cp2.state = "SCOREBOARD"
	cp2.round = 3
	cp2.players.append({"tile": 7, "name": "Cas", "age": 10, "player_id": 13, "lives": 0, "max_lives": 4,
		"dead": true, "started": true, "score": 0, "survived": 2, "streak": 0, "saved": false})
	c.game.recovery.apply(cp2)
	check(c.players.is_playing(3) and not c.players.is_playing(7),
		"exterminated Cas is out (his play ends), Anna plays on")
	check(c.game.round_number == 3 and c.game.state == GameManager.State.SCOREBOARD, "round 3, on the scoreboard")
	print("DONE: %d failure(s)" % _fails)
	get_tree().quit(1 if _fails else 0)
