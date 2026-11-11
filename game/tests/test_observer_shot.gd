extends Node
## Screenshots of the overview page for visitors (floating observer camera,
## rules, scores, event feed) during a Cyclone round, plus the full preview.
## Run (with a display): godot --path . --disable-vsync res://tests/test_observer_shot.tscn

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
	arena.apply_command({"tile": 8, "register": "Lotte", "color": "#ff8800", "age": 9})
	while not (game.state == GameManager.State.PLAYING):
		await get_tree().process_frame
	# a few presses: Anna on red, the others whenever
	var fw: TileFirmware = arena.tiles[0].get_node("Firmware")
	var t := 0.0
	while t < 6.0:
		if fw._phase == "run" and fw._offset() == 0:
			arena.tiles[0].press_button(&"Cross")
		await get_tree().process_frame
		t += get_process_delta_time()
	for id in [2, 4]:
		arena.tiles[id - 1].press_button(&"Square")
	arena.tiles[6].health = 0          # Eva knocked out: the observer flies to her tile
	await get_tree().create_timer(2.5).timeout
	var page: ObserverView = _find_page(arena.screen_wall)
	await RenderingServer.frame_post_draw
	page.get_viewport().get_texture().get_image().save_png("res://tests/shots/21_overview_page.png")
	get_viewport().get_texture().get_image().save_png("res://tests/shots/22_preview_all.png")
	game.result_time = 1.0
	game.skip()                        # end the round: the scoreboard on the page too
	while not (game.state == GameManager.State.SCOREBOARD and page._board):
		await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	await RenderingServer.frame_post_draw
	page.get_viewport().get_texture().get_image().save_png("res://tests/shots/23_overview_scoreboard.png")
	print("saved 21_overview_page, 22_preview_all, 23_overview_scoreboard")
	get_tree().quit()


func _find_page(n: Node) -> ObserverView:
	if n is ObserverView:
		return n
	for c in n.get_children():
		var f := _find_page(c)
		if f:
			return f
	return null
