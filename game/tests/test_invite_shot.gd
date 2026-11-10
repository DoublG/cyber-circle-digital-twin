extends Node
## The invite on a player's screen while they activate their tile: the tile
## drawn from above, pressed icons greyed out with a tick, the count.
## tests/shots/85_invite_*.  Run (with a display): godot --path . --disable-vsync res://tests/test_invite_shot.tscn

const ARENA := preload("res://scenes/arena.tscn")


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	arena.game.use_database("")
	arena.sound.enabled = false
	arena.game.set_mode(GameManager.Mode.OPEN)
	await get_tree().create_timer(1.0).timeout
	arena.apply_command({"tile": 2, "register": "Anna", "color": "#ff8800"})
	await get_tree().create_timer(1.0).timeout
	_shot("85_invite_0of4")
	for b in ["Square", "Cross"]:
		arena.apply_command({"tile": 2, "press": b})
		await get_tree().create_timer(0.3).timeout
	await get_tree().create_timer(0.5).timeout
	_shot("85_invite_2of4")
	# the slot at its real size on a screen with 3 players (627 x 1060), on its own
	var vp := SubViewport.new()
	vp.size = Vector2i(627, 1060)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var slot := TileSlot.new()
	slot.tile_id = 2
	slot.player = "Anna"
	slot.color = Color("#ff8800")
	slot.tile = arena.tiles[1]
	slot.size = Vector2(627, 1060)
	vp.add_child(slot)
	await get_tree().create_timer(0.5).timeout
	vp.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://tests/shots/85_invite_slot_full.png"))
	print("saved 85_invite_slot_full")
	print("DONE")
	get_tree().quit()


func _shot(name: String) -> void:
	get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path("res://tests/shots/%s.png" % name))
	print("saved ", name)
