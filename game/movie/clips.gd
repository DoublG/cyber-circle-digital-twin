extends Node
## Gameplay clips of the whole installation: every screen at once - the
## overview page big (top left), floor screens 1-4 on the right, screen 5 and
## the 2 mobile screens along the bottom - with a caption saying what happens. One clip per run (after "--"):
##   godot-4 --path . --resolution 1920x1080 --fixed-fps 30 --disable-vsync \
##     --write-movie movie/clip_setup.avi res://movie/clips.tscn -- --clip=setup
## --split=DIR: also every screen on its own, full HD, frame by frame
## (DIR/overzicht, DIR/scherm_1 .. 5, DIR/mobiel_1 .. 2: %05d.jpg, the same
## frames as the movie) - one video per screen (tools/media/make_clips.sh).
## Clips:
##   setup     test screens (SETUP) -> setup locked (CLOSED) -> open, idling
##   joining   QR registrations: the tile lights up in the player's colour, the
##             4 icons activate it; a mobile player on a drone (set up at the
##             station, assigned by the game master); the rounds start; a late
##             visitor waits and comes in on the scoreboard (NIEUW)
##   few       3 players: a quiz question, Ritme, UITSLAG, scoreboard
##   full      18 players (13 tiles + 5 drones): Cyclone (cameras look down at
##             the tiles), UITSLAG in two columns, exterminations of tiles and
##             a drone; a quiz with 18 cards
##   mobile    3 tiles + 3 drones: flying in, the mobile screens (2 and 1
##             views), quiz, Simon (looking down on the drone), a hit, the
##             shield, a drone exterminated
##   gallery   screenshots (no movie needed) of every game and state: setup,
##             closed, idle, joining, every round (intro, playing, the quiz's
##             steps), UITSLAG, scoreboard, an extermination, pause -
##             --shots=DIR: per moment the whole installation and the overview,
##             floor screen 1 and mobile screen 1 on their own (jpg)
##   leaving   a player walks away mid-game, exterminations (death clips in
##             the views), tiles free again, the last player leaves: idle

const ARENA := preload("res://scenes/arena.tscn")
const COLORS := ["#ff8800", "#33ccff", "#ff44cc", "#88ff00", "#ffee00", "#aa55ff", "#ff3344",
	"#00ffcc", "#ffffff", "#4488ff", "#ffaa88", "#bbff44", "#ff66ff", "#44ffaa", "#ffcc33",
	"#66ccff", "#ff8866", "#ccff99"]
const NAMES := ["Anna", "Bram", "Cleo", "Daan", "Eva", "Finn", "Gust", "Hanne", "Ilias", "Jules",
	"Kato", "Lotte", "Mohammed", "Mila", "Ravi", "Noor", "Sem", "Tess"]

var arena: Node3D
var game: GameManager
var bots: DemoBots
var _caption: Label
var _split := ""                 # --split=DIR: every screen's frames
var _panes: Array[SubViewport] = []
var _frame := 0
var _shots := ""                 # --shots=DIR (gallery)
var _shot_n := 0


