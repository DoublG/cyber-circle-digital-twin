extends Node
## Mobile players (drones, tiles 14-18): register as mobile, activate with the
## 4 icons, fly from the park into the ring; attack (bolt to the robot), get
## hit (bolt to the drone, -1 life), shield, a quiz round with the scoreboard
## labels (M1, M2), extermination (spiral down, explosion) and back to the
## park once the player left. Records a camera in the room frame by frame
## (user://frames_drones/) and saves screenshots (tests/shots/7x_*).
## Run (with a display): godot --path . --disable-vsync --fixed-fps 30 res://tests/test_drones.tscn

const ARENA := preload("res://scenes/arena.tscn")
const FRAMES := "user://frames_drones/"
const FPS := 30

var _fails := 0
var _frame := 0
var _vp: SubViewport
var _cam: Camera3D
var game: GameManager
var arena: Node3D


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/shots"))
	var dir := ProjectSettings.globalize_path(FRAMES)
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + f)
	arena = ARENA.instantiate()
	add_child(arena)
	game = arena.game
	game.use_database("")
	game.intro_time = 1.0
	game.result_time = 3.0
	game.scoreboard_time = 4.0
	game.auto_start_delay = 0.0
	game.random_rounds = false
	game.round_types = [QuizRound, CycloneRound]
	# a camera in the room, rendered on its own (the window shows the screens)
	_vp = SubViewport.new()
	_vp.size = Vector2i(1280, 720)
	_vp.world_3d = arena.get_world_3d()
	_vp.msaa_3d = Viewport.MSAA_2X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS   # (not on screen: render anyway)
	add_child(_vp)
	_cam = Camera3D.new()
	_cam.fov = 62.0
	_vp.add_child(_cam)
	_look(Vector3(0, 3.3, 5.6), Vector3(0, 1.5, 0))
	await _wait(0.5)

	print("--- 18 places: 13 floor tiles, 5 drones")
	check(arena.tiles.size() == 18, "18 tiles (%d)" % arena.tiles.size())
	check(arena.tiles.slice(13).all(func(t): return t is DroneTile), "14-18 are drones")
	check(Retro.tile_label(13) == "T13" and Retro.tile_label(14) == "M1" and Retro.tile_label(18) == "M5", "labels T13 / M1 / M5")
	var parked: Vector3 = arena.tiles[13].global_position
	check(parked.y > 3.0, "a free drone is parked high up (%.1f m)" % parked.y)

	print("--- 3 floor players, 2 mobile players")
	for p in [[1, "Anna"], [5, "Bram"], [9, "Cleo"]]:
		arena.join(p[0], p[1], 12)
	arena.apply_command({"register": "Zoe", "color": "#ffffff", "age": 12})          # (no tile: a floor tile)
	var zoe: int = arena.tiles.filter(func(t): return arena.is_pending(t.tile_id)).front().tile_id
	check(zoe <= 13, "a registration without a tile never gets a drone (T%02d)" % zoe)
	arena.leave(zoe)
	arena.apply_command({"tile": 14, "register": "Mila", "color": "#ff44cc", "age": 12})   # the operator picks the drone
	arena.apply_command({"tile": 15, "register": "Ravi", "color": "#44ffaa", "age": 7})
	var mobile: Array = arena.tiles.filter(func(t): return t is DroneTile and arena.is_pending(t.tile_id)) \
		.map(func(t): return t.tile_id)
	check(mobile == [14, 15], "mobile players on the drones the operator chose: %s" % [mobile])
	var floor_free: int = arena.tiles.filter(func(t): return not (t is DroneTile) and arena.is_pending(t.tile_id)).size()
	check(floor_free == 0, "no floor tile taken by a mobile player")
	await _record(1.5)
	for id in mobile:                               # activation: the 4 icons on their handheld tile
		for b in CyberTile.BUTTONS:
			arena.tiles[id - 1].press_button(b)
	await _record(3.5)
	var m1: DroneTile = arena.tiles[mobile[0] - 1]
	var m2: DroneTile = arena.tiles[mobile[1] - 1]
	check(arena.is_playing(m1.tile_id) and arena.is_playing(m2.tile_id), "both mobile players playing")
	var r := Vector2(m1.global_position.x, m1.global_position.z).length()
	check(absf(r - DroneTile.ORBIT_R) < 0.2 and absf(m1.global_position.y - DroneTile.ORBIT_Y) < 0.3,
		"in the ring: %.2f m out, %.2f m up" % [r, m1.global_position.y])
	await _shot_room("70_drones_ring")

	print("--- the mobile screens: only who plays, scaled up; the camera follows the drone")
	var wall: ScreenWall = arena.screen_wall
	check(wall._screens.size() == 7, "5 floor screens + 2 mobile screens (%d)" % wall._screens.size())
	for k in [5, 6]:
		_check_mobile_screen(wall, k)
	for d in [m1, m2]:
		var cam: Camera3D = wall._huds[d.tile_id].cell.get_meta(&"camera")
		var robot_head: Vector3 = arena.robot.global_position + Vector3(0, 1.3, 0)
		var on_screen := func(p: Vector3) -> bool:
			if cam.is_position_behind(p):
				return false
			var v := cam.unproject_position(p) / Vector2(cam.get_viewport().size)
			return v.x > 0.1 and v.x < 0.9 and v.y > 0.05 and v.y < 0.95
		check(on_screen.call(robot_head), "%s's camera sees the robot" % Retro.tile_label(d.tile_id))
		var robot_base: Vector3 = arena.robot.global_position
		check(on_screen.call(robot_base) and on_screen.call(d.global_position), "%s's camera: the whole robot and its own drone in view" % Retro.tile_label(d.tile_id))
		var vs := Vector2(cam.get_viewport().size)
		var drone_top: float = cam.unproject_position(d.global_position + Vector3(0, 0.1, 0)).y / vs.y
		var drone_r: float = absf(cam.unproject_position(d.global_position + cam.global_basis.x * 0.5).x - cam.unproject_position(d.global_position).x) / vs.y
		var base_y: float = cam.unproject_position(robot_base).y / vs.y
		check(drone_top - drone_r * 0.4 > base_y, "%s: the drone under the robot, not in front of it (drone %.2f, robot foot %.2f)"
			% [Retro.tile_label(d.tile_id), drone_top, base_y])
	await _shot_view(wall._screens[5], "74_mobile_screen_two")
	var noor := 16
	arena.join(noor, "Noor", 12)                   # alone on the other mobile screen: the whole screen
	await _record(2.0)
	_check_mobile_screen(wall, 6)
	await _shot_view(wall._screens[6], "75_mobile_screen_one")
	arena.leave(noor)

	print("--- attack together with the floor players")
	var sides_hit := []
	arena.robot.hit_taken.connect(func(s): sides_hit.append(s))
	arena.players_attack([1, 5, 9, m1.tile_id, m2.tile_id])
	await _record(2.5)
	check(sides_hit.size() == 5, "the robot takes the combined hit, drones included (%d sides)" % sides_hit.size())

	print("--- the robot hits back: Mila -1 life, Ravi's shield blocks")
	m2.shielded = true
	var lives := m1.health
	_look(Vector3(m1.global_position.x, 0, m1.global_position.z).normalized() * 5.4 + Vector3(0, 3.0, 0), Vector3(0, 1.9, 0))
	arena.robot_attack([m1.tile_id], Color(1.0, 0.1, 0.05), [m2.tile_id])
	await _record(3.5)
	check(m1.health == lives - 1, "Mila hit: %d -> %d lives" % [lives, m1.health])
	check(m2.health == m2.max_health, "Ravi shielded: no life lost")
	m2.shielded = false
	await _shot_room("71_drone_hit")

	print("--- a quiz round: the drones answer like tiles")
	_look(Vector3(0, 3.3, 5.6), Vector3(0, 1.5, 0))
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	var quiz: QuizRound = game.current
	check(m1.tile_id in quiz.players and m2.tile_id in quiz.players, "drones in the round")
	await _until(func(): return quiz._phase == "question")
	var correct := int(quiz._questions[quiz._index].correct)
	for id in [1, 5, m1.tile_id]:
		arena.tiles[id - 1].press_button(QuizRound.ANSWER_BUTTONS[correct])
	arena.tiles[m2.tile_id - 1].press_button(QuizRound.ANSWER_BUTTONS[(correct + 1) % 4])
	quiz._phase_left = 0.3
	await _record_until(func(): return quiz._phase == "reveal")
	await _record(3.0)
	await _until(func(): return game.state == GameManager.State.SCOREBOARD and game._lives_shown, 30.0)
	var board: ScoreboardView = game.screen_wall.shared_views[0]
	var labels: Array = board._rows.map(func(e): return (e.panel.get_child(0).get_child(2) as Label).text)
	check(Retro.tile_label(m1.tile_id) in labels and Retro.tile_label(m2.tile_id) in labels, "scoreboard tiles: %s" % [labels])
	await _shot_view(board, "72_drones_scoreboard")
	print("--- Cyclone (on the tile): the drone camera swings over the drone and looks down")
	game.skip()
	await _until(func(): return game.state == GameManager.State.PLAYING and game.current is CycloneRound, 30.0)
	await _wait(arena.screen_wall.tilt_delay + arena.screen_wall.tilt_time + 0.5)
	var cell: Control = arena.screen_wall._huds[m1.tile_id].cell
	var rig: Node = cell.get_children().filter(func(c): return c is ScreenWall.DroneCam).front()
	check(is_equal_approx(rig.down, 1.0), "drone camera looking down (%.2f)" % rig.down)
	var top_cam: Camera3D = cell.get_meta(&"camera")
	var v := top_cam.unproject_position(m1.global_position) / Vector2(top_cam.get_viewport().size)
	check(not top_cam.is_position_behind(m1.global_position) and v.distance_to(Vector2(0.5, 0.5)) < 0.2,
		"the drone in the middle of the view (%.2f, %.2f)" % [v.x, v.y])
	await _shot_view(arena.screen_wall._huds[m1.tile_id].cell, "76_mobile_screen_tile_game")
	game.stop_game()

	print("--- Mila exterminated: the drone spirals down and explodes")
	await _wait(0.5)
	if not arena.is_playing(m1.tile_id):           # (the stopped game let everyone go)
		arena.join(m1.tile_id, "Mila", 12)
		await _record(3.0)
	_look(Vector3(m1.global_position.x, 0, m1.global_position.z).normalized().rotated(Vector3.UP, 0.5) * 5.6 + Vector3(0, 3.6, 0), Vector3(0, 1.0, 0))
	arena.exterminate([m1.tile_id])
	m1.health = 0
	await _record_until(func(): return m1._falling)
	await _record(1.2)
	await _shot_room("73_drone_falling")
	await _record_until(func(): return m1._gone, 15.0)
	check(m1._gone and not m1.visible, "crashed and gone")
	await _record(1.5)
	arena.leave(m1.tile_id)
	await _record(1.0)
	check(m1.visible and m1.idle, "back in the park after the player left")
	await _record(2.0)
	print("frames: %d in %s" % [_frame, dir])
	print("DONE: %d failure(s)" % _fails)
	get_tree().quit()


