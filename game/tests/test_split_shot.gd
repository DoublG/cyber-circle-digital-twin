extends Node
## Screenshot of the split-screen layouts in a round on the tile (Simon):
## screen 1: 3 players; screen 2: 2 players + a free tile; screen 3: 1 player,
## an invited tile and a free one; screen 4: only an invite (overview + slots).
## Run (with a display): godot --path . res://tests/test_split_shot.tscn

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
	for p in [[1, "Anna", 12], [2, "Bram", 7], [3, "Cleo", 9], [4, "Daan", 13],
			[5, "Evelientje", 8], [7, "Fien", 10]]:
		arena.apply_command({"tile": p[0], "join": p[1], "age": p[2]})
	await get_tree().create_timer(1.0).timeout
	game.start_game()
	# invites (registered in the app, not activated yet) arrive during the game
	arena.apply_command({"tile": 8, "register": "Lotte", "color": "#ff8800", "age": 9})
	arena.apply_command({"tile": 10, "register": "Jan-Willem", "color": "#33ccff", "age": 11})
	while not (game.state == GameManager.State.PLAYING):
		await get_tree().process_frame
	var wall: ScreenWall = game.screen_wall
	await get_tree().create_timer(wall.tilt_delay + wall.tilt_time * 0.5).timeout
	await _shot("19_split_tilting")
	await get_tree().create_timer(wall.tilt_time * 0.5 + 2.5).timeout
	for id in [1, 4, 7]:
		wall.popup(id, "+4", Retro.GOOD)
	await get_tree().create_timer(0.15).timeout
	await _shot("20_split_on_tile")
	get_tree().quit()


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tests/shots/%s.png" % name)
	print("saved ", name)
