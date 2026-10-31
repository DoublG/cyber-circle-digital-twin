class_name QuizRound
extends GameRound
## Shared round: a question with 4 answers on all screens. Each answer has the
## colour and icon of a button.
## After every question the attacks are combined:
## Correct: 5 points + up to 5 speed bonus. All correct players attack the robot
##          together (green, tile -> robot); if everyone was right the robot
##          overloads (special animation).
## Wrong or no answer: the robot hits back at all of them at once (red,
##          robot -> tile): -1 life each.
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

const QUESTIONS_FILE := "res://data/questions.json"
const VIDEO_DIR := "res://data/videos/"
## answer 1..4 = these buttons (and their colours); same order as the icons on
## the glass seen from the player's spot: top-left, top-right, bottom-left, bottom-right
const ANSWER_BUTTONS: Array[StringName] = [&"Square", &"Triangle", &"Cross", &"Circle"]

var question_count := 3
var categories: Array = []         # only questions from these categories (empty = all)
var question_time := 15.0
var reveal_time := 5.0
var answers_time := 3.0            # s: everyone's answer shown, before who was right
var read_time := 3.5               # s: only the question, before the answers appear
var timeup_time := 1.2             # s: "TIJD OM!" between answering and the answers
## Steps of a question (the screen is a slide show, one step at a time):
##   [video] -> read (the question) -> question (answers + countdown) ->
##   timeup -> answers (everyone's icon) -> reveal (who was right)

var _questions: Array = []
var _index := -1
var _phase := "question"           # "video", "question" or "reveal"
var _phase_left := 0.0
var _question_time := 15.0         # time for the current question
var _video: VideoStreamPlayer      # one decoder; every screen shows its texture
var _answers := {}                 # tile_id -> answer index
var points_per_answer := 10
var _wrong := {}                   # tile_id -> wrong / no answers (not counting shielded ones)
var _streak_bonus := {}            # tile_id -> true: reached a streak milestone this round
var _done := false


func _init() -> void:
	title = "Quiz"
	mode = "shared"
	gives_lives = false            # (only through the streak)
	duration = 999.0               # ends after the last question
	rules = _rules(10)


func _rules(streak: int) -> String:
	return ("Druk op je tegel op het icoon van je antwoord (zelfde vorm, kleur en plek).\nJe mag je antwoord veranderen tot de tijd om is: je laatste keuze telt.\nJuist = %d punten. %d juiste antwoorden op rij = +1 leven!\nNa de ronde: een fout of geen antwoord kost een leven." % [points_per_answer, streak])


func tunables() -> Array:            # (no duration: the round ends after the last question)
	return [
		setting("question_count", "Vragen per ronde", 1, 10, 1),
		setting("read_time", "Leestijd vraag", 0, 15, 0.5, "s"),
		setting("question_time", "Antwoordtijd", 5, 60, 1, "s"),
		setting("timeup_time", "Tijd om", 0, 5, 0.1, "s"),
		setting("answers_time", "Iedereens antwoord", 1, 10, 0.5, "s"),
		setting("reveal_time", "Wie had het goed", 1, 15, 0.5, "s"),
		setting("points_per_answer", "Punten juist antwoord", 0, 100, 1),
	]


func prepare(game_manager: GameManager, _tile_ids: Array) -> void:
	game = game_manager
	rules = _rules(game.streak_bonus)


func _start() -> void:
	_questions = _pick_questions(game.all_questions())
	_next_question()


