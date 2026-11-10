extends Node
## The robot's shows in pictures: the robot (3D) and a screen (PowerView) at
## moments of the boot and the shutdown. tests/shots/89_power_*.png
##   godot --path godot res://tests/test_power_shot.tscn      (needs a display)

const ARENA := preload("res://scenes/arena.tscn")


func _ready() -> void:
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")
	arena.sound.enabled = false
	var vp := SubViewport.new()                       # the robot, from in front of T01
	vp.size = Vector2i(960, 720)
	vp.world_3d = arena.get_world_3d()
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var cam := Camera3D.new()
	cam.fov = 45.0
	vp.add_child(cam)
	var r: Vector3 = arena.robot.global_position
	cam.position = r + Vector3(0.0, 2.2, 3.6)
	cam.look_at(r + Vector3(0, 1.0, 0))
	var sv := SubViewport.new()                       # a screen
	sv.size = Vector2i(1920, 1080)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	game.set_mode(GameManager.Mode.CLOSED)
	await get_tree().create_timer(1.0).timeout
	for show in [["boot", [3.0, 7.0, 11.0, 14.6, 16.5]], ["shutdown", [1.0, 5.0, 11.0, 15.0, 20.0]]]:
		var at := Retro.game_clock
		game.set_mode(GameManager.Mode.OPEN if show[0] == "boot" else GameManager.Mode.CLOSED)
		for c in sv.get_children():
			c.queue_free()
		sv.add_child(PowerView.new(show[0], at))
		for t in show[1]:
			await get_tree().create_timer(t - (Retro.game_clock - at)).timeout
			var name := "89_power_%s_%04.1f" % [show[0], t]
			vp.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://tests/shots/%s_robot.png" % name))
			sv.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://tests/shots/%s_screen.png" % name))
		while game.power_show != "":
			await get_tree().process_frame
	print("DONE")
	get_tree().quit()
