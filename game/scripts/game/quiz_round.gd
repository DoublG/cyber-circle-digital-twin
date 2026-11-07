class_name QuizRound
extends GameRound
## Shared round: ONE question with 4 answers on all screens, then the
## scoreboard (every quiz round is one question; the randomizer puts the other
## games in between). Each answer has the
## colour and icon of a button.
## After every question the attacks are combined:
## No points and no places: the quiz is about staying in the game.
## Correct: you stay in the game; all correct players attack the robot
##          together (green, tile -> robot); if everyone was right the robot
##          overloads (special animation).
## Wrong or no answer: the robot hits back at all of them at once (red,
##          robot -> tile): -1 life (at the end of the round, at most 1).
## Protected: a player younger than the question's min_age gets a shield
##          (dome over the tile, blue LED ring, shield on the screen). A wrong
##          answer then costs nothing: the robot's shot bounces off.
##
## Question format (data/questions.json), only question/answers/correct required:
##   "question":    the question (big text)
##   "text":        longer text shown under the question (context, a story...)
##   "answers":     4 answers, in ANSWER_BUTTONS order
##   "correct":     index of the right answer
##   "time":        seconds to answer (default question_time)
##   "explanation": shown after the reveal
##   "category":    e.g. "Online veiligheid" (shown on the screen, see categories)
##   "min_age":     younger players are protected (no life lost when wrong)
##   "max_age":     only used to show the age range
##   "video":       Theora .ogv file: a name in data/videos/, a res:// path or
##                  an absolute path (videos outside the project, no re-export)
##   "video_when":  "before" (default): the video plays first, full width, and
##                  answering starts when it ends; "during": it loops next to
##                  the question while players answer
##   "image":       a picture next to the question (.png / .jpg / .webp): a
##                  name in data/images/, a res:// path or an absolute path

const QUESTIONS_FILE := "res://data/questions.json"
const VIDEO_DIR := "res://data/videos/"
const IMAGE_DIR := "res://data/images/"
## answer 1..4 = these buttons (and their colours); same order as the icons on
## the glass seen from the player's spot: top-left, top-right, bottom-left, bottom-right
const ANSWER_BUTTONS: Array[StringName] = [&"Square", &"Triangle", &"Cross", &"Circle"]

var categories: Array = []         # only questions from these categories (empty = all)
var question := ""                 # one chosen question (its id or its text; the plan, a demo): asked whatever the ages
var question_time := 15.0
var reveal_time := 5.0
var answers_time := 3.0            # s: everyone's answer shown, before who was right
var read_time := 3.5               # s: the question + buttons, before the answers appear
var timeup_time := 1.2             # s: "TIJD OM!" between answering and the answers
## Steps of a question (the screen is a slide show, one step at a time):
##   [video] -> read (the question) -> question (answers + countdown) ->
##   timeup -> answers (everyone's icon) -> reveal (who was right)

var _questions: Array = []
var _index := -1
var _phase := "question"           # "video", "question" or "reveal"
var _video_file := ""              # (a display node plays the question's video / shows its picture itself)
var _video_loop := false
var _image_file := ""
var _phase_left := 0.0
var _question_time := 15.0         # time for the current question
var _video: VideoStreamPlayer      # one decoder; every screen shows its texture
var _image: Texture2D              # the question's picture (or null)
var _answers := {}                 # tile_id -> answer index
var _wrong := {}                   # tile_id -> wrong / no answers (not counting shielded ones)
var _tick := 0                     # the countdown's last whole second (a sound + light cue for each of the last 5)
var _streak_bonus := {}            # tile_id -> true: reached a streak milestone this round
var _done := false


func _init() -> void:
	title = "Quiz"
	mode = "shared"
	gives_lives = false            # (only through the streak)
	can_repeat = true              # the backbone of the game: quiz after quiz
	ranked = false                 # right: you stay, wrong: -1 life
	duration = 999.0               # ends after the last question
	rules = _rules(10)


func _rules(streak: int) -> String:
	return ("Druk op je tegel op het icoon van je antwoord (zelfde vorm, kleur en plek).\nJe mag je antwoord veranderen tot de tijd om is: je laatste keuze telt.\nJuist: je blijft in het spel. Fout of te laat: je verliest een leven.\n%d juiste antwoorden op rij = +1 leven!" % streak)


func tunables() -> Array:            # (no duration: the round ends after the last question)
	return [
		setting("read_time", "Leestijd vraag (zonder antwoorden)", 0, 15, 0.5, "s"),
		setting("question_time", "Antwoordtijd", 5, 60, 1, "s"),
		setting("timeup_time", "Tijd om", 0, 5, 0.1, "s"),
		setting("answers_time", "Iedereens antwoord", 1, 10, 0.5, "s"),
		setting("reveal_time", "Wie had het goed", 1, 15, 0.5, "s"),
	]


