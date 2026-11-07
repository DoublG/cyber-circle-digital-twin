extends Node
## Screenshots of the SETUP test screens: every screen with its number, tiles,
## edges, colour bars and grey ramp (one free, one out of service tile).
## Saves the whole preview and every screen and the overview on its own at
## 1920x1080 (shots/setup_*.png - also usable as still test images).
## Run (with a display): godot --path . --disable-vsync res://tests/test_setup_shot.tscn

const ARENA := preload("res://scenes/arena.tscn")


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/shots"))
	get_window().size = Vector2i(1920, 1080)
	var arena: Node3D = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")
	await get_tree().create_timer(1.0).timeout
	arena.set_tile_enabled(8, false)
	game.set_mode(GameManager.Mode.SETUP)
	await get_tree().create_timer(1.5).timeout
	var wall: ScreenWall = arena.screen_wall
	var patterns := []
	for s in wall._screens + [wall._observer_screen]:
		patterns.append(s.get_node_or_null("TestPattern"))
	var ok := patterns.all(func(p): return p != null)
	print("    [%s] a test pattern on all %d screens + the overview" % ["ok" if ok else "FAIL", wall._screens.size()])
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tests/shots/setup_wall.png")
	for k in wall._screens.size():
		var vp: SubViewport = wall._screens[k].get_viewport()
		vp.get_texture().get_image().save_png("res://tests/shots/setup_screen_%d.png" % (k + 1))
	wall._observer_screen.get_viewport().get_texture().get_image().save_png("res://tests/shots/setup_overview.png")
	game.set_mode(GameManager.Mode.OPEN)
	await get_tree().create_timer(0.5).timeout
	var gone: bool = wall._screens.all(func(s): return s.get_node_or_null("TestPattern") == null)
	print("    [%s] the test pattern is gone when the game opens" % ["ok" if gone else "FAIL"])
	print("DONE")
	get_tree().quit()