## The questions for this round from the chosen categories. Questions that are
## too hard for every player (all younger than min_age) are skipped when there
## are enough others. Per question a category is drawn (game style, as the
## round types - GameManager.category_chances): its weight, plus drought
## protection for categories not asked for a while; then within it a question
## that was not asked yet, or the longest ago.
func _pick_questions(all: Array) -> Array:
	var pool := all.filter(func(q): return categories.is_empty() or q.get("category", "") in categories)
	var ages := players.map(func(id): return game.arena.player_age(id)).filter(func(a): return a > 0)
	if ages.size() == players.size() and not ages.is_empty():
		var oldest: int = ages.max()
		var fitting := pool.filter(func(q): return int(q.get("min_age", 0)) <= oldest)
		if fitting.size() >= question_count:
			pool = fitting
	var memory: Dictionary = game.question_memory
	var picked := []
	for n in question_count:
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
	if q.has("video"):
		var during: bool = q.get("video_when", "before") == "during"
		_play_video(q.video, during)
		if _video and not during:
			_phase = "video"
			for id in players:
				for b in CyberTile.BUTTONS:
					tile(id).set_button_led(b, Color.BLACK)
			return
	_read()


## Step: only the question, to read it (the icons are dark: no answering yet).
func _read() -> void:
	_phase = "read"
	_phase_left = read_time
	for id in players:
		for b in CyberTile.BUTTONS:
			tile(id).set_button_led(b, Color.BLACK)


func _start_answering() -> void:
	_phase = "question"
	_phase_left = _question_time
	for id in players:
		for b in CyberTile.BUTTONS:
			tile(id).set_button_led(b, CyberTile.BUTTON_COLORS[b])


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
	_video.visible = false         # decoded once; the screens draw its texture
	game.add_child(_video)
	_video.play()


func _stop_video() -> void:
	if _video:
		_video.stop()
		_video.queue_free()
		_video = null


func _update(delta: float) -> void:
	if _done:
		return
	_phase_left -= delta
	if _phase == "video":
		if _video == null or not _video.is_playing():
			_stop_video()
			_read()
	elif _phase == "read" and _phase_left <= 0.0:
		_start_answering()
	elif _phase == "question" and _phase_left <= 0.0:   # always the full time: answers can change
		_phase = "timeup"
		_phase_left = timeup_time
	elif _phase == "timeup" and _phase_left <= 0.0:
		_phase = "answers"               # everyone's answer icon
		_phase_left = answers_time
	elif _phase == "answers" and _phase_left <= 0.0:
		_reveal()                        # step 2: who was right (the right answer is never shown)
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
		"number": _index + 1, "total": _questions.size(), "phase": _phase,
		"category": str(q.get("category", "")), "ages": ages,
		"question": q.question, "answers": q.answers,
		"text": q.get("text", ""),
		"video": _video.get_video_texture() if _video else null,
		"video_progress": video_frac,
		"time_left": _phase_left,
		"time_total": {"question": _question_time, "answers": answers_time, "read": read_time,
			"timeup": timeup_time}.get(_phase, reveal_time),
		"players": status,
	}
	for view in game.screen_wall.shared_views:
		view.show_question(state)


## Players can change their answer until the time is up: the last one counts.
## The chosen icon lights up on the tile (others may see it - switching at
## the last second is allowed tactics); no speed points.
func button(id: int, b: StringName) -> void:
	if _phase != "question":
		return
	_answers[id] = {"answer": ANSWER_BUTTONS.find(b)}
	for other in CyberTile.BUTTONS:  # only the chosen icon stays lit
		tile(id).set_button_led(other, CyberTile.BUTTON_COLORS[other] if other == b else Color.BLACK)


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
			add_points(id, points_per_answer)
			right.append(id)
			_count_streak(id, true)
		elif is_protected(id):
			shielded.append(id)
			_count_streak(id, false)
		else:
			wrong.append(id)
			_wrong[id] = _wrong.get(id, 0) + 1
			_count_streak(id, false)
	_attacks(right, wrong, shielded)


## First the players' combined attack, then the robot's combined counter-attack.
## Shielded players are shot at too, but the shield blocks it. The robot's shot
## only shows the answer was wrong: lives change at the end of the round.
func _attacks(right: Array[int], wrong: Array[int], shielded: Array[int]) -> void:
	game.arena.players_attack(right, wrong.is_empty() and shielded.is_empty())
	if not right.is_empty() and not (wrong.is_empty() and shielded.is_empty()):
		await game.get_tree().create_timer(1.6).timeout
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