func prepare(game_manager: GameManager, _tile_ids: Array) -> void:
	game = game_manager
	rules = _rules(game.streak_bonus)


func _start() -> void:
	_questions = _pick_questions(game.all_questions())
	_next_question()


## The question for this round from the chosen categories (a list: the tests
## and screenshots can put several in it, played one after the other). Questions that are
## too hard for every player (all younger than min_age) are skipped when there
## are enough others. Per question a category is drawn (game style, as the
## round types - GameManager.category_chances): its weight, plus drought
## protection for categories not asked for a while; then within it a question
## that was not asked yet, or the longest ago.
func _pick_questions(all: Array) -> Array:
	if question != "":
		var chosen := all.filter(func(q): return _qid(q) == question or str(q.get("question", "")) == question)
		if not chosen.is_empty():
			game.note_question(str(chosen[0].get("category", "")), _qid(chosen[0]))
			return [chosen[0]]
		push_warning("quiz: no question %s - one at random" % question)
	var pool := all.filter(func(q): return categories.is_empty() or q.get("category", "") in categories)
	var ages := players.map(func(id): return game.arena.player_age(id)).filter(func(a): return a > 0)
	if ages.size() == players.size() and not ages.is_empty():
		var oldest: int = ages.max()
		var fitting := pool.filter(func(q): return int(q.get("min_age", 0)) <= oldest)
		if not fitting.is_empty():
			pool = fitting
	var memory: Dictionary = game.question_memory
	var picked := []
	for n in 1:
		var chances := game.category_chances(pool)
		if chances.is_empty():
			break
		var r := randf()
		var cat: String = chances.keys().back()
		for c in chances:
			r -= chances[c]
			if r <= 0.0:
				cat = c
				break
		var in_cat := pool.filter(func(q): return str(q.get("category", "")) == cat)
		in_cat.shuffle()                                        # (equal ones: at random)
		in_cat.sort_custom(func(a, b): return int(memory.asked.get(_qid(a), -1)) < int(memory.asked.get(_qid(b), -1)))
		var q: Dictionary = in_cat[0]
		picked.append(q)
		pool.erase(q)
		game.note_question(cat, _qid(q))
	return picked


func _qid(q: Dictionary) -> String:
	return str(q.get("id", q.get("question", "")))


## The current question is too hard for this player's age: wrong costs nothing.
func is_protected(id: int) -> bool:
	if _index < 0 or _index >= _questions.size():
		return false
	var age: int = game.arena.player_age(id)
	return age > 0 and age < int(_questions[_index].get("min_age", 0))


func is_finished() -> bool:
	return _done


func shared_countdown() -> float:              # the answer time (the ring on the screens)
	return _phase_left if _phase == "question" else -1.0


func _next_question() -> void:
	_index += 1
	if _index >= _questions.size():
		_done = true
		return
	_answers.clear()
	var q: Dictionary = _questions[_index]
	for id in players:
		tile(id).shielded = is_protected(id) and not tile(id).is_dead
	var own_time := float(q.get("time", 0))                   # the question's own time (0: the setting)
	_question_time = own_time / game.tempo if own_time > 0.0 else question_time
	_stop_video()
	_image_file = str(q.get("image", ""))
	_image = _load_image(_image_file) if q.has("image") else null
	if q.has("video"):
		var during: bool = q.get("video_when", "before") == "during"
		_play_video(q.video, during)
		if _video and not during:
			_phase = "video"
			for id in players:
				for b in CyberTile.BUTTONS:
					game.arena.rt(tile(id)).set_button_led(b, Color.BLACK)
			return
	_read()


## The question's picture: a name in data/images/, a res:// path or a file.
func _load_image(file: String) -> Texture2D:
	var path := file
	if not path.begins_with("res://") and not path.is_absolute_path():
		path = IMAGE_DIR + path
	if path.begins_with("res://"):
		return load(path) if ResourceLoader.exists(path) else null
	var img := Image.load_from_file(path) if FileAccess.file_exists(path) else null
	if img == null:
		push_warning("quiz: image not found: %s" % file)
		return null
	return ImageTexture.create_from_image(img)


## Step: the question and the 4 buttons, without the answers yet (the icons
## on the tile are dark: no answering yet); then the answers and the countdown.
func _read() -> void:
	_phase = "read"
	_phase_left = read_time
	var q: Dictionary = _questions[_index]
	game.arena.narrator.say(Narrator.question_name(q), str(q.question), "question", {}, true)
	for id in players:
		for b in CyberTile.BUTTONS:
			game.arena.rt(tile(id)).set_button_led(b, Color.BLACK)


