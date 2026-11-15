extends Node
## Screenshots of players' names in other scripts (accents, Cyrillic, Greek,
## Arabic, Chinese, Hebrew, Hindi, emoji): the player plates and the
## scoreboard. The game's font draws Latin, Cyrillic, Greek and Arabic; the
## rest comes from the system's fonts (the Pis: fonts-noto-*, install_game.sh).
## Run (with a display): godot --path . --disable-vsync res://tests/test_names_shot.tscn

const ARENA := preload("res://scenes/arena.tscn")
const NAMES := ["Zoë", "Çağla", "Иван", "Νίκος", "محمد", "李明", "שרה", "आर्या", "Lot 👩‍💻"]


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")
	game.intro_time = 1.0
	game.auto_start_delay = 0.0
	game.picker.random_rounds = false
	game.picker.round_types = [CycloneRound]
	for i in NAMES.size():
		arena.players.join(i + 1, NAMES[i], 10)
	await get_tree().create_timer(1.0).timeout
	game.start_game()
	while game.state != GameManager.State.PLAYING:
		await get_tree().process_frame
	await get_tree().create_timer(3.0).timeout
	await _shot("names_plates")
	game.result_time = 0.0
	game.skip()
	while not (not arena.screen_wall.shared_views.is_empty() and arena.screen_wall.shared_views[0] is ScoreboardView):
		await get_tree().process_frame
	await get_tree().create_timer(1.0).timeout
	await _shot("names_scoreboard")
	get_tree().quit()


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tests/shots/%s.png" % name)
	print("saved ", name)
