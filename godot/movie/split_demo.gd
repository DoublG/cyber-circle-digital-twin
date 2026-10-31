extends Node
## A short directed demo of one physical screen (screen 1: tiles 1-3), three
## players side by side. Record it with Godot's Movie Maker:
##   godot-4 --path . --resolution 1920x1080 --fixed-fps 30 --disable-vsync \
##     --write-movie movie/split_demo.avi res://movie/split_demo.tscn
## Script: lobby (Anna and Bram playing, Cleo invited on T03 -> activates) ->
## quiz (the slide show: question + who answered, everyone's answer, who was
## right; Bram wrong, Cleo's shield, Anna changes her answer at the last
## second; then all right) -> scoreboard -> Cyclone (cameras tilt down to the tiles, the players play) ->
## places in the views, Bram (last, 1 life) exterminated: death clip in his
## view, his tile free again -> scoreboard.

const ARENA := preload("res://scenes/arena.tscn")

var arena: Node3D
var game: GameManager


func _ready() -> void:
	arena = ARENA.instantiate()
	add_child(arena)
	game = arena.game
	game.use_database("")
	game.auto_start_delay = 0.0
	game.intro_time = 5.0
	game.scoreboard_time = 30.0
	game.random_rounds = false
	game.round_types = [QuizRound, CycloneRound]
	# film screen 1 only: its own SubViewport, shown full window
	var wall: ScreenWall = arena.screen_wall
	var screen_vp: SubViewport = wall._screens[0].get_viewport()
	wall.visible = false                     # hiding its container disables the viewport ...
	screen_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS   # ... so switch it on after
	get_viewport().disable_3d = true
	var layer := CanvasLayer.new()
	add_child(layer)
	var view := TextureRect.new()
	view.texture = screen_vp.get_texture()
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(view)
	_direct()


func _direct() -> void:
	arena.apply_command({"tile": 1, "join": "Anna", "age": 12})
	arena.apply_command({"tile": 2, "join": "Bram"})
	await _wait(3.0)
	print("[movie] Cleo invited on T03, activates")
	arena.apply_command({"tile": 3, "register": "Cleo", "color": "#33ccff", "age": 7})
	await _wait(3.0)
	for b in CyberTile.BUTTONS:
		arena.tiles[2].press_button(b)
		await _wait(0.5)
	await _wait(3.0)

	print("[movie] quiz")
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	var quiz: QuizRound = game.current
	quiz.question_time = 12.0
	var all: Array = JSON.parse_string(FileAccess.get_file_as_string(QuizRound.QUESTIONS_FILE))
	var plain := all.filter(func(q): return not q.has("video"))
	var hard := plain.filter(func(q): return int(q.get("min_age", 0)) >= 10)   # Cleo (7) protected
	quiz._questions = [hard[0], plain[1]]
	quiz._index = -1
	quiz._next_question()
	await _answer(quiz, {1: "switch", 2: false, 3: false})   # Bram wrong, Cleo shielded, Anna switches
	await _answer(quiz, {1: true, 2: true, 3: true})         # everyone right
	await _until(func(): return game.current is CycloneRound, 60.0)

	print("[movie] Cyclone")
	var cyc: CycloneRound = game.current
	cyc.duration = 22.0
	await _until(func(): return game.state == GameManager.State.PLAYING)
	arena.tiles[1].health = 1                              # Bram on his last life
	# bots: Anna presses on red, Cleo on the yellow next to it, Bram always too late
	var aim := {1: 0, 3: 1, 2: 7}
	var t := 0.0
	while game.state == GameManager.State.PLAYING:
		for id in aim:
			var fw: TileFirmware = arena.tiles[id - 1].get_node("Firmware")
			if fw._running and fw._phase == "run" and fw._offset() == aim[id] and randf() < 0.5:
				arena.tiles[id - 1].press_button(&"Cross")
		await get_tree().process_frame
		t += get_process_delta_time()

	print("[movie] places, Bram exterminated")
	await _until(func(): return game.screen_wall.shared_views.size() > 0, 30.0)   # the scoreboard
	await _wait(5.0)
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
