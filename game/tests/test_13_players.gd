extends Node
## 13 players through the end-of-round screens, with their animations:
##   quiz      every player's icon, then card by card its frame: right / wrong / shield
##   scoreboard after the quiz: the lives change, one player exterminated
##   Ritme     UITSLAG: 13 places (shared ones), +♥ / -♥ / ☠, then the
##             scoreboard with the lives change and an extermination
## Checks that everything fits on the screen and that every animation ends
## in its final state; records screen 1 frame by frame (user://frames_13/,
## make a video: see the end of the output) and saves screenshots.
## Run (with a display): godot --path . --disable-vsync --fixed-fps 30 res://tests/test_13_players.tscn

const ARENA := preload("res://scenes/arena.tscn")
const NAMES := ["Anna", "Bram", "Cleo", "Daan", "Eva", "Finn", "Gust", "Hanne", "Ilias", "Jules",
	"Kato", "Lotte", "Mohammed-Ali"]
const FRAMES := "user://frames_13/"       # (not in the project: no import)
const FPS := 30                          # run with --fixed-fps 30
const RIGHT := [1, 2, 3, 4, 5, 6]        # quiz: right answer
const WRONG := [7, 8, 9, 10]             # wrong (9: on his last life -> exterminated)
const SHIELDED := [12, 13]               # age 7 on a 10+ question: wrong but protected
                                         # 11: no answer

var game: GameManager
var arena: Arena

