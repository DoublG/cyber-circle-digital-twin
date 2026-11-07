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
	# the diagnosis: without MQTT the bridge reports a simulation ...
	ok = wall.diag.has("broker") and wall.diag.broker == "" and not wall.diag.mqtt
	print("    [%s] diagnosis without MQTT: simulated tiles" % ["ok" if ok else "FAIL"])
	# ... a tile's hello and place (as on MQTT) become that place's entry ...
	var mqtt: MqttBridge = arena.get_node("Mqtt")
	mqtt._on_device(PackedStringArray(["3c71bf0a1b05", "hello"]), JSON.stringify({"fw": "1.4.0", "net": "ethernet",
		"ip": "10.0.0.35", "link": "100M full"}).to_utf8_buffer())
	mqtt._on_device(PackedStringArray(["3c71bf0a1b05", "config"]), JSON.stringify({"tile": 5}).to_utf8_buffer())
	mqtt._on_device(PackedStringArray(["3c71bf0a1b99", "hello"]), JSON.stringify({"fw": "1.4.0"}).to_utf8_buffer())
	var d := mqtt.diagnosis()
	ok = d.tiles.has("5") and d.tiles["5"].online and d.tiles["5"].ip == "10.0.0.35" and d.unplaced == ["3c71bf0a1b99"]
	print("    [%s] a tile's hello + place: in the diagnosis (online, address), the other unplaced" % ["ok" if ok else "FAIL"])
	# ... and an installation as the master would report it with MQTT: the screenshots
	var tiles := {}
	for id in range(1, 19):
		if id in [3, 15]:
			continue                                          # (no physical tile placed there)
		tiles[str(id)] = {"device": "3c71bf0a1b%02x" % id, "fw": "1.4.0", "net": "ethernet", "ip": "10.0.0.%d" % (30 + id),
			"link": "100M full", "age": 4.0, "online": id != 2}
	wall.set_diag({"mqtt": true, "broker": "ws://10.0.0.1:9001", "tiles": tiles, "unplaced": ["3c71bf0a1b99"]})
	arena.tiles[0].press_button(&"Cross")
	arena.tiles[5].press_button(&"Square")
	await get_tree().create_timer(0.3).timeout
	ok = wall.last_press.has(1) and wall.last_press[1].button == &"Cross"
	print("    [%s] a press is remembered for the test screens" % ["ok" if ok else "FAIL"])
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
