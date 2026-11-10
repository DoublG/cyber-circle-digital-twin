extends SceneTree
## The robot's shows: the game opening (CLOSED -> OPEN) brings the robot to
## life, closing shuts it down - after the round when one is playing. The real
## robot gets {"boot"} / {"shutdown"}; the sounds and light cues follow the
## robot's moments; the screens show PowerView and then the normal views.
##   godot-4 --headless --path godot --script res://tests/check_power_show.gd
var fails := 0
var cues := []
var hw := []


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		fails += 1


func _init() -> void:
	var arena: Arena = load("res://scenes/arena.tscn").instantiate()
	root.add_child(arena)
	await process_frame
	Engine.time_scale = 4.0                        # (the shows take ~20 s each)
	var game: GameManager = arena.game
	game.use_database("")
	game.intro_time = 0.5
	game.auto_start_delay = 0.0
	arena.light_cue.connect(func(e, _d): cues.append(String(e)))
	arena.npc.hardware.connect(func(c): hw.append(c))

	print("  -- the game starts closed: the robot off, no show")
	game.set_mode(GameManager.Mode.CLOSED)
	check(not arena.robot.powered and game.power_show == "", "off at once")
	check(hw.any(func(c): return c.get("mood", "") == "off"), "the real robot: off")

	print("  -- opened: it comes to life")
	game.set_mode(GameManager.Mode.OPEN)
	check(game.power_show == "boot" and game.view.kind == "power", "boot: PowerView on the screens")
	check(hw.any(func(c): return c.has("boot")), "the real robot: boot")
	check(game.accepting_players(), "players may come in during the boot")
	await _until(func(): return game.power_show == "", 40.0)
	check(arena.robot.powered, "awake")
	check("boot" in cues and "boot_done" in cues, "the cues: boot, boot_done (%s)" % [cues])
	check(game.view.kind == "players", "the invites again")

	print("  -- closed during a round: after the round")
	for i in 3:
		arena.players.join(i + 1, "Speler %d" % (i + 1), 12)
	game.set_planned_round(0, "reaction")
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING, 20.0)
	cues.clear()
	game.set_mode(GameManager.Mode.CLOSED)
	check(game.mode == GameManager.Mode.OPEN and game.status().closing, "still open: closing after the round")
	check(not game.accepting_players(), "no new players meanwhile")
	check(game.power_show == "", "no show yet")
	game.skip()                                    # the round ends ...
	await _until(func(): return game.mode == GameManager.Mode.CLOSED, 60.0)
	check(game.mode == GameManager.Mode.CLOSED, "... and after its scoreboard: closed")
	check(arena.players.player_ids().is_empty(), "everyone out")
	check(game.power_show == "shutdown" and game.view.kind == "power", "shutdown: PowerView")
	check(hw.any(func(c): return c.has("shutdown")), "the real robot: shutdown")
	await _until(func(): return not arena.robot.powered, 40.0)
	check(not arena.robot.powered, "the robot is off")
	check("shutdown" in cues and "zap" in cues and "power_down" in cues and "off" in cues,
		"the cues: shutdown, zap, power_down, off (%s)" % [cues])
	await _until(func(): return game.power_show == "", 20.0)
	check(game.view.kind == "players", "GEWONNEN, then the closed screens")

	print("  -- closed while nothing plays: at once; a test from the web interface")
	game.set_mode(GameManager.Mode.OPEN)
	await _until(func(): return game.power_show == "", 40.0)
	game.set_mode(GameManager.Mode.CLOSED)
	check(game.power_show == "shutdown", "closed in the lobby: the shutdown at once")
	await _until(func(): return game.power_show == "", 60.0)
	game.set_mode(GameManager.Mode.OPEN)
	await _until(func(): return game.power_show == "", 40.0)
	arena.apply_command({"game": "shutdown"})
	check(game.power_show == "shutdown" and game.mode == GameManager.Mode.OPEN, "test: the shutdown, the mode stays open")
	await _until(func(): return game.power_show == "boot", 80.0)
	check(true, "... and back to life by itself (the game is open)")
	await _until(func(): return game.power_show == "" and arena.robot.powered, 40.0)
	check(arena.robot.powered, "on again")

	Engine.time_scale = 1.0
	print("DONE: %d failure(s)" % fails)
	quit(1 if fails else 0)


func _until(cond: Callable, seconds: float) -> void:
	var end := Time.get_ticks_msec() + seconds * 1000.0 / Engine.time_scale
	while Time.get_ticks_msec() < end:
		if cond.call():
			return
		await process_frame
	check(false, "timed out")