var _fails := 0
var _frame := 0


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
	game.result_time = 6.0
	game.scoreboard_time = 6.0
	game.auto_start_delay = 0.0
	game.picker.random_rounds = false
	game.picker.round_types = [QuizRound, RhythmRound]
	for i in NAMES.size():
		var id := i + 1
		arena.players.join(id, NAMES[i], 7 if id in SHIELDED else 12)
	await _wait(0.5)
	game.start_game()

	print("--- quiz, 13 players")
	await _until(func(): return game.state == GameManager.State.PLAYING)
	var quiz: QuizRound = game.current
	var all: Array = JSON.parse_string(FileAccess.get_file_as_string(QuizRound.QUESTIONS_FILE))
	var q: Dictionary = all.filter(func(q): return int(q.get("min_age", 0)) >= 10 and not q.has("video"))[0]
	quiz._questions = [q]
	quiz._index = -1
	quiz._next_question()
	arena.tiles[8].health = 1                       # Ilias: wrong on his last life
	await _until(func(): return quiz._phase == "question")
	var correct := int(q.correct)
	for id in RIGHT:
		arena.tiles[id - 1].press_button(QuizRound.ANSWER_BUTTONS[correct])
	for id in WRONG + SHIELDED:
		arena.tiles[id - 1].press_button(QuizRound.ANSWER_BUTTONS[(correct + 1 + id % 3) % 4])
	await _wait(1.0)
	quiz._phase_left = 0.5                          # (no need to wait the whole answer time)
	await _record_until(func(): return quiz._phase == "answers")
	await _record(1.5)
	var view: QuizView = game.screen_wall.shared_views[0]
	_inside(view, view._player_cards.values(), "quiz answers: card")
	_no_overlap(view._player_cards.values(), "quiz answers: cards")
	check(view._player_cards.size() == 13, "quiz: 13 player cards (%d)" % view._player_cards.size())
	await _shot(view, "50_13_quiz_answers")
	await _record_until(func(): return quiz._phase == "reveal")
	await _record(0.3)
	var before := view._player_cards.values().map(func(c): return c.global_position)
	var scale_before: Vector2 = view._player_grid.scale
	await _record(3.5)                              # the cards turn one by one
	var after := view._player_cards.values().map(func(c): return c.global_position)
	check(before.size() == after.size()
		and range(before.size()).all(func(i): return before[i].distance_to(after[i]) < 0.5)
		and view._player_grid.scale.is_equal_approx(scale_before),
		"reveal: the cards do not move when the result line appears (%s -> %s)" % [before.slice(0, 1), after.slice(0, 1)])
	check(view._shown_ok.size() == 13, "reveal: every card turned (%d)" % view._shown_ok.size())
	check(view._player_cards.values().all(func(c): return is_zero_approx(c.rotation) \
		and c.scale.is_equal_approx(Vector2.ONE)), "reveal: the shake / pop ended (no card tilted or scaled)")
	check(RIGHT.all(func(id): return _card_is(view, id, Retro.GOOD, true, false) and _card_width(view, id) >= 10),
		"reveal: the right ones: a thick glowing green border")
	check((WRONG + [11]).all(func(id): return _card_is(view, id, Retro.BAD, false, true) and _card_width(view, id) <= 5),
		"reveal: wrong / no answer: a thin red border, dimmed")
	check(SHIELDED.all(func(id):
		return _card_is(view, id, Retro.SHIELD, true, false) and view._player_cards[id].shield.visible),
		"reveal: shielded: blue, the shield, not dimmed")
	check(view._player_cards.values().all(func(c): return c.mark.text == "" or c.mark.text == "GEEN"),
		"reveal: no ✔ / ✘ marks")
	check(view._slide_status.visible and view._slide_status.modulate.a > 0.99
		and view._slide_status.text.begins_with("6 VAN 13"),
		"reveal: '%s'" % view._slide_status.text)
	_inside(view, [view._slide_status, view._legend], "reveal: status / legend")
	await _shot(view, "51_13_quiz_reveal")

	print("--- scoreboard after the quiz: no UITSLAG, Ilias exterminated")
	await _record_until(func(): return game.state == GameManager.State.SCOREBOARD)
	await _record(0.3)
	check(game.screen_wall.shared_views[0] is ScoreboardView, "quiz: straight to the scoreboard")
	await _record_until(func(): return game.views.lives_shown)
	await _record(2.0)
	_check_board("quiz scoreboard", 13)
	var board: ScoreboardView = game.screen_wall.shared_views[0]
	var ilias: Dictionary = board._rows.filter(func(e): return e.data.tile == 9).front()
	check(ilias.name.text.trim_prefix("▶").strip_edges().begins_with("☠"),
		"scoreboard: Ilias marked exterminated (%s)" % ilias.name.text)
	await _shot(board, "52_13_quiz_scoreboard")

	print("--- Ritme, 12 players: UITSLAG, then the scoreboard")
	await _until(func(): return game.state == GameManager.State.PLAYING and game.current is RhythmRound)
	var rhythm: RhythmRound = game.current
	var alive := rhythm.players.filter(func(id): return not arena.tiles[id - 1].is_dead)
	check(alive.size() == 12, "Ritme: 12 players (%d)" % alive.size())
	var pts := [31, 27, 27, 22, 19, 19, 15, 12, 9, 9, 4, -2]   # two shared places
	for i in alive.size():
		rhythm.points[alive[i]] = pts[i]
	var last: int = alive.back()
	arena.tiles[last - 1].health = 1                # last place on the last life
	await _wait(0.5)
	game.skip()
	var views := func(): return game.screen_wall.shared_views
	await _until(func(): return not views.call().is_empty() and views.call()[0] is RankingView)
	await _record(5.0)                              # rows in from the last place, then the badges
	var uitslag: RankingView = game.screen_wall.shared_views[0]
	check(uitslag._badges.size() == 12, "UITSLAG: 12 rows (%d)" % uitslag._badges.size())
	check(uitslag._badges.all(func(b): return b.scale.is_equal_approx(Vector2.ONE)), "UITSLAG: badges stamped in")
	var texts: Array = uitslag._badges.map(func(b): return b.text)
	check(texts.front() == "+♥" and texts.back() == "-♥ ☠" and texts.count("") == 10, "UITSLAG badges: %s" % [texts])
	var rows: Array = []
	for b in uitslag._badges:
		rows.append(b.get_parent().get_parent())
	_inside(uitslag, rows, "UITSLAG: row")
	var places: Array = rows.map(func(r): return (r.get_child(0).get_child(0) as Label).text)
	check(places == ["1", "2", "2", "3", "4", "4", "5", "6", "7", "7", "8", "9"], "UITSLAG places: %s" % [places])
	await _shot(uitslag, "53_13_uitslag")
	await _record_until(func(): return game.screen_wall.shared_views[0] is ScoreboardView)
	await _record_until(func(): return game.views.lives_shown)
	await _record(2.5)
	_check_board("Ritme scoreboard", 12)
	await _shot(game.screen_wall.shared_views[0], "54_13_scoreboard")
	var page := _find_page(arena.screen_wall)
	if page:
		await RenderingServer.frame_post_draw
		page.get_viewport().get_texture().get_image().save_png("res://tests/shots/55_13_overview.png")
	print("frames: %d in %s" % [_frame, dir])
	print("video:  ffmpeg -framerate 30 -i %s%%05d.jpg -vf scale=1280:720 -c:v libx264 -crf 27 -pix_fmt yuv420p OUT.mp4"
		% dir)
	print("DONE: %d failure(s)" % _fails)
	get_tree().quit()