func _ready() -> void:
	var clip := "setup"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--clip="):
			clip = a.trim_prefix("--clip=")
		if a.begins_with("--split="):
			_split = a.trim_prefix("--split=")
		if a.begins_with("--shots="):
			_shots = a.trim_prefix("--shots=")
	arena = ARENA.instantiate()
	add_child(arena)
	game = arena.game
	game.use_database("")
	game.auto_start_delay = 0.0
	game.random_rounds = false
	game.apply_settings({"game": {"intro_time": 5, "result_time": 7, "scoreboard_time": 7},
		"quiz": {"question_time": 10, "read_time": 2.5}, "rhythm": {"duration": 25},
		"cyclone": {"duration": 25}, "simon": {"duration": 25}})
	game.auto_start_delay = 0.0                   # (the settings put it back to 20 s): the clips start the rounds
	_compose()
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	_caption = Label.new()
	_caption.add_theme_font_override("font", Retro.FONT)
	_caption.add_theme_font_size_override("font_size", 30)
	_caption.add_theme_color_override("font_color", Retro.CREAM)
	_caption.add_theme_stylebox_override("normal", Retro.panel(Color(0, 0, 0, 0.8), Retro.ORANGE, 2, 10, 16))
	_caption.grow_horizontal = Control.GROW_DIRECTION_BOTH     # centred low on the overview pane
	_caption.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_caption.resized.connect(func(): _caption.position = Vector2(720 - _caption.size.x / 2, 800 - _caption.size.y))
	layer.add_child(_caption)
	if _split != "":
		_record_panes()
	await _wait(0.5)
	match clip:
		"setup": await _setup()
		"joining": await _joining()
		"few": await _few()
		"full": await _full()
		"mobile": await _mobile()
		"leaving": await _leaving()
		"gallery": await _gallery()
		_: push_warning("unknown clip %s" % clip)
	print("[clip] done")
	get_tree().quit()


# ---------------------------------------------------------------- clips

func _gallery() -> void:
	DirAccess.make_dir_recursive_absolute(_shots)
	game.set_mode(GameManager.Mode.SETUP)
	say("SETUP: test screens; on the tiles the hearts show the place number in binary")
	await _wait(2.0)
	await _snap("setup")
	game.set_mode(GameManager.Mode.CLOSED)
	say("Setup locked: closed")
	await _wait(1.5)
	await _snap("closed")
	game.set_mode(GameManager.Mode.OPEN)
	say("Open, nobody playing: idle, the overview invites visitors")
	await _wait(3.0)
	await _snap("idle")
	for i in 3:
		_register([2, 6, 10][i], i)
	_register(14, 13)
	say("Visitors registered: their tile (and drone M1) lights up in the gamemaster's colour, waiting for the 4 icons")
	await _wait(2.5)
	await _snap("invited")
	for id in [2, 6, 10, 14]:
		await _activate(id, 0.1)
	for i in 5:
		arena.join([1, 4, 8, 11, 13][i], NAMES[3 + i], 12 if i % 2 else 7)
	arena.join(16, NAMES[15], 12)
	say("8 players on the tiles, 2 mobile players on drones: the lobby")
	await _wait(4.0)
	await _snap("lobby_players")
	game.round_types = [QuizRound, CycloneRound, ReactionRound, SimonRound, ZwartePietRound, RhythmRound]
	_bots(false)
	game.start_game()

	# the quiz: intro, read, question, time up, answers, reveal, scoreboard
	await _until(func(): return game.state == GameManager.State.INTRO)
	say("Intro: the round's title, rules and countdown")
	await _wait(2.0)
	await _snap("quiz_intro")
	await _until(func(): return game.state == GameManager.State.PLAYING)
	var quiz: QuizRound = game.current
	await _until(func(): return quiz._phase == "read")
	say("Quiz - read the question (the answers come in a moment)")
	await _wait(1.2)
	await _snap("quiz_read")
	await _until(func(): return quiz._phase == "question")
	var correct := int(quiz._questions[quiz._index].correct)
	for id in arena.player_ids():
		arena.tiles[id - 1].press_button(QuizRound.ANSWER_BUTTONS[correct if id % 3 else (correct + 1) % 4])
	say("Quiz - the answers and the countdown; who answered already")
	await _wait(2.0)
	await _snap("quiz_question")
	quiz._phase_left = 0.2
	await _until(func(): return quiz._phase == "timeup")
	say("Time up")
	await _wait(0.4)
	await _snap("quiz_timeup")
	await _until(func(): return quiz._phase == "answers")
	say("Everyone's answer")
	await _wait(1.2)
	await _snap("quiz_answers")
	await _until(func(): return quiz._phase == "reveal")
	say("Card by card: right or wrong (shield: protected by age)")
	await _wait(3.0)
	await _snap("quiz_reveal")
	await _until(func(): return game.state == GameManager.State.SCOREBOARD, 30.0)
	await _until(func(): return game._lives_shown, 15.0)
	say("Scoreboard after the quiz: wrong = -1 life")
	await _wait(1.5)
	await _snap("quiz_scoreboard")

	# the personal games: intro, playing, UITSLAG, scoreboard
	for g in [["cyclone", "Cyclone - on the tile: every camera looks down at its own tile (drones from above)"],
			["reaction", "Reactie - press the colour as fast as you can, not on red"],
			["simon", "Simon zegt - repeat the sequence on your tile"],
			["zwarte_piet", "Zwarte Piet - kick the light to your neighbour before the hidden timer ends"],
			["rhythm", "Ritme - icons fall down the lanes: in the band +1, on the line +3"]]:
		await _until(func(): return game.state == GameManager.State.INTRO, 60.0)
		await _wait(1.5)
		await _snap(g[0] + "_intro")
		await _until(func(): return game.state == GameManager.State.PLAYING, 30.0)
		say(g[1] + (" - T01: the death clip in the exterminated player's own view" if g[0] == "zwarte_piet" else ""))
		await _wait(7.0)
		await _snap(g[0] + "_playing")
		if g[0] == "simon":                       # an extermination: the last on the last life
			var simon: SimonRound = game.current
			await _until(func(): return simon.time_left < 1.5, 60.0)
			for id in simon.players:                   # (tile 1: on screen 1, the death clip there)
				simon.state[id].best = 0 if id == 1 else 3
			arena.tiles[0].health = 1
		await _until(func(): return game.state == GameManager.State.SCOREBOARD, 60.0)
		say("UITSLAG: the round's places, +1 life for the 1st, -1 for the last")
		await _wait(4.0)
		await _snap(g[0] + "_uitslag")
		await _until(func(): return game._lives_shown, 20.0)
		say("Scoreboard: the lives change" + (" - GEËXTERMINEERD" if g[0] == "simon" else ""))
		await _wait(1.5)
		await _snap(g[0] + "_scoreboard")
		if g[0] == "simon":
			await _until(func(): return not arena.dying.is_empty(), 15.0)
			await _wait(1.5)
			say("The robot fires at the exterminated tile; the overview drifts over to watch")
			await _snap("extermination")
	await _until(func(): return game.state == GameManager.State.INTRO, 60.0)
	game.set_mode(GameManager.Mode.PAUSED)
	say("Paused by the operator: everything stands still")
	await _wait(1.5)
	await _snap("paused")
	game.set_mode(GameManager.Mode.OPEN)


