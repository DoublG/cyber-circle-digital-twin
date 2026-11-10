extends Node
## Code kraken: the hints per place (green / yellow / grey, repeats counted right), the codes
## (4 different, 4 with a repeat, 5), a round with 5 players - Anna cracks it
## at once, Bram in 2 tries, Cleo guesses wrong (the hints on her tile's ring),
## Daan plays like the demo bots (a code that fits every hint so far), Eva does
## nothing - the points, the next code, places and lives, and screenshots of
## the board and of a cracked code.
## Run (with a display): godot --path . --disable-vsync res://tests/test_code.tscn

const ARENA := preload("res://scenes/arena.tscn")

var failures := 0
var arena: Arena
var game: GameManager
var shows := {}                                   # tile -> the "show" messages it got


func check(ok: bool, what: String) -> void:
	print(("ok    " if ok else "FAIL  ") + what)
	if not ok:
		failures += 1


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	print("--- the hints")
	check(CodeRound.score([0, 1, 2, 3], [0, 1, 2, 3]) == [4, 0], "all right: 4 green")
	check(CodeRound.score([0, 1, 2, 3], [3, 2, 1, 0]) == [0, 4], "all icons, all in another place: 4 yellow")
	check(CodeRound.score([0, 1, 2, 3], [0, 0, 0, 0]) == [1, 0], "one icon four times: 1 green, no yellow (counted once)")
	check(CodeRound.score([1, 1, 2, 3], [1, 2, 1, 1]) == [1, 2], "repeats: 1 green, 2 yellow (the 1 twice in the code)")
	check(CodeRound.marks([1, 1, 2, 3], [1, 2, 1, 1]) == [2, 1, 1, 0],
		"per place: green, yellow, yellow, grey (no 1 left for the last)")
	check(CodeRound.marks([0, 1, 2, 3], [1, 0, 2, 3]) == [1, 1, 2, 2], "per place: two swapped = yellow, the rest green")
	var codes := CodeRound.make_codes(5)
	check(codes[0].length == 4 and codes[0].code.duplicate().all(func(x): return codes[0].code.count(x) == 1),
		"code 1: 4 icons, all different")
	check(codes[1].length == 4 and codes[1].code.any(func(x): return codes[1].code.count(x) > 1),
		"code 2: 4 icons, one repeats")
	check(codes[2].length == 5 and codes[4].length == 5, "code 3 and further: 5 icons")
	check(DemoBots.code_candidates(4, false, []).size() == 24 and DemoBots.code_candidates(5, true, []).size() == 1024,
		"possibilities: 24 (4 different), 1024 (5 with repeats)")

	arena = ARENA.instantiate()
	add_child(arena)
	game = arena.game
	game.use_database("")
	game.intro_time = 1.0
	game.auto_start_delay = 0.0
	game.picker.random_rounds = false
	game.picker.round_types = [CodeRound]
	arena.tile_message.connect(func(id, msg):
		if msg.has("show"):
			shows.get_or_add(id, []).append(msg.show))
	for p in [[1, "Anna", 12], [2, "Bram", 7], [3, "Cleo", 10], [10, "Daan", 13], [11, "Eva", 8]]:
		arena.apply_command({"tile": p[0], "join": p[1], "age": p[2]})
	await _wait(1.0)
	game.start_game()
	while game.state != GameManager.State.PLAYING:
		await get_tree().process_frame
	var r: CodeRound = game.current
	check(r != null and r.title == "Code kraken" and not r.on_tile, "Code kraken is playing (the board on the screen)")
	var code: Array = r.codes[0].code
	check(shows.get(1, []).size() >= 1 and shows[1][0].ring.size() == 4, "the tile shows 4 empty places at the start")

	print("--- Anna: the code at once")
	await _type(1, code)
	var anna: CodeRound.PlayerState = r.state[1]
	check(anna.cracked == 1 and anna.level == 1 and r.points[1] == r.crack_points + r.par_tries - 1,
		"cracked in 1 try: %d points (%d + %d)" % [r.points[1], r.crack_points, r.par_tries - 1])
	check(shows[1][-1].ring.all(func(c): return _is(c, CodeRound.HINT_GREEN)), "her ring: all green")
	await _wait(0.3)
	await _shot("48_code_cracked")

	print("--- Bram: one wrong try, then right")
	var wrong := code.duplicate()
	wrong.reverse()
	await _type(2, wrong)
	await _type(2, code)
	check(r.state[2].cracked == 1 and r.points[2] == r.crack_points + r.par_tries - 2,
		"cracked in 2 tries: %d points" % r.points[2])

	print("--- Cleo: wrong tries, the hints")
	var other := [code[1], code[0], code[2], code[3]]   # 2 green, 2 yellow
	await _type(3, other)
	var t: Dictionary = r.state[3].tries[0]
	check(t.green == 2 and t.yellow == 2, "2 icons in place, 2 swapped: 2 green 2 yellow")
	var ring: Array = shows[3][-1].ring
	check(t.marks == [1, 1, 2, 2], "her hints per place: yellow, yellow, green, green")
	check(_is(ring[0], CodeRound.HINT_YELLOW) and _is(ring[1], CodeRound.HINT_YELLOW)
		and _is(ring[2], CodeRound.HINT_GREEN) and _is(ring[3], CodeRound.HINT_GREEN),
		"her ring: the same, a segment per place in order")
	await _wait(r.hint_time + 0.3)
	check(not _is(shows[3][-1].ring[0], CodeRound.HINT_GREEN), "after a moment: ready for the next try")
	await _type(3, [code[0], code[0], code[0], code[0]])
	await _type(3, [code[0], code[1], code[3], code[2]])
	check(r.state[3].tries.size() == 3 and r.state[3].cracked == 0, "3 tries, not cracked yet")
	await _wait(r.hint_time + 0.3)
	await _shot("47_code_board", 3)

	print("--- Daan: like the bots (a code that fits every hint so far)")
	var guesses := 0
	while r.state[10].cracked == 0 and guesses < 10:
		var c: Dictionary = r.codes[r.state[10].level]
		var fits := DemoBots.code_candidates(c.length, c.repeats, r.state[10].tries)
		await _type(10, fits.pick_random())
		guesses += 1
	check(r.state[10].cracked == 1, "Daan cracked code 1 in %d tries (24 possibilities)" % guesses)
	check(r.state[10].level == 1 and r.state[10].tries.is_empty(), "... and has code 2 now, its board empty")

	print("--- the end")
	game.skip()
	while game.state == GameManager.State.PLAYING:
		await get_tree().process_frame
	check(shows.get(1, []).size() > 0 and not shows[1][-1] is Dictionary,
		"the end: the tiles' pictures cleared ({\"show\": false})")
	var places := r.places()
	print("    points: ", r.points, "  places: ", places)
	check(places[1] == 1 and places[11] == places.values().max(), "Anna 1st, Eva (nothing) last")
	var lives := r.life_changes()
	check(lives.get(1, 0) == 1 and lives.get(11, 0) == -1, "Anna +1 life, Eva -1")
	print("FAILURES: %d" % failures)
	get_tree().quit(1 if failures else 0)


## A colour sent to a tile ("#rrggbb": 8 bits a channel) is this one.
func _is(sent: String, col: Color) -> bool:
	return sent.trim_prefix("#") == col.to_html(false)


func _type(id: int, lanes: Array) -> void:
	for lane in lanes:
		arena.tiles[id - 1].press_button(CyberTile.BUTTONS[lane], 0.05)
		await _wait(0.12)


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func _shot(name: String, _tile := 1) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tests/shots/%s.png" % name)