## The scoreboard: n rows (plus new / out ones), all inside the board.
func _check_board(what: String, n: int) -> void:
	var board: ScoreboardView = game.screen_wall.shared_views[0]
	check(board._rows.size() >= n, "%s: %d rows (%d)" % [what, n, board._rows.size()])
	_inside(board, board._rows.map(func(e): return e.panel), what + ": row")


## Every control inside the view (scaled lists: their screen rect).
func _inside(view: Control, controls: Array, what: String) -> void:
	var r := view.get_global_rect().grow(1)
	for c in controls:
		var cr: Rect2 = c.get_global_rect()
		if c.get_parent() is Control and (c.get_parent() as Control).scale != Vector2.ONE:
			var p: Control = c.get_parent()
			cr = Rect2(p.get_global_rect().position + (cr.position - p.get_global_rect().position) * p.scale, cr.size * p.scale)
		if not r.encloses(cr):
			check(false, "%s inside the screen (%s in %s)" % [what, cr, r])
			return
	check(true, what)


func _no_overlap(controls: Array, what: String) -> void:
	for i in controls.size():
		for j in range(i + 1, controls.size()):
			if controls[i].get_global_rect().grow(-1).intersects(controls[j].get_global_rect().grow(-1)):
				check(false, "%s don't overlap" % what)
				return
	check(true, what + " don't overlap")


## Screen 1 (its own 1920x1080 viewport), every frame.
func _capture() -> void:
	await RenderingServer.frame_post_draw
	if game.screen_wall.shared_views.is_empty():
		return
	var img: Image = game.screen_wall.shared_views[0].get_viewport().get_texture().get_image()
	img.save_jpg(ProjectSettings.globalize_path(FRAMES) + "%05d.jpg" % _frame, 0.9)
	_frame += 1


func _record(seconds: float) -> void:
	var end := _frames_for(seconds)
	for i in end:
		await _capture()


func _record_until(cond: Callable, timeout := 60.0) -> void:
	var n := 0
	while not cond.call() and n < _frames_for(timeout):
		await _capture()
		n += 1


func _frames_for(seconds: float) -> int:
	return int(seconds * FPS)


func _until(cond: Callable, timeout := 60.0) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shot(view: Control, file: String) -> void:
	await RenderingServer.frame_post_draw
	view.get_viewport().get_texture().get_image().save_png("res://tests/shots/%s.png" % file)
	print("saved ", file)


func _find_page(n: Node) -> ObserverView:
	if n is ObserverView:
		return n
	for c in n.get_children():
		var f := _find_page(c)
		if f:
			return f
	return null


func check(ok: bool, what: String) -> void:
	if ok:
		print("    [ok] ", what)
	else:
		_fails += 1
		print("    [FAIL] ", what)


## A quiz card's frame after the reveal: its border colour, a glow or not, dimmed or not.
func _card_is(view, id: int, color: Color, glow: bool, dimmed: bool) -> bool:
	var c: QuizPlayerCard = view._player_cards[id]
	var st: StyleBoxFlat = c.get_theme_stylebox("panel")
	var dim: bool = c.modulate.a < 0.99
	return st.border_color.is_equal_approx(color) and (st.shadow_size > 0) == glow and dim == dimmed


func _card_width(view, id: int) -> int:
	var st: StyleBoxFlat = view._player_cards[id].get_theme_stylebox("panel")
	return st.border_width_top