## Gallery: the whole installation, and the overview, floor screen 1 and
## mobile screen 1 on their own.
func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	_shot_n += 1
	var base := _shots.path_join("%02d_%s" % [_shot_n, name])
	get_viewport().get_texture().get_image().save_jpg(base + ".jpg", 0.9)
	var wall: ScreenWall = arena.screen_wall
	wall._observer_screen.get_viewport().get_texture().get_image().save_jpg(base + "_overzicht.jpg", 0.9)
	wall._screens[0].get_viewport().get_texture().get_image().save_jpg(base + "_scherm1.jpg", 0.9)
	wall._screens[wall.screen_groups.size()].get_viewport().get_texture().get_image().save_jpg(base + "_mobiel1.jpg", 0.9)
	print("[gallery] ", name)


func _setup() -> void:
	game.set_mode(GameManager.Mode.SETUP)
	say("SETUP: every screen shows its number, its tiles and test colours (the overview too)")
	await _wait(8.0)
	game.set_mode(GameManager.Mode.CLOSED)
	say("Setup locked: the game is closed, the screens show the free tiles")
	await _wait(6.0)
	game.set_mode(GameManager.Mode.OPEN)
	say("Open: nobody playing - tiles and drones idle, the overview invites visitors")
	await _wait(12.0)


