extends Node
## A partial installation (PlayerRegistry.set_installed): only T01-T07 and M1-M2.
## The room from above (the other tiles, their ducts and cables hidden) and
## the screens (no slots for the missing places; a screen without any: how
## to join). tests/shots/86_installed_*.
## Run (with a display): godot --path . --disable-vsync res://tests/test_installed_shot.tscn

const ARENA := preload("res://scenes/arena.tscn")

var fails := 0


func check(ok: bool, what: String) -> void:
	print(("    [ok] " if ok else "    [FAIL] ") + what)
	fails += 0 if ok else 1


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	arena.game.use_database("")
	arena.sound.enabled = false
	arena.game.set_mode(GameManager.Mode.OPEN)
	var vp := SubViewport.new()
	vp.size = Vector2i(1280, 720)
	vp.world_3d = arena.get_world_3d()
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var cam := Camera3D.new()
	vp.add_child(cam)
	cam.position = Vector3(0, 5.2, 4.2)                  # inside the dome, looking down on the circle
	cam.look_at(Vector3.ZERO)
	await get_tree().create_timer(1.0).timeout
	arena.apply_command({"tile": 9, "join": "Weg"})          # a player on a place that goes
	await get_tree().create_timer(0.5).timeout
	arena.players.set_installed([1, 2, 3, 4, 5, 6, 7, 14, 15])
	await get_tree().create_timer(1.0).timeout
	check(not arena.players.is_installed(9) and not arena.players.is_enabled(9), "T09 not installed, not usable")
	check(not arena.players.is_playing(9), "the player on T09 left")
	check(not arena.tiles[8].visible and arena.tiles[0].visible, "T09 hidden, T01 shown")
	check(not arena.tiles[15].visible, "M3 (drone) hidden")
	var floor_model: Node = arena.get_node("Room") if arena.get_node("Room").baked else arena.get_node("Floor")
	var ducts := floor_model.find_child("Tile_Ducts_09", true, false)
	if ducts == null:
		ducts = floor_model.find_child("Spoke_09", true, false)
	check(ducts != null and not ducts.visible, "T09's duct hidden")
	var ring7 := floor_model.find_child("Ring_07", true, false)
	var ring6 := floor_model.find_child("Ring_06", true, false)
	check(ring7 != null and not ring7.visible and ring6.visible, "the duct T07-T08 hidden, T06-T07 shown")
	var groups: Array = arena.screen_wall.groups()
	check(groups[0] == [1, 2, 3] and groups[2] == [7] and groups[3].is_empty(),
		"screens: only installed tiles (%s)" % [groups])
	arena.apply_command({"tile": 2, "register": "Anna", "color": "#ff8800"})
	await get_tree().create_timer(0.5).timeout
	vp.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://tests/shots/86_installed_room.png"))
	get_viewport().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://tests/shots/86_installed_screens.png"))
	print("saved 86_installed_room, 86_installed_screens")
	arena.players.set_installed(range(1, 19))
	await get_tree().create_timer(0.5).timeout
	check(arena.tiles[8].visible and floor_model.find_child("Ring_07", true, false).visible,
		"all back: T09 and its ducts shown")
	print("DONE: %d failure(s)" % fails)
	get_tree().quit()
