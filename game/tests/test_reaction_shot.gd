extends Node
## Screenshot of the reaction round (player views looking at their tiles).
## Run (with a display): godot --path . --disable-vsync res://tests/test_reaction_shot.tscn

const ARENA := preload("res://scenes/arena.tscn")


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")                 # screenshots: no database writes
	game.intro_time = 1.0
	game.auto_start_delay = 0.0
	game.picker.round_types = [ReactionRound]
	for p in [[1, "Anna", 12], [2, "Bram", 7], [4, "Daan", 13], [7, "Eva", 8]]:
		arena.apply_command({"tile": p[0], "join": p[1], "age": p[2]})
	await get_tree().create_timer(1.0).timeout
	game.start_game()
	while not (game.state == GameManager.State.PLAYING):
		await get_tree().process_frame
	var round: ReactionRound = game.current
	for id in [1, 2]:  # a few results first, so the overlay shows them
		var fw: TileFirmware = arena.tiles[id - 1].get_node("Firmware")
		fw.step_started.connect(func(tid, i, step):
			if i < 2:
				await get_tree().create_timer(0.3 if tid == 1 else 0.7).timeout
				arena.tiles[tid - 1].press_button(StringName(step.button)))
	while round._results[1].size() < 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tests/shots/14_reaction_round.png")
	print("saved 14_reaction_round")
	get_tree().quit()
