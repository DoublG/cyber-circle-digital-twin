extends Node
## Screenshot of the Simon round (player views with the Simon overlay).
## Run (with a display): godot --path . --disable-vsync res://tests/test_simon_shot.tscn

const ARENA := preload("res://scenes/arena.tscn")


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")                 # screenshots: no database writes
	game.intro_time = 1.0
	game.auto_start_delay = 0.0
	game.picker.round_types = [SimonRound]
	for p in [[1, "Anna", 12], [2, "Bram", 7], [4, "Daan", 13], [7, "Eva", 8]]:
		arena.apply_command({"tile": p[0], "join": p[1], "age": p[2]})
	await get_tree().create_timer(1.0).timeout
	game.start_game()
	while not (game.state == GameManager.State.PLAYING):
		await get_tree().process_frame
	var round: SimonRound = game.current
	# Anna and Daan repeat correctly, Bram gets one wrong, Eva waits
	for id in [1, 2, 4]:
		var fw: TileFirmware = arena.tiles[id - 1].get_node("Firmware")
		fw.simon_turn.connect(func(tid, _level, seq):
			for i in seq.size():
				if tid == 1 and round.state[1].level >= 4 and i == 2:
					return                   # Anna: stop halfway, so the pips show
				await get_tree().create_timer(0.35).timeout
				var b := StringName(seq[i].button)
				if tid == 2 and i == 1:
					b = &"Circle" if b != &"Circle" else &"Square"
				arena.tiles[tid - 1].press_button(b)
				if tid == 2 and i == 1:
					return)
	while not (round.state[1].phase == "repeat" and round.state[1].level == 4 and round.state[1].index == 2):
		await get_tree().process_frame
	await get_tree().create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tests/shots/15_simon_round.png")
	print("saved 15_simon_round")
	get_tree().quit()
