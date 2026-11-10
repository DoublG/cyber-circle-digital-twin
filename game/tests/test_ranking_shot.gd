extends Node
## Screenshots of the overall ranking: the scoreboard with record + rank, the
## player plates with their rank and the overview page's ranking page.
## Run (with a display): godot --path . --disable-vsync res://tests/test_ranking_shot.tscn

const ARENA := preload("res://scenes/arena.tscn")
const DB_FILE := "res://tests/_ranking.db"


func _ready() -> void:
	for f in [DB_FILE, DB_FILE + "-wal", DB_FILE + "-shm"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	get_window().size = Vector2i(1920, 1080)
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database(DB_FILE)
	game.intro_time = 1.0
	game.auto_start_delay = 0.0
	game.picker.random_rounds = false
	game.picker.round_types = [CycloneRound]
	var db: GameDb = game.db
	var gid := db.start_game()
	var ids := {}
	for p in [["Anna", 12, [120, 80]], ["Bram", 7, [95]], ["Cleo", 9, [60, 140, 30]], ["Daan", 13, [75]],
			["Eva", 11, [110]], ["Fien", 10, [40]], ["Gijs", 8, [88]], ["Hanne", 12, [15]]]:
		ids[p[0]] = db.add_player(p[0], "#ffcc00", p[1])
		for score in p[2]:
			db.save_result(gid, {"player_id": ids[p[0]], "tile": 1, "name": p[0], "score": score, "lives": 0,
				"exterminated": true})
	game.standings.load_records()
	for p in [[1, "Anna"], [2, "Bram"], [3, "Gijs"], [4, "Daan"]]:
		arena.players.join(p[0], p[1], 10, ids[p[1]])
	await get_tree().create_timer(1.0).timeout
	game.start_game()
	while game.state != GameManager.State.PLAYING:
		await get_tree().process_frame
	game.scores[2] = 101                       # Bram is beating his record
	game.scores[1] = 64
	game.scores[3] = 30
	for id in [1, 2, 3, 4]:
		arena.screen_wall.update_player(id)
	await get_tree().create_timer(3.0).timeout
	await _shot("28_plates_with_rank")
	var cyc: CycloneRound = game.current       # places: Anna 1, Bram and Gijs 2, Daan last (on his last life)
	for p in [[1, 5], [2, 3], [3, 3], [4, 1]]:
		cyc.state[p[0]].best = p[1]
	arena.tiles[3].health = 1
	game.skip()                                # end the round: UITSLAG, then the scoreboard
	while not (not arena.screen_wall.shared_views.is_empty() and arena.screen_wall.shared_views[0] is RankingView):
		await get_tree().process_frame
	await get_tree().create_timer(4.0).timeout # (rows and lives badges in)
	await _shot("28b_uitslag")
	while not arena.screen_wall.shared_views[0] is ScoreboardView:
		await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	await _shot("29_scoreboard_record_rank")
	var page: ObserverView = _find_page(arena.screen_wall)
	page.show_scene("scores")                  # the ranking page
	page._update()
	await RenderingServer.frame_post_draw
	page.get_viewport().get_texture().get_image().save_png("res://tests/shots/30_overview_ranking.png")
	print("saved 30_overview_ranking")
	get_tree().quit()


func _find_page(n: Node) -> ObserverView:
	if n is ObserverView:
		return n
	for c in n.get_children():
		var f := _find_page(c)
		if f:
			return f
	return null


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tests/shots/%s.png" % name)
	print("saved ", name)