## A mobile screen: a view for every mobile player of its group who plays
## (nobody: the free slots), side by side from left to right, equal, filling the screen.
func _check_mobile_screen(wall: ScreenWall, k: int) -> void:
	var ids: Array = wall.groups()[k]
	var playing := ids.filter(func(id): return arena.is_playing(id))
	var cells := playing.filter(func(id): return wall._huds.has(id)).map(func(id): return wall._huds[id].cell)
	var others := ids.filter(func(id): return wall._huds.has(id) and id not in playing)
	check(cells.size() == playing.size() and others.is_empty(), "screen %d %s: views for %s only" % [k + 1, ids, playing])
	if cells.is_empty():
		return
	var w: float = (1920.0 - 10.0 * (cells.size() + 1)) / cells.size()
	check(cells.all(func(c): return absf(c.size.x - w) < 3.0 and c.size.y > 1050.0),
		"screen %d: %d view(s) side by side, %.0f px wide, full height (%s)" % [k + 1, cells.size(), w, cells.map(func(c): return c.size.round())])


func _look(from: Vector3, at: Vector3) -> void:
	_cam.position = from
	_cam.look_at(at)


func _capture() -> void:
	await RenderingServer.frame_post_draw
	_vp.get_texture().get_image().save_jpg(ProjectSettings.globalize_path(FRAMES) + "%05d.jpg" % _frame, 0.9)
	_frame += 1


func _record(seconds: float) -> void:
	for i in int(seconds * FPS):
		await _capture()


func _record_until(cond: Callable, timeout := 30.0) -> void:
	var n := 0
	while not cond.call() and n < int(timeout * FPS):
		await _capture()
		n += 1


func _shot_room(file: String) -> void:
	await RenderingServer.frame_post_draw
	_vp.get_texture().get_image().save_png("res://tests/shots/%s.png" % file)
	print("saved ", file)


func _shot_view(view: Control, file: String) -> void:
	await RenderingServer.frame_post_draw
	view.get_viewport().get_texture().get_image().save_png("res://tests/shots/%s.png" % file)
	print("saved ", file)


func _until(cond: Callable, timeout := 60.0) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func check(ok: bool, what: String) -> void:
	if ok:
		print("    [ok] ", what)
	else:
		_fails += 1
		print("    [FAIL] ", what)
