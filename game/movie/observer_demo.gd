extends Node
## A short directed demo, filmed by the floating observer camera (the overview
## page full screen). Record it with Godot's Movie Maker:
##   godot-4 --path . --resolution 1920x1080 --fixed-fps 30 --disable-vsync \
##     --write-movie movie/observer_demo.avi res://movie/observer_demo.tscn
## Script: an idle game (nobody playing) -> players walk up, Eva activates
## her tile -> quiz round (the slide show: question, who answered, everyone's
## answer, who was right):
##   Q1  three right (green attack), Daan wrong (robot fires, harmless during
##       the round), Cleo (7) wrong on a 10+ question: her shield blocks; Anna
##       changes her answer at the last second
##   Q2  Bram (on his last life) wrong
##   Q3  everyone right: the special all-correct attack
## -> end of the round: wrong answers cost a life -> Bram exterminated (red
## blinking tile, the robot turns and fires, electrocution + explosion, the
## tile free again) -> the scoreboard on the overview -> Zwarte Piet (the
## light kicked around, the hidden countdown) -> places, lives -> scoreboard.
## With sound (Movie Maker records the game's audio).

const ARENA := preload("res://scenes/arena.tscn")

var arena: Arena
var game: GameManager


func _ready() -> void:
	arena = ARENA.instantiate()
	add_child(arena)
	game = arena.game
	game.use_database("")
	game.auto_start_delay = 0.0
	game.intro_time = 5.0
	game.scoreboard_time = 30.0
	game.picker.random_rounds = false
	game.picker.round_types = [QuizRound, ZwartePietRound]
	arena.screen_wall.visible = false        # only the overview page is filmed
	get_viewport().disable_3d = true         # the page has its own camera view
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.theme = Retro.THEME
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(root)
	var page := ObserverView.create(arena.screen_wall)
	root.add_child(page)
	var crt: Control = preload("res://scenes/ui/crt_overlay.tscn").instantiate()
	crt.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(crt)
	_direct()


func _direct() -> void:
	print("[movie] idle: nobody playing")
	await _wait(6.0)
	for p in [[1, "Anna", 12], [5, "Bram", 0], [7, "Cleo", 7], [10, "Daan", 13]]:
		arena.apply_command({"tile": p[0], "join": p[1], "age": p[2]})
		await _wait(1.2)
	await _wait(2.0)

	print("[movie] Eva activates T12")
	arena.apply_command({"tile": 12, "register": "Eva", "color": "#ff8800", "age": 11})
	await _wait(2.0)
	for b in CyberTile.BUTTONS:
		arena.tiles[11].press_button(b)
		await _wait(0.5)
	await _wait(2.0)

	print("[movie] quiz round")
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	var quiz: QuizRound = game.current
	quiz.question_time = 12.0
	var all: Array = JSON.parse_string(FileAccess.get_file_as_string(QuizRound.QUESTIONS_FILE))
	var plain := all.filter(func(q): return not q.has("video"))
	var hard := plain.filter(func(q): return int(q.get("min_age", 0)) >= 10)   # Cleo (7) protected
	quiz._questions = [hard[0], plain[1], plain[3]]
	quiz._index = -1
	quiz._next_question()
	arena.tiles[4].health = 1                          # Bram on his last life

	print("[movie] Q1: green attack, Daan wrong, Cleo's shield, Anna changes her answer")
	await _answer(quiz, {1: "switch", 5: true, 7: false, 10: false, 12: true})
	print("[movie] Q2: Bram wrong")
	await _answer(quiz, {1: true, 5: false, 7: true, 10: true, 12: true})
	print("[movie] Q3: everyone right -> special attack")
	await _answer(quiz, {1: true, 5: true, 7: true, 10: true, 12: true})

	print("[movie] end of the quiz: lives, Bram exterminated, scoreboard")
	await _until(func(): return game.state == GameManager.State.SCOREBOARD, 60.0)
	await _until(func(): return game.current is ZwartePietRound, 60.0)

	print("[movie] Zwarte Piet")
	var piet: ZwartePietRound = game.current
	piet.duration = 32.0
	piet.countdown_min = 5.0
	piet.countdown_max = 8.0
	await _until(func(): return game.state == GameManager.State.PLAYING)
	var react := randf_range(0.4, 1.4)
	while game.state == GameManager.State.PLAYING:   # the players kick the light on
		if piet.holder != 0 and piet._clock - piet._got_at > react:
			arena.tiles[piet.holder - 1].press_button(CyberTile.BUTTONS.pick_random())
			react = randf_range(0.3, 1.5)
		await get_tree().process_frame
	await _until(func(): return (game.state == GameManager.State.SCOREBOARD
		and game.screen_wall.shared_views.size() > 0), 40.0)
	await _wait(7.0)
	print("[movie] done")
	get_tree().quit()


## Players answer one after the other: true = the right answer,
## "switch": first a wrong answer, the right one just before the time is up.
## Waits until the round shows who was right.
func _answer(quiz: QuizRound, right: Dictionary) -> void:
	var index := quiz._index
	await _until(func(): return quiz._phase == "question", 30.0)
	await _wait(1.5)
	var correct := int(quiz._questions[quiz._index].correct)
	for id in right:
		var answer: int = correct if typeof(right[id]) == TYPE_BOOL and right[id] else (correct + 1) % 4
		arena.tiles[id - 1].press_button(QuizRound.ANSWER_BUTTONS[answer])
		await _wait(0.8)
	for id in right:
		if typeof(right[id]) == TYPE_STRING:
			await _until(func(): return quiz._phase_left < 1.5 or quiz._phase != "question", 30.0)
			arena.tiles[id - 1].press_button(QuizRound.ANSWER_BUTTONS[correct])
	await _until(func(): return quiz._index != index and quiz._phase == "read" or quiz.is_finished(), 60.0)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _until(cond: Callable, timeout := 60.0) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()