func _start_answering() -> void:
	_phase = "question"
	_phase_left = _question_time
	var q: Dictionary = _questions[_index]
	var qn := Narrator.question_name(q)
	for n in mini(q.answers.size(), 4):                     # read out after the question
		game.arena.narrator.say("%s_answer_%d" % [qn, n + 1], Narrator.answer_line(q, n), "answer", {"answer": n + 1})
	for id in players:
		for b in CyberTile.BUTTONS:
			game.arena.rt(tile(id)).set_button_led(b, CyberTile.BUTTON_COLORS[b])


func _play_video(file: String, loop: bool) -> void:
	var path := file
	if not path.begins_with("res://") and not path.is_absolute_path():
		path = VIDEO_DIR + path
	var stream: VideoStream
	if path.begins_with("res://"):
		stream = load(path) if ResourceLoader.exists(path) else null
	elif FileAccess.file_exists(path):
		stream = VideoStreamTheora.new()
		stream.file = path
	if stream == null:
		push_warning("quiz: video not found: %s" % file)
		return
	_video = VideoStreamPlayer.new()
	_video.stream = stream
	_video.loop = loop
	_video_file = file
	_video_loop = loop
	if not game.arena.sound.plays_here():
		_video.volume_db = -80.0       # (its sound: on the display nodes)
	_video.visible = false         # decoded once; the screens draw its texture
	game.add_child(_video)
	_video.play()


func _stop_video() -> void:
	_video_file = ""
	if _video:
		_video.stop()
		_video.queue_free()
		_video = null


func _update(delta: float) -> void:
	if _done:
		return
	_phase_left -= delta
	if _phase == "question":             # the last seconds: a tick each (sound, light cue)
		var left := ceili(_phase_left)
		if left != _tick and left >= 1 and left <= 5:
			game.arena.cue(&"countdown", 0, {"seconds": left})
		_tick = left
	if _phase == "video":
		if _video == null or not _video.is_playing():
			_stop_video()
			_read()
	elif _phase == "read" and _phase_left <= 0.0:
		_start_answering()
	elif _phase == "question" and _phase_left <= 0.0:   # always the full time: answers can change
		_phase = "timeup"
		_phase_left = timeup_time
		game.arena.narrator.say("time_up", "Tijd om!", "time_up", {}, true)
		game.arena.sound.play(&"time_up")
	elif _phase == "timeup" and _phase_left <= 0.0:
		_phase = "answers"               # everyone's answer icon
		_phase_left = answers_time
	elif _phase == "answers" and _phase_left <= 0.0:
		_reveal()                        # step 2 (same slide): who was right (the right answer is never shown)
	elif _phase == "reveal" and _phase_left <= 0.0:
		_next_question()
		if _done:
			return
	var q: Dictionary = _questions[_index]
	var status := []
	for id in players:
		var answer: int = _answers[id].answer if _answers.has(id) else -1
		status.append({"id": id, "name": game.arena.player_name(id), "dead": tile(id).is_dead,
			"answer": answer, "protected": is_protected(id), "streak": game.streaks.get(id, 0),
			"ok": answer == int(q.correct) if _phase == "reveal" else null})
	var ages := ""
	if q.has("min_age") or q.has("max_age"):
		ages = "%d-%d JAAR" % [int(q.get("min_age", 0)), int(q.get("max_age", 99))] if q.has("max_age") \
			else "%d+ JAAR" % int(q.min_age)
	var video_frac := 0.0
	if _video and _video.get_stream_length() > 0.0:
		video_frac = _video.stream_position / _video.get_stream_length()
	var state := {
		"phase": _phase,
		"category": str(q.get("category", "")), "ages": ages,
		"question": q.question, "answers": q.answers,
		"text": q.get("text", ""),
		"video": _video.get_video_texture() if _video else null,
		"media": _video.get_video_texture() if _video else _image,   # left of the question
		"video_progress": video_frac,
		"time_left": _phase_left,
		"time_total": {"question": _question_time, "answers": answers_time, "read": read_time,
			"timeup": timeup_time}.get(_phase, reveal_time),
		"players": status,
	}
	for view in game.screen_wall.shared_views:
		view.show_question(state)
	var out := state.duplicate()                  # (to the display nodes: files, not textures)
	out.erase("video")
	out.erase("media")
	out["video_file"] = _video_file
	out["video_loop"] = _video_loop
	out["image_file"] = _image_file if _image else ""
	Replica.relay_live("round", &"replica_show", [out])


