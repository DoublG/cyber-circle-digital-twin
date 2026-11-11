extends Node
## Diagnostic: the floor from straight above with every floor tile hidden
## (only the mobile places installed): shows any baked trace of the tiles,
## ducts or cables (tests/shots/87_floor_empty.png); then the room's consoles
## from the middle (87_room_door_side / 87_room_far_side).

const ARENA := preload("res://scenes/arena.tscn")


func _ready() -> void:
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	arena.game.use_database("")
	arena.sound.enabled = false
	var vp := SubViewport.new()
	vp.size = Vector2i(1400, 1400)
	vp.world_3d = arena.get_world_3d()
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 7.0
	vp.add_child(cam)
	cam.position = Vector3(0, 5.0, 0)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	await get_tree().create_timer(1.0).timeout
	arena.installation.set_installed([14, 15, 16, 17, 18])
	arena.robot.visible = false
	await get_tree().create_timer(1.0).timeout
	vp.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://tests/shots/87_floor_empty.png"))
	# the consoles: the room from the middle, both halves
	arena.installation.set_installed(range(1, 19))
	arena.robot.visible = true
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	cam.fov = 75.0
	vp.size = Vector2i(1600, 900)
	for side in [["87_room_door_side", Vector3(0, 2.0, -3.2), Vector3(0, 1.3, 6)],
			["87_room_far_side", Vector3(0, 2.0, 3.2), Vector3(0, 1.3, -6)]]:
		cam.position = side[1]
		cam.look_at(side[2])
		await get_tree().create_timer(0.6).timeout
		vp.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://tests/shots/%s.png" % side[0]))
	print("DONE")
	get_tree().quit()
