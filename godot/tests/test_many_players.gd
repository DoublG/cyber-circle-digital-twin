extends Node
## More players than tiles (mobile tiles for players with mobility issues):
## the shared end-of-round screens with 24 players on a 1920x1080 screen -
## quiz answers / reveal, UITSLAG, scoreboard. Everything must fit and every
## animation end in its final state. Screenshots in tests/shots/6x_*.
## Run (with a display): godot --path . --disable-vsync --fixed-fps 30 res://tests/test_many_players.tscn

const N := 24
const NAMES := ["Anna", "Bram", "Cleo", "Daan", "Eva", "Finn", "Gust", "Hanne", "Ilias", "Jules",
	"Kato", "Lotte", "Mohammed-Ali", "Nora", "Otto", "Pieter-Jan", "Quinten", "Roos", "Sem", "Tess",
	"Ugo", "Vic", "Wout", "Xander-Alexander"]

var _fails := 0
var _vp: SubViewport


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/shots"))
	var container := SubViewportContainer.new()
	container.size = Vector2(1920, 1080)
	add_child(container)
	_vp = SubViewport.new()
	_vp.size = Vector2i(1920, 1080)
	container.add_child(_vp)

	print("--- quiz with %d players" % N)
	var quiz := _screen(QuizView.new()) as QuizView
	var players := []
	for i in N:
		var id := i + 1
		var answer := -1 if id % 7 == 0 else id % 4
		players.append({"id": id, "name": NAMES[i], "dead": false, "answer": answer,
			"protected": id % 11 == 0, "streak": 0, "ok": null})
	var state := {"phase": "answers", "question": "Wat betekent CPU?", "answers": ["a", "b", "c", "d"],
		"category": "Computers", "ages": "10-16 JAAR", "text": "", "video": null, "media": null,
		"video_progress": 0.0, "time_left": 3.0, "time_total": 3.0, "players": players}
	await _frames(state, quiz, 1.0)
	var cards: Array = quiz._player_cards.values().map(func(c): return c.panel)
	check(cards.size() == N, "quiz: %d cards (%d)" % [N, cards.size()])
	_inside(quiz, cards, "quiz answers: every card on the screen")
	var clipped := quiz._player_cards.values().all(func(c): return c.name.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS)
	check(clipped, "quiz: names clip with … (the card keeps its width)")
	await _shot("60_many_quiz_answers")
	for p in players:
		p.ok = p.answer == 1
	state.phase = "reveal"
	await _frames(state, quiz, 3.5)
	check(quiz._shown_ok.size() == N, "reveal: every card turned (%d)" % quiz._shown_ok.size())
	check(cards.all(func(c): return is_zero_approx(c.rotation) and c.scale.is_equal_approx(Vector2.ONE)),
		"reveal: no card left tilted or scaled")
	_inside(quiz, cards + [quiz._slide_status, quiz._legend], "reveal: cards, status and legend on the screen")
	check(quiz._slide_status.visible, "reveal: status shown: %s" % quiz._slide_status.text)
	await _shot("61_many_quiz_reveal")

	print("--- UITSLAG with %d players" % N)
	var rows := []
	for i in N:
		rows.append({"name": NAMES[i], "tile": i + 1, "place": i / 2 + 1, "score": 40 - i,
			"change": 1 if i < 2 else (-1 if i >= N - 2 else 0), "doomed": i == N - 1})
	var ranking := _screen(RankingView.new()) as RankingView
	ranking.show_ranking("Ritme", "PUNTEN", rows)
	await _wait(5.0)
	check(ranking._badges.size() == N, "UITSLAG: all %d rows (%d)" % [N, ranking._badges.size()])
	_inside(ranking, ranking._badges.map(func(b): return b.get_parent().get_parent()), "UITSLAG: every row on the screen")
	check(ranking._badges.all(func(b): return b.scale.is_equal_approx(Vector2.ONE)), "UITSLAG: badges stamped in")
	await _shot("62_many_uitslag")

	print("--- scoreboard with %d players" % N)
	var board_rows := []
	for i in N:
		board_rows.append({"name": NAMES[i], "tile": i + 1, "survived": 12 - i / 2, "lives": 1 + i % 5,
			"lives_before": 1 + i % 5, "change": 0, "out": i == N - 1, "was_out": false, "record": 14,
			"rank": i + 1})
	var board := _screen(ScoreboardView.new()) as ScoreboardView
	board.show_scores("Scorebord", "Ritme", board_rows, true)
	await _wait(1.5)
	check(board._rows.size() == N, "scoreboard: all %d rows (%d)" % [N, board._rows.size()])
	_inside(board, board._rows.map(func(e): return e.panel), "scoreboard: every row on the screen")
	await _shot("63_many_scoreboard")
	print("DONE: %d failure(s)" % _fails)
	get_tree().quit()


func _screen(view: Control) -> Control:
	for c in _vp.get_children():
		c.queue_free()
	var bg := ColorRect.new()                     # as a screen of the wall: the Retro theme
	bg.color = Color.BLACK
	bg.size = Vector2(1920, 1080)
	bg.theme = Retro.theme()
	_vp.add_child(bg)
	view.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.add_child(view)
	return view


## The quiz view gets its state every frame (as from QuizRound._update).
func _frames(state: Dictionary, view: QuizView, seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		view.show_question(state)
		await get_tree().process_frame
		t += get_process_delta_time()


## Every control inside the view, as drawn (scaled parents included).
func _inside(view: Control, controls: Array, what: String) -> void:
	var r := view.get_global_rect().grow(1)
	for c in controls:
		var cr: Rect2 = c.get_global_transform() * Rect2(Vector2.ZERO, c.size)
		if not r.encloses(cr):
			check(false, "%s (%s in %s)" % [what, cr, r])
			return
	check(true, what)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shot(file: String) -> void:
	await RenderingServer.frame_post_draw
	_vp.get_texture().get_image().save_png("res://tests/shots/%s.png" % file)
	print("saved ", file)


func check(ok: bool, what: String) -> void:
	if ok:
		print("    [ok] ", what)
	else:
		_fails += 1
		print("    [FAIL] ", what)