## A display node: the master's quiz screen; the video and the picture are its own.
func replica_show(st: Dictionary) -> void:
	var vf := str(st.get("video_file", ""))
	if vf != _video_file:
		_stop_video()
		if vf != "":
			_play_video(vf, bool(st.get("video_loop", false)))
	var img := str(st.get("image_file", ""))
	if img != _image_file:
		_image_file = img
		_image = _load_image(img) if img != "" else null
	st["video"] = _video.get_video_texture() if _video else null
	st["media"] = _video.get_video_texture() if _video else _image
	for view in game.screen_wall.shared_views:
		if is_instance_valid(view) and view.has_method("show_question"):   # (a late one: the view moved on)
			view.show_question(st)


func replica_end() -> void:
	_stop_video()


## Players can change their answer until the time is up: the last one counts.
## The chosen icon lights up on the tile (others may see it - switching at
## the last second is allowed tactics); no speed points.
func button(id: int, b: StringName) -> void:
	if _phase != "question":
		return
	var was: int = _answers[id].answer if _answers.has(id) else -1
	_answers[id] = {"answer": ANSWER_BUTTONS.find(b)}
	if was != _answers[id].answer:                         # (for the player's accessible page)
		game.arena.narrator.say_to(id, "answer", "Je koos %s." % Narrator.ICON_NAMES[_answers[id].answer])
	for other in CyberTile.BUTTONS:  # only the chosen icon stays lit
		game.arena.rt(tile(id)).set_button_led(other, CyberTile.BUTTON_COLORS[other] if other == b else Color.BLACK)


func _reveal() -> void:
	_phase = "reveal"
	_phase_left = reveal_time
	var correct := int(_questions[_index].correct)
	var right: Array[int] = []
	var wrong: Array[int] = []
	var shielded: Array[int] = []
	for id in players:
		if tile(id).is_dead:
			continue
		if _answers.has(id) and _answers[id].answer == correct:
			right.append(id)
			_count_streak(id, true)
		elif is_protected(id):
			shielded.append(id)
			_count_streak(id, false)
		else:
			wrong.append(id)
			_wrong[id] = _wrong.get(id, 0) + 1
			_count_streak(id, false)
	for id in right:
		game.arena.narrator.say_to(id, "right", "Goed!")
	for id in wrong:
		game.arena.narrator.say_to(id, "wrong", "Fout." if _answers.has(id) else "Geen antwoord.")
	for id in shielded:
		game.arena.narrator.say_to(id, "shielded", "Fout, maar je schild beschermt je.")
	_attacks(right, wrong, shielded)


## First the players' combined attack, then the robot's combined counter-attack.
## Shielded players are shot at too, but the shield blocks it. The robot's shot
## only shows the answer was wrong: lives change at the end of the round.
func _attacks(right: Array[int], wrong: Array[int], shielded: Array[int]) -> void:
	var any_wrong := not (wrong.is_empty() and shielded.is_empty())
	if not right.is_empty():
		game.arena.sound.play(&"quiz_right")
	game.arena.players_attack(right, not any_wrong)
	if not right.is_empty() and any_wrong:
		await game.get_tree().create_timer(1.6).timeout
	if any_wrong:
		game.arena.sound.play(&"quiz_wrong")
	game.arena.robot_attack(wrong, Color(1.0, 0.1, 0.05), shielded, false)


## Answer streak (kept over rounds by the game): right +1, wrong / no answer
## back to 0. Every `streak_bonus` in a row earns a life at the end of the round.
func _count_streak(id: int, right: bool) -> void:
	var n: int = game.streaks.get(id, 0) + 1 if right else 0
	game.streaks[id] = n
	if right and n % game.streak_bonus == 0:
		_streak_bonus[id] = true
		game.screen_wall.popup(id, "%d OP RIJ!" % n, Retro.GOOD, false)
		game.log_event("%s: %d JUIST OP RIJ - +1 LEVEN" % [game.arena.player_name(id).to_upper(), n], Retro.GOOD)


## End of the quiz: any wrong (or no) answer -1 life; a streak milestone +1
## (together: at most 1 either way). Wrong answers on questions too hard for
## the player's age don't cost a life (but do end the streak).
func life_changes() -> Dictionary:
	var out := {}
	for id in players:
		if tile(id).is_dead or not game.arena.is_playing(id):
			continue
		var d := (-1 if _wrong.get(id, 0) > 0 else 0) + (1 if _streak_bonus.has(id) else 0)
		if d != 0:
			out[id] = d
	return out



func finish() -> void:
	_stop_video()
	for id in players:
		tile(id).shielded = false


func make_shared_view() -> Control:
	return QuizView.new()
