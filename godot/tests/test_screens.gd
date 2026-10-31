extends Node
## Renders the screen wall at key moments of a game and saves screenshots
## to res://tests/shots/. Run (with a display): godot --path . res://tests/test_screens.tscn

const ARENA := preload("res://scenes/arena.tscn")

var arena: Node3D
var game: GameManager


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/shots"))
	get_window().size = Vector2i(1920, 1080)
	arena = ARENA.instantiate()
	add_child(arena)
	game = arena.game
	game.use_database("")                 # screenshots: no database writes
	game.intro_time = 2.0
	game.auto_start_delay = 0.0
	_run()


func _run() -> void:
	await _wait(1.5)
	await _shot("1_lobby_idle")

	for p in [[1, "Anna", "#ff8800", 12], [2, "Bram", "#00ccff", 7], [3, "Cleo", "#ff00aa", 9],
			[4, "Daan", "#88ff00", 13], [7, "Eva", "#ffee00", 8], [12, "Finn", "#aa55ff", 10]]:
		arena.apply_command({"tile": p[0], "register": p[1], "color": p[2], "age": p[3]})
	await _wait(0.8)
	for p in [1, 2, 3, 4, 7]:  # tile 12 stays pending
		for b in CyberTile.BUTTONS:
			arena.tiles[p - 1].press_button(b)
	await _wait(1.5)
	await _shot("2_lobby_players")

	game.start_game()
	await _wait(1.0)
	await _shot("3_intro")
	await _until(func(): return game.state == GameManager.State.PLAYING)
	await _wait(1.5)
	arena.tiles[0].press_button(&"Cross")
	await _wait(0.2)
	await _shot("4_cyclone_personal")

	game.skip()
	await _wait(1.0)
	await _shot("5_scoreboard")
	game.skip()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	await _wait(1.0)
	var quiz: QuizRound = game.current
	await _shot("6a_quiz_read")
	await _until(func(): return quiz._phase == "question")
	var correct := int(quiz._questions[quiz._index].correct)
	arena.tiles[0].press_button(QuizRound.ANSWER_BUTTONS[correct])
	arena.tiles[1].press_button(QuizRound.ANSWER_BUTTONS[(correct + 1) % 4])
	arena.tiles[3].press_button(QuizRound.ANSWER_BUTTONS[correct])
	await _wait(1.0)
	await _shot("6_quiz_shared")
	await _until(func(): return quiz._phase == "answers")
	await _wait(0.3)
	await _shot("6b_quiz_answers")
	await _until(func(): return quiz._phase == "reveal")
	await _wait(0.3)
	await _shot("7_quiz_reveal")

	# a question with a video, then one with a long text
	var all: Array = JSON.parse_string(FileAccess.get_file_as_string(QuizRound.QUESTIONS_FILE))
	quiz._questions = all.filter(func(q): return q.get("id", "").begins_with("voorbeeld"))
	quiz._stop_video()
	quiz._index = -1
	quiz._next_question()
	await _wait(3.0)
	await _shot("8_quiz_video")
	await _until(func(): return quiz._phase == "question")
	await _wait(1.0)
	arena.tiles[0].press_button(QuizRound.ANSWER_BUTTONS[1])
	await _shot("9_quiz_after_video")
	await _until(func(): return quiz._phase == "reveal")
	await _wait(0.3)
	await _shot("10_quiz_reveal_after_video")
	await _until(func(): return quiz._phase == "question" and quiz._index == 1)
	await _wait(1.0)
	await _shot("11_quiz_long_text")

	# switch the overview camera to a close view of the robot for one shot
	game.skip()
	await _wait(0.5)
	arena.screen_wall.visible = false
	arena.robot.look_at_side(1)
	arena.apply_command({"attacked": [2, 3]})
	await _wait(0.9)
	await _shot("12_room_robot_attack")
	await _wait(2.0)
	# shields: tiles 2 and 3 are protected and block the robot, tile 4 is hit
	arena.tiles[1].shielded = true
	arena.tiles[2].shielded = true
	await _wait(0.8)
	arena.robot_attack([4], Color(1.0, 0.1, 0.05), [2, 3])
	await _until(func(): return arena.tiles[1].get_ring_colors()[0].b > 0.9, 10.0)
	await _wait(0.05)
	await _shot("13_room_shield_block")
	get_tree().quit()


func _shot(file: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://tests/shots/%s.png" % file)
	print("saved ", file)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _until(cond: Callable, timeout := 120.0) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()