func _joining() -> void:
	game.set_mode(GameManager.Mode.OPEN)
	say("Open and idling: the tiles run their attract animation, the drones wait in their park")
	await _wait(5.0)
	say("Visitors scan the QR code: their tile lights up in their colour (screens show the invite)")
	for i in 3:
		_register(i + 1 + i * 3, i)
		await _wait(1.2)
	await _wait(3.0)
	say("They press the 4 icons on their tile to activate it")
	for i in 3:
		await _activate(i + 1 + i * 3, 0.35)
	await _wait(2.0)
	say("A mobile player, set up at the station, is put on drone M1: it flies into the ring")
	_register(14, 13)
	await _wait(2.0)
	await _activate(14, 0.4)
	await _wait(5.0)
	say("The rounds start by themselves: intro with the rules, then the quiz")
	game.round_types = [QuizRound, CycloneRound]
	_bots(false)
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	var quiz: QuizRound = game.current
	await _until(func(): return quiz._phase == "question")
	say("A late visitor registers during the round: they wait for the next round")
	_register(12, 11)
	await _activate(12, 0.3)
	await _answer(quiz, {1: true, 5: true, 9: false, 14: true})
	await _until(func(): return game.state == GameManager.State.SCOREBOARD, 40.0)
	say("The scoreboard: lives change (wrong = -1) and the new player comes in (NIEUW)")
	await _until(func(): return game.state == GameManager.State.INTRO, 30.0)
	say("Next round: the new player plays along")
	await _wait(6.0)


func _few() -> void:
	game.set_mode(GameManager.Mode.OPEN)
	for i in 3:
		arena.join([1, 5, 9][i], NAMES[i], 12)
	game.round_types = [QuizRound, RhythmRound]
	_bots(false)
	say("3 players: the empty places on the screens show how to join")
	await _wait(4.0)
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	say("Quiz: one question - right = you stay in, wrong or too late = -1 life")
	await _answer(game.current, {1: true, 5: false, 9: true})
	say("Who chose what, then card by card right or wrong")
	await _until(func(): return game.state == GameManager.State.SCOREBOARD, 40.0)
	say("Scoreboard: Bram loses a life")
	await _until(func(): return game.state == GameManager.State.PLAYING and game.current is RhythmRound, 40.0)
	say("Ritme: icons fall down the lanes - in the band +1, on the line +3")
	await _until(func(): return game.state == GameManager.State.SCOREBOARD, 40.0)
	say("UITSLAG: the places of the round, +1 life for the winner, -1 for the last")
	await _until(func(): return not game.screen_wall.shared_views.is_empty() and game.screen_wall.shared_views[0] is ScoreboardView, 20.0)
	say("Then the scoreboard with the lives changing")
	await _wait(8.0)


func _full() -> void:
	game.set_mode(GameManager.Mode.OPEN)
	for i in 13:
		arena.join(i + 1, NAMES[i], 12 if i % 4 else 8)
	for i in 5:
		arena.join(14 + i, NAMES[13 + i], 12)
	say("Completely full: 13 players on the tiles and 5 mobile players on drones (18)")
	await _wait(6.0)
	game.round_types = [CycloneRound, QuizRound]
	_bots(false)
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	say("Cyclone, played on the tile: every camera looks down at its own tile (drones: from above)")
	var cyc: CycloneRound = game.current
	await _until(func(): return cyc.time_left < 1.5, 60.0)
	for id in [4, 11, 16]:                          # the last places, on their last life
		cyc.state[id].best = 0
		arena.tiles[id - 1].health = 1
	await _until(func(): return game.state == GameManager.State.SCOREBOARD, 20.0)
	say("UITSLAG with 18 players: two columns; three players on their last life (skull)")
	await _until(func(): return not game.screen_wall.shared_views.is_empty() and game.screen_wall.shared_views[0] is ScoreboardView, 20.0)
	say("Scoreboard: GEËXTERMINEERD - the robot fires at the tiles and the drone, one after the other")
	await _until(func(): return game.state == GameManager.State.PLAYING and game.current is QuizRound, 40.0)
	say("The next round already runs while the exterminations finish: a quiz with every player's card")
	var right := {}
	for id in arena.player_ids():
		if not arena.tiles[id - 1].is_dead:
			right[id] = id % 3 != 0
	await _answer(game.current, right, 0.15)
	await _until(func(): return game.state == GameManager.State.SCOREBOARD, 40.0)
	await _wait(9.0)


