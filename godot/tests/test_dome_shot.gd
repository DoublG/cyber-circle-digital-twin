extends Node
## The dome: its texture, the lights and where the walls meet it.
## tests/shots/88_dome_*.png

const ARENA := preload("res://scenes/arena.tscn")


func _ready() -> void:
	var arena: Node3D = ARENA.instantiate()
	add_child(arena)
	arena.game.use_database("")
	arena.sound.enabled = false
	var vp := SubViewport.new()
	vp.size = Vector2i(1600, 900)
	vp.world_3d = arena.get_world_3d()
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var cam := Camera3D.new()
	cam.fov = 70.0
	vp.add_child(cam)
	for shot in [["88_dome_junction", Vector3(0, 2.2, 1.5), Vector3(0, 3.6, -6.0)],
			["88_dome_up", Vector3(0, 1.8, 2.5), Vector3(0, 8.0, -1.0)],
			["88_dome_close", Vector3(1.5, 2.8, -3.2), Vector3(3.0, 3.9, -5.6)]]:
		cam.position = shot[1]
		cam.look_at(shot[2])
		await get_tree().create_timer(0.8).timeout
		vp.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://tests/shots/%s.png" % shot[0]))
	print("DONE")
	get_tree().quit()
