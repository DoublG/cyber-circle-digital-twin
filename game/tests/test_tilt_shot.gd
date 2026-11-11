extends Node
## Screenshots of the camera tilting down to the tile in a round played on the
## tile (Cyclone): halfway with the arrow hint, then looking at the tile.
## Run (with a display): godot --path . --disable-vsync res://tests/test_tilt_shot.tscn

const ARENA := preload("res://scenes/arena.tscn")


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")                 # screenshots: no database writes
	game.intro_time = 1.0
	game.auto_start_delay = 0.0
	game.picker.round_types = [CycloneRound]
	for p in [[1, "Anna", 12], [2, "Bram", 7], [4, "Daan", 13], [7, "Eva", 8]]:
		arena.apply_command({"tile": p[0], "join": p[1], "age": p[2]})
	await get_tree().create_timer(1.0).timeout
	game.start_game()
	while not (game.state == GameManager.State.PLAYING):
		await get_tree().process_frame
	var wall: ScreenWall = game.screen_wall
	await get_tree().create_timer(wall.tilt_delay + wall.tilt_time * 0.45).timeout
	await _shot("16_tilt_arrow")
	await get_tree().create_timer(wall.tilt_time * 0.55 + 0.5).timeout
	await _shot("17_tile_view")
	print("--- refresh during the round keeps looking down")
	wall.refresh()
	await get_tree().create_timer(0.3).timeout
	await _shot("18_tile_view_after_refresh")
	get_tree().quit()


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tests/shots/%s.png" % name)
	print("saved ", name)
