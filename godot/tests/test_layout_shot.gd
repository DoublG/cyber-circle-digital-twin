extends Node
## Layout checks (with screenshots): the overview page never overlaps itself
## (13 players, a full event feed, rules / ranking, timer), the GEËXTERMINEERD
## banner stays above the scoreboard rows, and the quiz screen does not move
## when the answers fade in (read -> question).
## Run (with a display): godot --path . --disable-vsync res://tests/test_layout_shot.tscn

const ARENA := preload("res://scenes/arena.tscn")
const NAMES := ["Anna", "Bram", "Cleo", "Daan", "Eva", "Finn", "Gust", "Hanne", "Ilias", "Jules",
	"Kato", "Lotte", "Mohammed-Ali"]

var _fails := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/shots"))
	get_window().size = Vector2i(1920, 1080)
	var arena: Node3D = ARENA.instantiate()
	add_child(arena)
	var game: GameManager = arena.game
	game.use_database("")
	game.intro_time = 2.0
	game.result_time = 0.0
	game.scoreboard_time = 6.0
	game.auto_start_delay = 0.0
	game.random_rounds = false
	game.round_types = [QuizRound]
	for i in NAMES.size():
		arena.apply_command({"tile": i + 1, "join": NAMES[i], "age": 12})
	for i in 14:                                         # a full event feed with long lines
		game.log_event("EEN HEEL LANGE GEBEURTENIS OM HET AFKAPPEN TE TESTEN NUMMER %d" % i, Retro.CREAM)
	await get_tree().create_timer(1.0).timeout
	var page: ObserverView = _find_page(arena.screen_wall)
	await _no_overlap(page, "overview lobby")
	game.start_game()
	while game.state != GameManager.State.INTRO:
		await get_tree().process_frame
	await get_tree().create_timer(0.6).timeout
	await _no_overlap(page, "overview intro")
	page._page_t = page.page_time                         # the ranking page in the rules panel
	await get_tree().create_timer(0.4).timeout
	await _no_overlap(page, "overview ranking")
	page.get_viewport().get_texture().get_image().save_png("res://tests/shots/40_overview_layout.png")

	# quiz: read -> question, nothing moves
	var quiz: QuizRound
	while true:
		quiz = game.current as QuizRound
		if game.state == GameManager.State.PLAYING and quiz and quiz._phase == "read":
			break
		await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	var view: QuizView = game.screen_wall.shared_views[0]
	var before := _rects(view)
	await _shot("41_quiz_read")
	while quiz._phase != "question":
		await get_tree().process_frame
	for i in 3:
		await get_tree().process_frame
	var after := _rects(view)
	for k in before:
		check(before[k].is_equal_approx(after[k]), "quiz: %s stays put when the answers appear (%s -> %s)" % [k, before[k], after[k]])
	await get_tree().create_timer(0.6).timeout
	await _shot("42_quiz_question")

	# scoreboard with two exterminations: the banner above the rows
	game.skip()
	while not game._lives_shown:
		await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout
	for b in [page._board] + game.screen_wall.shared_views.slice(0, 1):
		b._exterminate_banner(["BRAM", "MOHAMMED-ALI"])
	await get_tree().create_timer(0.6).timeout
	for b in [page._board] + game.screen_wall.shared_views.slice(0, 1):
		var board: ScoreboardView = b
		var banner: Control = board._header.get_children().filter(func(c): return c.has_meta(&"banner")).front() \
			if board._header.get_children().any(func(c): return c.has_meta(&"banner")) else null
		check(banner != null, "scoreboard: GEËXTERMINEERD banner shown")
		if banner:
			var head_row: Control = board._rows[0].panel.get_parent().get_child(0)
			check(banner.get_global_rect().end.y <= head_row.get_global_rect().position.y + 0.5,
				"scoreboard: banner (bottom %.0f) above the column headers (top %.0f)" % [banner.get_global_rect().end.y, head_row.get_global_rect().position.y])
		var last: Control = board._rows.back().panel
		check(last.get_global_rect().end.y <= board.get_global_rect().end.y + 0.5,
			"scoreboard: all %d rows inside the board (last ends %.0f, board %.0f)" % [board._rows.size(), last.get_global_rect().end.y, board.get_global_rect().end.y])
	page._board.visible = true                             # (hidden while the robot fires: show it for the shot)
	await RenderingServer.frame_post_draw
	page.get_viewport().get_texture().get_image().save_png("res://tests/shots/43_overview_board_banner.png")
	await _shot("44_board_banner")
	print("DONE: %d failure(s)" % _fails)
	get_tree().quit()


## Every pair of the page's panels: no overlap.
func _no_overlap(page: ObserverView, what: String) -> void:
	await RenderingServer.frame_post_draw
	var parts := {"status": page._status.get_parent().get_parent(), "timer": page._timer,
		"cta": page._under[0], "rules": page._under[1], "players": page._list.get_parent(),
		"events": page._events.get_parent().get_parent().get_parent()}
	var keys := parts.keys()
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			var a: Control = parts[keys[i]]
			var b: Control = parts[keys[j]]
			if not (a.is_visible_in_tree() and b.is_visible_in_tree()):
				continue
			var ra := a.get_global_rect().grow(-1)
			var rb := b.get_global_rect().grow(-1)
			check(not ra.intersects(rb), "%s: %s and %s don't overlap (%s / %s)" % [what, keys[i], keys[j], ra, rb])
	var page_rect := Rect2(Vector2.ZERO, page.size)
	for k in keys:
		var c: Control = parts[k]
		if c.is_visible_in_tree():
			check(page_rect.encloses(c.get_global_rect().grow(-1)), "%s: %s inside the page (%s in %s)" % [what, k, c.get_global_rect(), page_rect])


func _rects(view: QuizView) -> Dictionary:
	return {"question panel": view._q_panel.get_global_rect(), "answer grid": view._grid.get_global_rect(),
		"time bar": view._bar.get_global_rect(), "status": view._status.get_global_rect()}


func check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
		print("    [FAIL] ", what)
	elif not what.begins_with("overview") or what.contains("don't"):
		pass


func _shot(file: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tests/shots/%s.png" % file)


func _find_page(n: Node) -> ObserverView:
	if n is ObserverView:
		return n
	for c in n.get_children():
		var f := _find_page(c)
		if f:
			return f
	return null