func _mobile() -> void:
	game.set_mode(GameManager.Mode.OPEN)
	game.round_types = [QuizRound, SimonRound]
	for i in 3:
		arena.join([2, 6, 10][i], NAMES[i], 12)
	say("Mobile players (wheelchair, blind with a handheld tile, tablet) are each set up at a station")
	await _wait(3.0)
	for i in 3:
		_register([14, 15, 16][i], 13 + i)
		await _wait(0.6)
	say("Assigned to drones M1, M2, M3: they fly from their park into the ring above the tiles")
	for id in [14, 15, 16]:
		await _activate(id, 0.25)
	await _wait(5.0)
	say("Mobile screens: M1 + M2 side by side, M3 alone on its screen - their drone in view, the robot above it")
	await _wait(6.0)
	say("The robot attacks the drones: a hit makes M1 rock and drop; M3's shield blocks")
	arena.tiles[15].shielded = true
	arena.robot_attack([14], Color(1.0, 0.1, 0.05), [16], false)
	await _wait(5.0)
	arena.tiles[15].shielded = false
	_bots(false)
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	say("The same game: they answer on their handheld tile; the drones attack with bolts through the air")
	await _answer(game.current, {2: true, 6: true, 10: true, 14: true, 15: true, 16: false})
	await _until(func(): return game.state == GameManager.State.PLAYING and game.current is SimonRound, 40.0)
	say("Simon, on the tile: the drone camera swings over the drone and looks down at its LEDs")
	var simon: SimonRound = game.current
	await _until(func(): return simon.time_left < 1.5, 60.0)
	for id in arena.player_ids():
		simon.state[id].best = 3 if id != 15 else 0     # M2 last ...
	arena.tiles[14].health = 1                          # ... on the last life
	await _until(func(): return game.state == GameManager.State.SCOREBOARD, 20.0)
	say("M2 lost: the drone stops, the robot fires - it spirals down trailing smoke and explodes")
	await _wait(18.0)


func _leaving() -> void:
	game.set_mode(GameManager.Mode.OPEN)
	for i in 6:
		arena.join([1, 3, 5, 8, 10, 12][i], NAMES[i], 12)
	arena.join(17, NAMES[14], 12)
	game.round_types = [ReactionRound, QuizRound]
	_bots(false)
	await _wait(4.0)
	game.start_game()
	await _until(func(): return game.state == GameManager.State.PLAYING)
	say("Reactie - halfway through, a player just walks away: their view leaves the screen")
	await _wait(8.0)
	arena.leave(3)
	await _wait(5.0)
	var r: ReactionRound = game.current
	await _until(func(): return r.time_left < 1.5, 60.0)
	for id in [8, 17]:                                # last place, last life
		if r.stats.has(id):
			r.stats[id].best_streak = 0
		arena.tiles[id - 1].health = 1
	await _until(func(): return game.state == GameManager.State.SCOREBOARD, 20.0)
	say("Two players exterminated: the death clip plays in their own view, then the tile is free again")
	await _until(func(): return game.state == GameManager.State.PLAYING, 40.0)
	await _wait(16.0)
	say("The others leave one by one - the last one gone: the game goes back to idle")
	for id in arena.player_ids():
		arena.leave(id)
		await _wait(1.5)
	await _wait(8.0)


