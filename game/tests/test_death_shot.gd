extends Node
## Screenshots of exterminations - lives only change on the scoreboard; two
## players at once (the robot turns to the first before the scores, then from
## one to the next while the first one's tile still blinks / explodes):
## a player who joins during the round waits (no tilt, "WACHT"), the round
## ends, the scoreboard shows the lives as they were, then the change: Bram
## (last, 1 life) GEËXTERMINEERD (banner, red rows), the new player NIEUW;
## the overview watches the robot fire (a popup over the floating camera); the
## next round starts while the extermination runs on. The death clip only
## plays in the player's own split screen view, never over a shared screen.
## Run (with a display): godot --path . res://tests/test_death_shot.tscn

const ARENA := preload("res://scenes/arena.tscn")


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")                 # screenshots: no database writes
	game.intro_time = 1.0
	game.result_time = 1.0
	game.scoreboard_time = 4.0
	game.auto_start_delay = 0.0
	game.picker.random_rounds = false
	arena.clip_time = 7.0                      # longer than the 4 s clip: it holds its last frame
	game.picker.round_types = [ZwartePietRound, CycloneRound]
	for p in [[1, "Anna", 12], [2, "Bram", 7], [3, "Cleo", 9], [5, "Eva", 11]]:
		arena.apply_command({"tile": p[0], "join": p[1], "age": p[2]})
	await get_tree().create_timer(1.0).timeout
	game.start_game()
	while not (game.state == GameManager.State.PLAYING):
		await get_tree().process_frame
	var piet: ZwartePietRound = game.current
	piet.countdown_min = 100.0                 # no bursts: the places come from these points
	piet.countdown_max = 100.0
	piet.add_points(1, 3)
	piet.add_points(5, 2)
	arena.tiles[1].health = 1                  # Bram and Cleo: last, on their last life
	arena.tiles[2].health = 1
	arena.apply_command({"tile": 4, "join": "Daan", "age": 10})   # joins during the round
	await get_tree().create_timer(1.5).timeout
	await _shot("28_waiting_for_next_round")
	game.skip()                                # end of the round
	while not (game.state == GameManager.State.SCOREBOARD and not game.screen_wall.shared_views.is_empty()):
		await get_tree().process_frame
	await get_tree().create_timer(0.8).timeout
	check(arena.tiles[1].health == 1 and arena.tiles[2].health == 1,
		"lives unchanged until the scoreboard shows the change")
	check(arena.robot.is_facing_target() and arena.robot._target_yaw == CyberRobot.side_yaw(1),
		"the robot already faces the first one (Bram) before the lives change")
	await _shot("29_scoreboard_before")
	while not game._lives_shown:
		await get_tree().process_frame
	await get_tree().create_timer(0.7).timeout
	await _shot("30_scoreboard_exterminated")
	var page: ObserverView = _find_page(arena.screen_wall)
	check(arena.dying.has(2) and arena.dying.has(3), "both exterminated at once (Bram and Cleo)")
	var t := 0.0
	var both_running := false
	while t < 15.0 and not both_running:            # the second one starts while the first still plays
		both_running = arena.dying.get(2, 0) > 0 and arena.dying.get(3, 0) > 0
		await get_tree().process_frame
		t += get_process_delta_time()
	check(both_running, "the robot moved on to the second one during the first one's death animation")
	check(arena.clip_waiting.has(2) and arena.clip_started.is_empty(),
		"the death clip waits while the screens are shared (scoreboard)")
	await get_tree().create_timer(0.8).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tests/shots/31_scoreboard_death_clip.png")
	page.get_viewport().get_texture().get_image().save_png("res://tests/shots/32_overview_extermination.png")
	print("saved 31_scoreboard_death_clip, 32_overview_extermination")
	while game.state != GameManager.State.INTRO:
		await get_tree().process_frame
	while game.state != GameManager.State.PLAYING:
		await get_tree().process_frame
	await get_tree().create_timer(1.0).timeout
	check(game.state == GameManager.State.PLAYING, "the next round did not wait for the animations")
	check(not game.screen_wall.shared_views.any(func(v): return v.get_parent().get_children().any(
		func(c): return c is PanelContainer and c != v)), "no death clip over the shared screens")
	check(arena.clip_started.has(2) and arena.clip_started.has(3),
		"the death clips start once the split views are on screen")
	var age: float = arena.clock - float(arena.clip_started.get(2, 0.0))
	check(age < 1.5, "the clip started from the beginning (%.1f s ago)" % age)
	check(arena.players.is_playing(2), "the tile stays theirs while the clip plays")
	await _shot("33_next_round_while_dying")
	var clip_end: float = float(arena.clip_started[2]) + arena.death_clip_length()
	while arena.clock < clip_end + 1.0:
		await get_tree().process_frame
	check(arena.players.is_playing(2) and arena.death_clip_pending(2),
		"clip shorter than the death screen time: the tile is still theirs")
	await _shot("34_clip_last_frame")
	while arena.death_clip_pending(2):
		await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	check(not arena.players.is_playing(2), "the tile is free after the clip")
	print("DONE")
	get_tree().quit()


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])


func _find_page(n: Node) -> ObserverView:
	if n is ObserverView:
		return n
	for c in n.get_children():
		var f := _find_page(c)
		if f:
			return f
	return null


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tests/shots/%s.png" % name)
	print("saved ", name)
