extends Node
## Rendering cost of one physical screen (screen 1, 3 player views side by
## side), e.g. to judge a Raspberry Pi per screen. Prints averages.
## Run: godot --path . --disable-vsync [--rendering-method gl_compatibility] res://tests/perf_probe.tscn

const ARENA := preload("res://scenes/arena.tscn")


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	arena.game.use_database("")
	for p in [[1, "Anna"], [2, "Bram"], [3, "Cleo"]]:
		arena.apply_command({"tile": p[0], "join": p[1]})
	var wall: ScreenWall = arena.screen_wall
	var vp: SubViewport = wall._screens[0].get_viewport()
	wall.visible = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_viewport().disable_3d = true
	var view := TextureRect.new()
	view.texture = vp.get_texture()
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var layer := CanvasLayer.new()
	layer.add_child(view)
	add_child(layer)
	await get_tree().create_timer(3.0).timeout
	var n := 0
	var sums := [0.0, 0.0, 0.0, 0.0]
	var t0 := Time.get_ticks_usec()
	while n < 120:
		await RenderingServer.frame_post_draw
		sums[0] += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		sums[1] += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		sums[2] += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		n += 1
	var fps := n / ((Time.get_ticks_usec() - t0) / 1e6)
	print("PROBE %s: %.0f fps, %.0f draw calls, %.0f objects, %.0fk triangles per frame (3 views)" % [
		RenderingServer.get_current_rendering_method(), fps, sums[0] / n, sums[1] / n, sums[2] / n / 1000.0])
	get_tree().quit()
