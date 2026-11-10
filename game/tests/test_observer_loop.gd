extends Node
## The overview page's loop for the people watching: scores -> every game
## explained (the one being played first) -> how to join -> the robot up
## close -> scores ...; an extermination clears the page. Screenshots in
## tests/shots/8x_*.
## Run (with a display): godot --path . --disable-vsync --fixed-fps 30 res://tests/test_observer_loop.tscn

const ARENA := preload("res://scenes/arena.tscn")

var arena: Arena
var game: GameManager
var page: ObserverView

var _fails := 0


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	arena = ARENA.instantiate()
	add_child(arena)
	game = arena.game
	game.use_database("")
	game.auto_start_delay = 0.0
	game.picker.random_rounds = false
	game.picker.round_types = [SimonRound]
	page = _find_page(arena.screen_wall)
	page.scenes = [["scores", 3.0], ["games", 1.5], ["join", 3.0], ["robot", 4.0]]
	page.show_scene("scores")
	for i in 5:
		arena.players.join([1, 3, 6, 9, 12][i], ["Anna", "Bram", "Cleo", "Daan", "Eva"][i], 12)
	await _wait(1.0)
	check(page._under.all(func(c): return c.visible) and not page._center.visible, "scores: players, events, ranking")
	await _shot("80_overview_scores")
	await _until(func(): return page.scene_name() == "games")
	await _wait(0.3)
	check(page._center.visible and page._center_sub.text.begins_with("DE SPELLEN  1/"),
		"games: the first game explained (%s)" % page._center_sub.text)
	await _shot("81_overview_games")
	var seen := {}
	while page.scene_name() == "games":
		seen[page._center_title.text] = true
		await get_tree().process_frame
	check(seen.size() == RoundPicker.ROUND_TYPES.size(),
		"games: all %d explained: %s" % [RoundPicker.ROUND_TYPES.size(), seen.keys()])
	check(page.scene_name() == "join" and page._center_title.text == "HOE DOE JE MEE?", "join: the steps")
	await _wait(0.5)
	await _shot("82_overview_join")
	await _until(func(): return page.scene_name() == "robot")
	await _wait(3.0)
	var cam: Vector3 = arena.observer.global_position
	check(not page._center.visible and page._under.all(func(c): return not c.visible), "robot: nothing over the camera")
	check(Vector2(cam.x, cam.z).length() < 4.0,
		"robot: the camera close around the robot (%.1f m)" % Vector2(cam.x, cam.z).length())
	await _shot("83_overview_robot")
	await _until(func(): return page.scene_name() == "scores")
	check(true, "back to the scores: a loop")

	print("--- during a round: the game being played first")
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	page.show_scene("games")
	await _wait(0.2)
	check(page._center_sub.text == "NU BEZIG" and page._center_title.text == "SIMON ZEGT", "games: Simon first, NU BEZIG")
	await _shot("84_overview_games_now")
	print("--- an extermination clears the page")
	page.scenes[1][1] = 30.0
	arena.tiles[5].health = 0
	await _until(func(): return not arena.dying.is_empty())
	await _wait(0.5)
	check(not page._center.visible and page._under.all(func(c): return not c.visible),
		"extermination: everything steps aside")
	await _wait(1.5)
	await _shot("85_overview_extermination")
	print("DONE: %d failure(s)" % _fails)
	get_tree().quit()


func _shot(file: String) -> void:
	await RenderingServer.frame_post_draw
	page.get_viewport().get_texture().get_image().save_png("res://tests/shots/%s.png" % file)
	print("saved ", file)


func _find_page(n: Node) -> ObserverView:
	if n is ObserverView:
		return n
	for c in n.get_children():
		var f := _find_page(c)
		if f:
			return f
	return null


func _until(cond: Callable, timeout := 60.0) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		_fails += 1