# ---------------------------------------------------------------- helpers

## The movie layout on a 4 x 4 grid of 480 x 270: the overview 3 x 3 units,
## screens 1-4 down the right column, 5, M1-M2 and M3-M5 along the bottom.
func _compose() -> void:
	var wall: ScreenWall = arena.screen_wall
	var panes: Array[SubViewport] = [wall._observer_screen.get_viewport()]
	for screen in wall._screens:
		panes.append(screen.get_viewport())
	_panes = panes
	wall.visible = false                          # (hiding the preview stops its viewports ...)
	for vp in panes:
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS   # ... so they render anyway
	get_viewport().disable_3d = true
	var layer := CanvasLayer.new()
	add_child(layer)
	var back := ColorRect.new()
	back.color = Color(0.05, 0.05, 0.06)
	back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(back)
	var unit := Vector2(480, 270)
	var places := [Rect2(0, 0, 3, 3), Rect2(3, 0, 1, 1), Rect2(3, 1, 1, 1), Rect2(3, 2, 1, 1),
		Rect2(3, 3, 1, 1), Rect2(0, 3, 1, 1), Rect2(1, 3, 1, 1), Rect2(2, 3, 1, 1)]
	for k in mini(panes.size(), places.size()):
		var r: Rect2 = places[k]
		var view := TextureRect.new()
		view.texture = panes[k].get_texture()
		view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		view.position = r.position * unit + Vector2(2, 2)
		view.size = r.size * unit - Vector2(4, 4)
		layer.add_child(view)


func say(text: String) -> void:
	print("[clip] ", text)
	_caption.text = text


## A visitor scans the QR code: their tile (or drone) lights up in their colour.
func _register(tile_id: int, who: int) -> void:
	arena.apply_command({"tile": tile_id, "register": NAMES[who], "color": COLORS[who], "age": 12})


## The 4 icons, one after the other.
func _activate(tile_id: int, gap: float) -> void:
	for b in CyberTile.BUTTONS:
		arena.tiles[tile_id - 1].press_button(b)
		await _wait(gap)


## Bots for the tile games and Ritme; the quiz answers come from _answer.
func _bots(quiz: bool) -> void:
	if bots == null:
		bots = DemoBots.new()
		bots.players = 0
		bots.arena = arena
		add_child(bots)
		game.auto_start_delay = 0.0
	bots.answer_quiz = quiz


## Every frame: every screen's image (the overview, the floor screens, the
## mobile screens) as its own jpg.
func _record_panes() -> void:
	var names := ["overzicht"]
	for k in arena.screen_wall.screen_groups.size():
		names.append("scherm_%d" % (k + 1))
	for k in arena.screen_wall.mobile_groups.size():
		names.append("mobiel_%d" % (k + 1))
	for n in names:
		DirAccess.make_dir_recursive_absolute(_split.path_join(n))
	while true:
		await RenderingServer.frame_post_draw
		for k in _panes.size():
			_panes[k].get_texture().get_image().save_jpg(_split.path_join(names[k]).path_join("%05d.jpg" % _frame), 0.92)
		_frame += 1


## The players answer one after the other: true = right. Waits for the reveal.
func _answer(quiz: QuizRound, right: Dictionary, gap := 0.5) -> void:
	await _until(func(): return quiz._phase == "question", 30.0)
	await _wait(1.5)
	var correct := int(quiz._questions[quiz._index].correct)
	for id in right:
		if arena.is_playing(id) and id in quiz.players:
			var answer: int = correct if right[id] else (correct + 1 + id % 3) % 4
			arena.tiles[id - 1].press_button(QuizRound.ANSWER_BUTTONS[answer])
			await _wait(gap)
	await _until(func(): return quiz._phase == "reveal", 40.0)
	await _wait(4.0)


func _until(cond: Callable, timeout := 60.0) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
