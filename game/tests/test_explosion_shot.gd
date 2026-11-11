extends Node
## Close-ups of a hit and an explosion on a tile (flash, glow, shockwave,
## debris): tests/shots/80_* .. 81_*; then the room's lights and lightning
## from across the room (lobby, charge, extermination, round start): 82_*;
## a shield block (83_*), and a drone: the robot tilts its eye gun up at it,
## a hit, its extermination (84_*).
## Run (with a display): godot --path . --disable-vsync res://tests/test_explosion_shot.tscn

const ARENA := preload("res://scenes/arena.tscn")

var arena: Arena
var cam: Camera3D
var vp: SubViewport


func _ready() -> void:
	get_window().size = Vector2i(1280, 720)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/shots"))
	arena = ARENA.instantiate()
	add_child(arena)
	arena.game.use_database("")
	arena.sound.enabled = false
	vp = SubViewport.new()                  # the close-up, rendered on its own (the window shows the screens)
	vp.size = Vector2i(1280, 720)
	vp.world_3d = arena.get_world_3d()
	vp.msaa_3d = Viewport.MSAA_2X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	cam = Camera3D.new()
	cam.fov = 55.0
	vp.add_child(cam)
	await get_tree().create_timer(1.0).timeout
	var tile: CyberTile = arena.tiles[0]
	_look_at(tile)
	await get_tree().create_timer(0.5).timeout
	tile.play_hit()
	for t in [0.05, 0.2]:
		await get_tree().create_timer(t).timeout
		_shot("80_hit_%03d" % int(t * 1000))
	await get_tree().create_timer(2.0).timeout
	tile._explode()
	var at := 0.0
	for t in [0.05, 0.25, 0.6, 1.2, 2.2]:
		await get_tree().create_timer(t - at).timeout
		at = t
		_shot("81_explosion_%04d" % int(t * 1000))
	# the room: wide, across the robot to tile 1
	cam.global_position = Vector3(0, 2.4, 5.8)
	cam.look_at(Vector3(0, 2.0, -3.0))
	cam.fov = 70.0
	arena.game.modes.change(GameManager.Mode.OPEN)
	await get_tree().create_timer(2.0).timeout
	_shot("82_lights_lobby")
	arena.cue(&"charge", 0, {"tiles": [1]})
	await get_tree().create_timer(0.3).timeout
	_shot("82_lights_charge")
	await get_tree().create_timer(1.5).timeout
	arena.cue(&"death", 1)
	await get_tree().create_timer(0.3).timeout
	_shot("82_lights_death")
	await get_tree().create_timer(3.0).timeout
	arena.cue(&"zap", 1)
	await get_tree().create_timer(0.3).timeout
	_shot("82_lights_zap")
	await get_tree().create_timer(2.0).timeout
	arena.cue(&"round_start", 0, {"round": "quiz"})
	await get_tree().create_timer(0.45).timeout
	_shot("82_lights_round_start")
	# a shield block on tile 2
	var t2: CyberTile = arena.tiles[1]
	t2.shielded = true
	_look_at(t2)
	cam.fov = 55.0
	await get_tree().create_timer(1.0).timeout
	t2.play_block()
	at = 0.0
	for t in [0.08, 0.5, 1.1]:
		await get_tree().create_timer(t - at).timeout
		at = t
		_shot("83_shield_%04d" % int(t * 1000))
	# a drone: into the ring, the robot aims up at it, a hit, then exterminated
	arena.apply_command({"tile": 14, "join": "Mila"})
	await get_tree().create_timer(6.0).timeout
	var drone: CyberTile = arena.tiles[13]
	var dp := drone.global_position
	cam.global_position = Vector3(dp.x, 0, dp.z).normalized().rotated(Vector3.UP, 0.9) * 3.6 + Vector3(0, 1.6, 0)
	cam.look_at((dp + Vector3(0, 1.4, 0)) * 0.5)
	arena.robot.look_at_point(dp)
	var waited := 0.0
	while not arena.robot.is_facing_target() and waited < 5.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	print("eye pitch at the drone: %.1f deg (drone %.2f m up)" % [arena.robot.get_eye_pitch(), dp.y])
	_shot("84_drone_aim")
	drone.play_hit()
	await get_tree().create_timer(0.12).timeout
	_shot("84_drone_hit")
	await get_tree().create_timer(2.0).timeout
	cam.global_position = Vector3(0, 7.0, 0) + Vector3(dp.x, 0, dp.z).normalized() * -4.0   # high, across the robot
	cam.look_at(Vector3(dp.x, 0, dp.z) * 0.8)
	cam.fov = 65.0
	arena.apply_command({"tile": 14, "health": 0})
	waited = 0.0
	while not drone.get("_falling") and waited < 12.0:
		await get_tree().create_timer(0.05).timeout
		waited += 0.05
	await get_tree().create_timer(1.0).timeout
	_shot("84_drone_falling")
	while not drone.get("_gone") and waited < 20.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	var crash := drone.global_position                     # where it came down
	cam.global_position = crash + Vector3(crash.x, 0, crash.z).normalized() * -3.0 + Vector3(0, 2.2, 0)
	cam.look_at(crash + Vector3(0, 0.3, 0))
	await get_tree().create_timer(0.1).timeout
	_shot("84_drone_crashed")
	print("DONE")
	get_tree().quit()


func _look_at(tile: Node3D) -> void:
	var p := tile.global_position
	var out := Vector3(p.x, 0, p.z).normalized()
	cam.global_position = p + out * 2.8 + Vector3(0, 1.6, 0)
	cam.look_at(p + Vector3(0, 0.3, 0))


func _shot(name: String) -> void:
	vp.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://tests/shots/%s.png" % name))
	print("saved ", name)
