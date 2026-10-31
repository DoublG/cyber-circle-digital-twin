extends Node
## Screenshot of an extermination: the death clip in the player's (narrow,
## 3 side by side) view, the overview page catching the robot firing and the
## tile being electrocuted / exploding, then the tile free again.
## Run (with a display): godot --path . res://tests/test_death_shot.tscn

const ARENA := preload("res://scenes/arena.tscn")


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	var arena: Node3D = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")                 # screenshots: no database writes
	game.intro_time = 1.0
	game.auto_start_delay = 0.0
	game.round_types = [SimonRound]
	for p in [[1, "Anna", 12], [2, "Bram", 7], [3, "Cleo", 9]]:
		arena.apply_command({"tile": p[0], "join": p[1], "age": p[2]})
	await get_tree().create_timer(1.0).timeout
	game.start_game()
	while not (game.state == GameManager.State.PLAYING):
		await get_tree().process_frame
	await get_tree().create_timer(3.0).timeout
	arena.tiles[1].health = 1
	arena.apply_command({"attacked": [2]})          # the robot hits Bram: 0 lives
	while not arena.tiles[1].is_dead:
		await get_tree().process_frame
	await get_tree().create_timer(0.6).timeout
	await _shot("23_doomed_blinking")
	var page: ObserverView = _find_page(arena.screen_wall)
	var tile: CyberTile = arena.tiles[1]
	var t0 := 0.0
	while not tile.get_children().any(func(c): return c is MeshInstance3D and c.mesh is ImmediateMesh) and t0 < 20.0:
		await get_tree().process_frame                # wait for the electrocution
		t0 += get_process_delta_time()
	await get_tree().create_timer(0.4).timeout
	await RenderingServer.frame_post_draw          # same frame: clip in Bram's view + overview
	get_viewport().get_texture().get_image().save_png("res://tests/shots/24_death_clip.png")
	page.get_viewport().get_texture().get_image().save_png("res://tests/shots/26_overview_electrocuted.png")
	while not tile.get_children().any(func(c): return c is CPUParticles3D):
		await get_tree().process_frame                # the explosion
	await get_tree().create_timer(0.15).timeout
	await RenderingServer.frame_post_draw
	page.get_viewport().get_texture().get_image().save_png("res://tests/shots/27_overview_explosion.png")
	print("saved 24_death_clip, 26_overview_electrocuted, 27_overview_explosion")
	while arena.is_playing(2):
		await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	await _shot("25_tile_free_again")
	get_tree().quit()


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
