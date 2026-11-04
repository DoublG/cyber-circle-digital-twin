class_name GameManager
extends Node
## Continuous, round-based game: as long as there are players, round follows
## round - players come (they play from the next round) and go (exterminated).
##   LOBBY      nobody playing; starts automatically after auto_start_delay
##              once someone has activated a tile
##   INTRO      round title, rules and countdown on all screens
##   PLAYING    personal round: every player's own view (split screen)
##              shared round:   the same view on all screens
##   SCOREBOARD this round's places with the lives to gain / lose (UITSLAG; not
##              after the quiz), then the standing of the players in the game
##              with the lives changing (SCOREBORD), then the next round
## When the last player is gone the game goes back to the LOBBY (stop_game
## ends it at once). In the database one game = from start to the lobby; every
## player's result is saved when they leave.
## Counters (names on the screens in brackets):
##   points    (PUNTEN)  within one round; they decide the round's places
##                       (not in the quiz: right = stay, wrong = -1 life)
##   lives     (LEVENS)  max 5; change ONLY at the end of a round, by at most 1
##                       (GameRound.life_changes: 1st place +1, last -1; the
##                       quiz only takes: a wrong answer -1). 0 = exterminated.
##   streak    (OP RIJ)  quiz answers right in a row, over rounds; every
##                       `streak_bonus` in a row: +1 life (at the end of that round)
##   survived  (RONDES)  rounds survived this play: the ranking during the game
##   record    (RECORD)  a player's most rounds survived over all plays
##   place     (#)       the overall ranking by record - live while playing
## Players can play many times (each time from 0).
## The next rounds are planned ahead (`upcoming`, shown in the web interface,
## which can set them: a chosen round is always played).
## Every quiz round is one question. Round types are picked at random (the
## other games never twice in a row; quiz after quiz can); with fewer
## than `personal_min_players` players only shared rounds (the quiz) are played:
## personal rounds always have a loser, in the quiz everyone can stay alive.
## Questions come from the database, which also keeps the scores (GameDb).
## A player loses at most 1 life per round (take_life). At 0 lives they are
## exterminated: the tile blinks red, the robot's death animation plays and
## the tile becomes free again (the player leaves the game).

signal state_changed(state: State)
signal mode_changed(mode: Mode)
## Something worth telling visitors happened (overview page event feed).
signal game_event(text: String, color: Color)
signal ranking_shown(title: String, label: String, rows: Array)     # this round's places (UITSLAG)
signal scores_shown(title: String, subtitle: String, rows: Array)   # the scoreboard after a round
signal settings_changed
signal lives_revealed                  # the scoreboard shows the lives changing (+1 / -1 / exterminated)

enum State { LOBBY, INTRO, PLAYING, SCOREBOARD }
## Operating mode, set by the operator (web interface -> control server -> MQTT `mode`):
##   SETUP   physical setup: tiles and screens are assigned; game closed, the
##           screens show every slot's tile number
##   CLOSED  setup locked, game closed (no players)
##   OPEN    players can join; nobody playing = idle; rounds start by themselves
##   PAUSED  everything frozen (round timers, the tile games); OPEN resumes
## Without a control server the game starts OPEN.
enum Mode { SETUP, CLOSED, OPEN, PAUSED }

const ROUND_TYPES := [preload("res://scripts/game/cyclone_round.gd"),
	preload("res://scripts/game/quiz_round.gd"), preload("res://scripts/game/reaction_round.gd"),
	preload("res://scripts/game/rhythm_round.gd"), preload("res://scripts/game/simon_round.gd"),
	preload("res://scripts/game/zwarte_piet_round.gd")]

## Game settings the operator can change (see settings_schema); every round
## type has its own (GameRound.tunables). tempo > 1: every time shorter.
const GAME_TUNABLES := [
	{"key": "tempo", "label": "Tempo (x, alle tijden)", "min": 0.5, "max": 2.0, "step": 0.05, "unit": ""},
	{"key": "intro_time", "label": "Uitleg voor een ronde", "min": 2, "max": 30, "step": 1, "unit": "s"},
	{"key": "result_time", "label": "Uitslag (plaatsen, levens)", "min": 0, "max": 30, "step": 1, "unit": "s"},
	{"key": "scoreboard_time", "label": "Scorebord", "min": 2, "max": 30, "step": 1, "unit": "s"},
	{"key": "clip_time", "label": "Doodsfilmpje op eigen scherm (min.)", "min": 2, "max": 60, "step": 1, "unit": "s"},
	{"key": "clip_wait", "label": "Doodsfilmpje wacht op eigen scherm max.", "min": 0, "max": 120, "step": 5, "unit": "s"},
	{"key": "auto_start_delay", "label": "Start na eerste speler", "min": 0, "max": 120, "step": 5, "unit": "s"},
	{"key": "lives", "label": "Levens (leeftijd onbekend)", "min": 1, "max": 5, "step": 1, "unit": ""},
	{"key": "lives_age_8", "label": "Levens t/m 8 jaar", "min": 1, "max": 5, "step": 1, "unit": ""},
	{"key": "lives_age_10", "label": "Levens 9 - 10 jaar", "min": 1, "max": 5, "step": 1, "unit": ""},
	{"key": "lives_age_99", "label": "Levens vanaf 11 jaar", "min": 1, "max": 5, "step": 1, "unit": ""},
	{"key": "streak_bonus", "label": "Juist op rij voor +1 leven", "min": 2, "max": 50, "step": 1, "unit": ""},
	{"key": "personal_min_players", "label": "Spelers nodig voor eigen spellen", "min": 1, "max": 13, "step": 1, "unit": ""},
	{"key": "queue_length", "label": "Rondes vooruit gepland", "min": 1, "max": 10, "step": 1, "unit": ""},
]

@export var tempo := 1.0
@export var intro_time := 7.0
@export var scoreboard_time := 8.0
@export var result_time := 10.0        # the UITSLAG board (places, lives) before the scoreboard
@export var lives_delay := 2.5         # s the scoreboard shows before the lives change
@export var auto_start_delay := 20.0   # seconds after the first player joins; 0 = start manually
@export var lives := 5                 # lives when the player's age is unknown
## Lives depend on age: {up to this age: lives}. Younger players get more
## lives (max 5, the hearts on the tile). Older than every key: the last value.
@export var lives_by_age := {8: 5, 10: 4, 99: 3}

var arena: Node3D
var screen_wall: ScreenWall
var state := State.LOBBY
var mode := Mode.OPEN
var scores := {}                       # tile_id -> total points this play (tie-break)
var survived := {}                     # tile_id -> rounds survived this play (RONDES)
var streaks := {}                      # tile_id -> quiz answers right in a row (OP RIJ)
@export var streak_bonus := 10         # this many right in a row: +1 life
var current: GameRound
var round_number := 0
var _timer := 0.0
var _lobby_timer := -1.0
var round_types: Array = ROUND_TYPES: set = set_round_types   # the round types to pick from
@export var random_rounds := true          # false: play round_types in order (tests)
@export var personal_min_players := 4      # fewer players: no personal rounds (they always have a loser)
@export var db_path := "res://data/cybercircle.db"   # standalone: the SQLite file itself
@export var control_url := ""              # installation: the control server owns the database
var db                                     # GameDb or ControlApi; null: none (JSON questions, no saving)
var game_id := 0                           # this game's id in the database
var _last_type: Script
@export var queue_length := 3              # rounds planned ahead
## The randomizer (game style: weighted random with drought protection and a
## "director", see round_chances): weight per round type (0 = never), the
## extra chance per round a type was not played, and how strongly the
## players' lives steer it.
var randomizer_off := {}                   # type name -> true: never drawn (the operator can still plan it)
var round_weights := {"cyclone": 1.0, "quiz": 5.0, "reaction": 1.0, "rhythm": 1.0, "simon": 1.0, "zwarte_piet": 1.0}
@export var drought := 0.5
@export var mercy := 1.0
var _history: Array[Script] = []           # the round types played, last at the end
## Questions (same style): weight per category (missing = 1, 0 = never) and
## the extra chance per question a category was not asked.
var category_weights := {}
@export var category_drought := 0.5
## What was asked (over all quiz rounds): {count: questions asked, since:
## {category: questions since it was last asked}, asked: {question id: count when}}.
var question_memory := {"count": 0, "since": {}, "asked": {}}
var upcoming: Array = []                   # [{type: Script, forced: bool, options: {}}]: the next rounds
var _planned := 0                          # rounds planned so far (fixed order: the index)
var _result_saved := {}                    # tile_id -> true once their result is in the database
var _records := {}                         # player_id -> {name, best, plays} from the database
var _started := {}                     # tile_id -> true once the player has had lives set
var _life_lost := {}                   # tile_id -> round_number in which they lost a life
var settings := {}                     # operator values: {"game": {key: v}, "<round type>": {key: v}}
var _game_defaults := {}
var _result_left := 0.0               # s the UITSLAG board still shows
var _lives_shown := false              # the scoreboard shows the lives after the change
var _score_seq := 0                    # (a skipped scoreboard stops its own sequence)
var _sound_defaults := {}
var _light_defaults := {}
var _voice_defaults := {}
var _countdown := 0                    # the last second announced (light cue "countdown")
var recovery: Recovery                 # crash / power cut: the game comes back where it was
@export var restore := true                # --no-restore: always a fresh start
@export var restore_max_age := 3600.0      # s: an older checkpoint is a previous day's game
var _current_entry := {}               # the round being played, as it was planned (replayed after a crash)
var _pending_lives := {}               # end of a round: the lives about to change {tile_id: -1/0/+1}
var _target_lives := {}                # ... and once given / taken: what they become (shots still flying)
var view := {}                         # what the screens show (show_view): a display node builds the same
var _view_seq := 0
var _replica_round := 0                # a display node: the master's round it has (instance id there)


## The scoreboard shows the lives changing (here and on the display nodes).
func reveal_lives() -> void:
	Replica.relay("game", &"reveal_lives", [])
	lives_revealed.emit()


# ---------------------------------------------------------------- what the screens show

## The screens show this (kinds: players [overlay: the round's, look_down],
## message (a round's intro), round (a shared round's view), ranking, scores).
## As data, so a display node (Replica) builds the very same views itself.
func show_view(v: Dictionary) -> void:
	_view_seq += 1
	view = v.merged({"seq": _view_seq}, true)
	_build_view()


func _build_view() -> void:
	var v := view
	match str(v.get("kind", "players")):
		"players":
			var f := Callable()
			if v.get("overlay", false) and current:
				f = func(id): return current.make_player_overlay(id) if in_round(id) else _waiting_overlay()
			screen_wall.show_players(f, bool(v.get("look_down", false)))
		"message":
			screen_wall.show_shared(func(): return MessageView.new())
		"round":
			if current:
				screen_wall.show_shared(current.make_shared_view)
		"ranking":
			screen_wall.show_shared(func():
				var r := RankingView.new()
				r.show_ranking(str(v.title), str(v.label), v.rows)
				return r)
		"scores":
			var rows: Array = v.rows
			screen_wall.show_shared(func():               # (also rebuilt when a player joins / leaves)
				var b := ScoreboardView.new()
				var shown := rows.duplicate()
				var listed := rows.map(func(r): return r.tile)
				for id in arena.player_ids():               # new players come in here: at the bottom
					if id not in listed and not arena.tiles[id - 1].is_dead:
						var h: int = arena.tiles[id - 1].health
						shown.append({"name": arena.player_name(id), "tile": id, "survived": 0, "lives": h,
							"lives_before": h, "change": 0, "score": 0, "delta": 0, "out": false, "was_out": false,
							"record": record(id), "rank": overall_rank(id), "new": true})
				b.show_scores(str(v.title), str(v.subtitle), shown, _lives_shown)
				lives_revealed.connect(b.reveal_lives)
				return b)


# ---------------------------------------------------------------- display nodes (Replica)

## What the display nodes' screens read of the game (Arena.replica_fields).
func replica_fields() -> Dictionary:
	var r := {}
	if current:
		r = {"id": current.get_instance_id(), "type": round_type_name(current.get_script()),
			"init": current.replica_init()}
	return {"g_state": state, "g_mode": mode, "scores": scores, "survived": survived, "streaks": streaks,
		"round_number": round_number, "records": _records, "started": _started, "lives_shown": _lives_shown,
		"tempo": tempo, "round": r, "round_sync": current.replica_sync() if current else {}, "view": view}


## A display node: the game's fields from the master.
func apply_replica(f: Dictionary, full: bool) -> void:
	for k in ["scores", "survived", "streaks", "round_number", "tempo"]:
		if f.has(k):
			set(k, f[k])
	if f.has("records"):
		_records = f.records
	if f.has("started"):
		_started = f.started
	if f.has("lives_shown"):
		_lives_shown = bool(f.lives_shown)
	if f.has("round"):
		var r: Dictionary = f.round
		if (r.is_empty() or _replica_round != int(r.get("id", 0))) and current:
			current.replica_end()
		if r.is_empty():
			current = null
			_replica_round = 0
		elif current == null or _replica_round != int(r.id):
			var t: Script = _round_type(str(r.type))
			current = t.new() if t else null
			_replica_round = int(r.id)
			if current:
				current.replica_begin(self, r.init)
		elif current:
			current.replica_begin(self, r.init)
	if f.has("round_sync") and current:
		current.apply_replica_sync(f.round_sync)
	if f.has("g_mode") and int(f.g_mode) != mode:
		mode = int(f.g_mode) as Mode
		mode_changed.emit(mode)
	if f.has("g_state") and int(f.g_state) != state:
		state = int(f.g_state) as State
		state_changed.emit(state)
	if f.has("view") and (full or int(f.view.get("seq", -1)) != int(view.get("seq", -2))):
		view = f.view
		_build_view()


## A display node: no database, no game logic - only the screens.
func setup_replica(arena_node: Node3D) -> void:
	arena = arena_node
	screen_wall = arena.screen_wall
	restore = false
	show_view({"kind": "players"})


func setup(arena_node: Node3D) -> void:
	arena = arena_node
	for t in GAME_TUNABLES + _randomizer_tunables():
		_game_defaults[t.key] = _get_game_setting(t.key)
	_game_defaults["category_drought"] = category_drought
	for t in arena.sound.tunables():
		_sound_defaults[t.key] = arena.sound.get(t.key)
	for t in arena.lights.tunables():
		_light_defaults[t.key] = arena.lights.get(t.key)
	for t in arena.narrator.tunables():
		_voice_defaults[t.key] = arena.narrator.get(t.key)
	screen_wall = arena.screen_wall
	if control_url != "":
		use_control_server(control_url)
	else:
		use_database(db_path)
	_load_records()
	_enter_lobby()
	recovery = Recovery.new()
	recovery.name = "Recovery"
	recovery.game = self
	recovery.enabled = restore
	recovery.max_age = restore_max_age
	add_child(recovery)
	recovery.restore.call_deferred()


## A stable moment: the game as it is now is what comes back after a crash.
func _checkpoint() -> void:
	if recovery:
		recovery.mark()


## Back after a crash / power cut (Recovery.apply): on the scoreboard - the
## lives that were about to change change now (exterminations too), then the
## next round. A round that was interrupted is played again (it never counted).
func resume(changes: Dictionary) -> void:
	current = null
	_lives_shown = false
	_score_seq += 1
	var seq := _score_seq
	_set_state(State.SCOREBOARD)
	_timer = INF
	log_event("HET SPEL GAAT VERDER (RONDE %d)" % (round_number + 1), Retro.TEAL)
	_show_scores("Scorebord", "Het spel gaat verder", {}, changes)
	await get_tree().create_timer(lives_delay / tempo).timeout
	if state != State.SCOREBOARD or seq != _score_seq:
		return
	_lives_shown = true
	reveal_lives()
	if not changes.is_empty():
		_apply_lives(changes)
	_timer = scoreboard_time / tempo


## Open another database file ("" = none); e.g. a test database.
## The installation: questions, players and scores through the control server.
func use_control_server(url: String) -> void:
	var api := ControlApi.new()
	api.name = "ControlApi"
	add_child(api)
	api.open(url)
	api.changed.connect(_load_records)
	db = api


## Standalone: open the SQLite file directly ("" = no database).
func use_database(path: String) -> void:
	if path.begins_with("res://") and not OS.has_feature("editor"):
		# an exported build can't write inside itself: use the folder of the program
		path = OS.get_executable_path().get_base_dir().path_join(path.get_file())
	db_path = path
	var file := GameDb.new()
	db = file if path != "" and file.open(path) else null


func _process(delta: float) -> void:
	if Replica.client:                   # a display node: the round's clocks run on between the master's updates
		if current and mode != Mode.PAUSED:
			current.replica_tick(delta)
		return
	if mode == Mode.PAUSED:
		return                           # frozen: no timers, no rounds
	match state:
		State.LOBBY:
			if _lobby_timer >= 0.0:
				_lobby_timer -= delta
				screen_wall.set_timer("Start over %d" % ceili(_lobby_timer))
				if _lobby_timer <= 0.0:
					start_game()
		State.INTRO:
			_timer -= delta
			screen_wall.call_shared(&"show_message", [current.title, current.rules,
				"Start over %d" % ceili(_timer)], true)
			if _timer <= 0.0:
				_begin_round()
		State.PLAYING:
			current.update(delta)
			if current and current.mode == "personal":
				screen_wall.set_timer("%d" % ceili(maxf(current.time_left, 0.0)))
				var left := ceili(current.time_left)
				if left != _countdown and left >= 1 and left <= 5:   # the last seconds: a light cue each
					arena.cue(&"countdown", 0, {"seconds": left})
				_countdown = left
			if current.is_finished() or _alive_players().is_empty():
				_end_round()
		State.SCOREBOARD:
			_timer -= delta
			if _timer <= 0.0:
				_next_round()


# ---------------------------------------------------------------- flow

func start_game() -> void:
	if state != State.LOBBY or arena.player_ids().is_empty() or mode != Mode.OPEN:
		return
	game_id = db.start_game() if db else 0
	if not random_rounds:                # fixed order (tests): from the first type
		upcoming.clear()
		_planned = 0
	_result_saved.clear()
	scores.clear()
	survived.clear()
	streaks.clear()
	_started.clear()
	for id in arena.player_ids():
		scores[id] = 0
		survived[id] = 0
	round_number = 0
	_lobby_timer = -1.0
	_next_round()


## Skip the current phase (operator key N).
func skip() -> void:
	match state:
		State.LOBBY:
			start_game()
		State.INTRO:
			_timer = 0.0
		State.PLAYING:
			_end_round()
		_:
			if _result_left > 0.0:
				_result_left = 0.0                # UITSLAG -> the scoreboard
			else:
				_timer = 0.0


func stop_game() -> void:
	if current:
		current.finish()
	current = null
	_finish_game()


func _next_round() -> void:
	if arena.player_ids().is_empty():    # the last player is gone: back to the lobby
		_finish_game()
		return
	round_number += 1                    # counts rounds (database, 1 life per round)
	_plan_rounds()
	var entry: Dictionary = upcoming.pop_front()
	_current_entry = entry
	_target_lives.clear()
	_last_type = entry.type
	_history.append(_last_type)
	if _history.size() > 20:
		_history.pop_front()
	_plan_rounds()
	current = _last_type.new()
	current.configure(settings.get(round_type_name(_last_type), {}))   # operator settings ...
	current.configure(entry.get("options", {}))                         # ... this round in the plan
	for t in current.tunables():                                        # the tempo: all times
		if t.unit in ["s", "ms"] and not t.key.begins_with("latency"):   # (a hardware delay: not a game time)
			var v = current.get(t.key) / tempo
			current.set(t.key, roundi(v) if current.get(t.key) is int else v)
	current.prepare(self, arena.player_ids().filter(func(id): return not arena.tiles[id - 1].is_dead))
	Texts.dress(current, round_type_name(_last_type))   # the operator's name and rules for this game
	_set_state(State.INTRO)
	arena.narrator.say("round_" + round_type_name(_last_type), "%s. %s" % [current.title, current.rules], "round", {}, true)
	_timer = intro_time / tempo
	screen_wall.set_timer("")
	show_view({"kind": "message"})
	arena.npc.mood("intro")


## Random round type after `after`: personal rounds only with enough players,
## and not the same type twice in a row (when there is a choice). n: the
## round's index, for the fixed order (random_rounds = false).
func _pick_round_type(after: Script, n: int) -> Script:
	return _pick(after, n).type


## {type, chance}: the pick and how likely it was.
func _pick(after: Script, n: int) -> Dictionary:
	if not random_rounds:
		return {"type": round_types[n % round_types.size()], "chance": 1.0}
	var chances := round_chances(after)
	var r := randf()
	var pick: Script = chances.keys().back()
	for t in chances:
		r -= chances[t]
		if r <= 0.0:
			pick = t
			break
	return {"type": pick, "chance": chances[pick]}


## The chance of each round type for the round after `after` - a weighted
## random, steered the way games steer their dice:
##   in / out   per type (settings "Randomizer", the web interface's Spel tab):
##              out = never drawn - planning it (set_planned_round) still plays it:
##              a new game for a chosen audience
##   weight     per type (settings "Randomizer"; 0 = never)
##   no repeat  never the same type twice in a row (when there is a choice;
##              the quiz can: it is the backbone, the other games come in between)
##   drought    (pity / bad-luck protection) every round a type was not
##              played - played or already planned - adds `drought` x its
##              weight: nothing stays away for long
##   director   the players' lives: when they are low, the rounds that can
##              win a life (the personal ones) come more often and the quiz
##              (it only takes lives) less; everyone healthy: more quiz
##              (more pressure). `mercy` = how strongly (0 = off)
## Personal rounds only with enough players. Returns {Script: chance}.
func round_chances(after: Script) -> Dictionary:
	var options := round_types.filter(func(t): return _allowed(t) and not randomizer_off.has(round_type_name(t)))
	if options.is_empty():                       # (everything out, or not allowed: then any allowed type)
		options = round_types.filter(func(t): return _allowed(t))
	if options.is_empty():
		options = round_types.duplicate()
	if options.size() > 1:
		options = options.filter(func(t): return t != after or t.new().can_repeat)
	var seq: Array = Array(_history) + upcoming.map(func(e): return e.type)
	var lives_factor := _director()
	var w := {}
	for t in options:
		var since := seq.size() - 1 - seq.rfind(t) if t in seq else mini(seq.size() + 1, 10)
		var weight: float = round_weights.get(round_type_name(t), 1.0)
		weight *= 1.0 + drought * maxi(since - 1, 0)
		if not t.new().gives_lives:
			weight *= lives_factor
		w[t] = weight
	var total: float = w.values().reduce(func(a, b): return a + b, 0.0)
	for t in w:
		w[t] = w[t] / total if total > 0.0 else 1.0 / w.size()
	return w


## All questions: from the database (or control server), else the JSON file.
func all_questions() -> Array:
	var all: Array = db.questions() if db else []
	if all.is_empty():
		var data = JSON.parse_string(FileAccess.get_file_as_string(QuizRound.QUESTIONS_FILE))
		all = data if data is Array else []
	return all


## The chance of each category for the next question (the categories in `pool`):
## its weight x (1 + category_drought x questions since it was last asked;
## never asked: as long as there have been questions, max 10); a category
## whose questions were all asked is skipped while other ones have new ones
## (repeats only when nothing new is left).
## {category: chance}.
func category_chances(pool: Array) -> Dictionary:
	var w := {}
	var fresh := {}                                 # category -> it still has unasked questions
	for q in pool:
		var c := str(q.get("category", ""))
		if not question_memory.asked.has(str(q.get("id", q.get("question", "")))):
			fresh[c] = true
		if w.has(c):
			continue
		var since: int = question_memory.since.get(c, mini(question_memory.count + 1, 10))
		w[c] = float(category_weights.get(c, 1.0)) * (1.0 + category_drought * mini(since, 10))
	if not fresh.is_empty():
		for c in w:
			if not fresh.has(c):
				w[c] = 0.0                          # every question asked already: not while others have new ones
	var total: float = w.values().reduce(func(a, b): return a + b, 0.0)
	if total <= 0.0:
		return {}                                   # every category weight 0
	for c in w.keys():
		if w[c] <= 0.0:
			w.erase(c)
		else:
			w[c] /= total
	return w


## A question was asked (for the drought protection and no early repeats).
func note_question(category: String, id: String) -> void:
	question_memory.count += 1
	for c in question_memory.since:
		question_memory.since[c] += 1
	question_memory.since[category] = 0
	question_memory.asked[id] = question_memory.count


## The director: x weight of the rounds that cannot win a life, from the
## players' lives (average share of their own full hearts - age): low -> fewer, full -> more.
func _director() -> float:
	var alive: Array = arena.player_ids().filter(func(id): return not arena.tiles[id - 1].is_dead)
	if alive.is_empty() or mercy <= 0.0:
		return 1.0
	var f: float = alive.map(func(id): return float(arena.tiles[id - 1].health) / maxi(arena.tiles[id - 1].max_health, 1)) \
		.reduce(func(a, b): return a + b, 0.0) / alive.size()
	var tension := clampf((0.7 - f) / 0.45, 0.0, 1.0)    # lives running out (full effect at 1/4)
	var ease := clampf((f - 0.8) / 0.2, 0.0, 1.0)        # (almost) all hearts full
	return maxf(0.1, 1.0 - mercy * tension) * (1.0 + mercy * ease)


func _allowed(t: Script) -> bool:
	return _personal_allowed() or t.new().mode != "personal"


func _personal_allowed() -> bool:
	var alive: int = arena.player_ids().filter(func(id): return not arena.tiles[id - 1].is_dead).size()
	return alive >= personal_min_players


## Keep `queue_length` rounds planned: planned (not chosen) rounds that are no
## longer allowed (too few players) are planned again.
func _plan_rounds() -> void:
	var keep := []
	var personal_ok := _personal_allowed()
	for e in upcoming:
		if not random_rounds or e.forced:                         # (fixed order: every type)
			keep.append(e)
		elif _allowed(e.type) and (e.get("personal_ok", true) or not personal_ok) \
				and not randomizer_off.has(round_type_name(e.type)):
			keep.append(e)
		# else: not allowed any more, or only chosen because personal rounds were not
		# allowed then (too few players): pick again, now from every type
	upcoming = keep
	while upcoming.size() < queue_length:
		var after: Script = upcoming.back().type if not upcoming.is_empty() else _last_type
		var pick := _pick(after, _planned)
		upcoming.append({"type": pick.type, "forced": false, "personal_ok": personal_ok, "chance": pick.chance})
		_planned += 1
	while upcoming.size() > queue_length and not upcoming.back().forced:   # (shorter queue setting)
		upcoming.pop_back()


## Operator: play `type_name` (cyclone, quiz, reaction, rhythm, simon, zwarte_piet) as the round in
## slot `slot` of the plan (0 = the next round). "" = random again from there.
func set_planned_round(slot: int, type_name: String, options := {}) -> void:
	_plan_rounds()
	slot = clampi(slot, 0, upcoming.size() - 1)
	if type_name == "":
		upcoming.resize(slot)
	else:
		var t := _round_type(type_name)
		if t == null:
			push_warning("unknown round type %s" % type_name)
			return
		upcoming[slot] = {"type": t, "forced": true, "options": options}
	_plan_rounds()
	_checkpoint()


func clear_planned_rounds() -> void:
	upcoming.clear()
	_plan_rounds()
	_checkpoint()


func set_round_types(types: Array) -> void:
	round_types = types
	upcoming.clear()                     # plan again with the new types
	_planned = 0
	if arena:
		_plan_rounds()


func round_type_name(t: Script) -> String:
	return t.resource_path.get_file().get_basename().trim_suffix("_round")


func _round_type(type_name: String) -> Script:
	for t in ROUND_TYPES:
		if round_type_name(t) == type_name:
			return t
	return null


## Everything the web interface shows of the game (published on MQTT `state`).
func status() -> Dictionary:
	var players := []
	for id in arena.player_ids():
		var t: CyberTile = arena.tiles[id - 1]
		players.append({"tile": id, "name": arena.player_name(id), "lives": maxi(t.health, 0),
			"max_lives": t.max_health, "survived": survived.get(id, 0), "record": record(id),
			"streak": streaks.get(id, 0),
			"points": current.points.get(id, 0) if current and current.points.has(id) else 0,
			"score": scores.get(id, 0), "rank": overall_rank(id),
			"out": t.is_dead, "player_id": arena.player_db_id(id)})
	var pending := []
	for id in range(1, arena.tiles.size() + 1):
		var p: Dictionary = arena.pending_info(id)
		if not p.is_empty():
			pending.append({"tile": id, "name": p.name, "color": "#" + p.color.to_html(false),
				"player_id": p.get("player_id", 0)})
	return {"state": State.keys()[state], "mode": mode_name(), "round": current.title if current else "",
		"round_number": round_number, "game_id": game_id,
		"uitslag": _result_left > 0.0,              # SCOREBOARD: still the round's places (UITSLAG)
		"ranked": current.ranked if current else false,   # the round has points and places (not the quiz)
		"floor_tiles": Retro.FLOOR_TILES, "tile_count": arena.tiles.size(),
		"timer": screen_wall.timer_text(), "players": players, "pending": pending,
		"plan": planned_rounds(), "round_types": _round_types_status(),
		"disabled": range(1, arena.tiles.size() + 1).filter(func(id): return not arena.is_enabled(id)),
		"dying": _dying(),
		"installed": range(1, arena.tiles.size() + 1).filter(func(id): return arena.is_installed(id))}


## The tiles in an extermination and when they come free: [{tile, free_in}]
## (whole seconds; -1: the robot has not fired yet).
func _dying() -> Array:
	var out := []
	for id in arena.player_ids():
		var f: float = arena.free_in(id)
		if f != 0.0:
			out.append({"tile": id, "free_in": -1 if f < 0.0 else ceili(f)})
	return out


## The plan for the web interface: [{type, title, forced}].
## Every round type for the web interface: in the randomizer or not, its
## weight, its chance now (for a random round after the planned ones).
func _round_types_status() -> Array:
	var after: Script = upcoming.back().type if not upcoming.is_empty() else _last_type
	var chances := round_chances(after) if random_rounds else {}
	return ROUND_TYPES.map(func(t): return {"type": round_type_name(t), "title": t.new().title,
		"random": not randomizer_off.has(round_type_name(t)), "weight": round_weights.get(round_type_name(t), 1.0),
		"allowed": _allowed(t), "min_players": personal_min_players if t.new().mode == "personal" else 0,
		"chance": snappedf(chances.get(t, 0.0), 0.001)})


func planned_rounds() -> Array:
	return upcoming.map(func(e): return {"type": round_type_name(e.type), "title": e.type.new().title,
		"forced": e.forced, "options": e.get("options", {}), "chance": e.get("chance", 1.0)})


## Starting lives for the player on a tile, from their age (see lives_by_age).
func lives_for(tile_id: int) -> int:
	var age: int = arena.player_age(tile_id)
	if age <= 0 or lives_by_age.is_empty():
		return lives
	var ages := lives_by_age.keys()
	ages.sort()
	for max_age in ages:
		if age <= max_age:
			return lives_by_age[max_age]
	return lives_by_age[ages[-1]]


func _begin_round() -> void:
	var ids: Array[int] = []
	ids.assign(arena.player_ids())
	for id in ids:
		if not scores.has(id) or not _started.has(id):  # activated since the last round
			scores[id] = scores.get(id, 0)
			var t: CyberTile = arena.tiles[id - 1]
			arena.rt(t).revive(lives_for(id))
			_started[id] = true
	current.begin(self, ids)
	arena.cue(&"round_start", 0, {"round": round_type_name(current.get_script())})
	log_event("%s BEGINT" % current.title.to_upper(), Retro.TEAL)
	_set_state(State.PLAYING)
	arena.npc.mood("playing")
	if current.mode == "personal":
		show_view({"kind": "players", "overlay": true, "look_down": current.on_tile})
	else:
		screen_wall.set_timer("")
		show_view({"kind": "round"})


## The end of a round. Lives only change here, and only on the scoreboard:
##   (rounds with places: first the UITSLAG board, result_time: the places
##   1, 2, 3 ... and the life each player will gain / lose)
##   scoreboard with the lives as they were -> after lives_delay the rows show
##   the change (+1 / -1 / exterminated) -> the robot gives / takes the lives:
##   whoever reaches 0 is exterminated (the robot turns and fires, the tile's
##   death animation, the death clip on their screen; several: all in one
##   go, the robot turning from one to the next) -> scoreboard_time more, then
##   the next round. Nothing waits for the animations: they run on top (into
##   the next round; that player's view stays on the clip).
func _end_round() -> void:
	current.finish()
	var changes := _life_plan(current.life_changes())
	var doomed := changes.keys().filter(func(id): return arena.tiles[id - 1].health + changes[id] <= 0)
	arena.aim_at_doomed(doomed)                  # the robot turns to the first one already
	_lives_shown = false
	_score_seq += 1
	var seq := _score_seq
	if db and game_id != 0:
		var type: String = current.get_script().resource_path.get_file().get_basename().trim_suffix("_round")
		var rows := current.points.keys().filter(func(id): return arena.is_playing(id)).map(func(id): return {
			"player_id": arena.player_db_id(id), "tile": id, "points": current.points[id],
			"score": survived.get(id, 0),
			"lives": maxi(arena.tiles[id - 1].health + changes.get(id, 0), 0)})
		db.save_round(game_id, round_number, type, rows)
	var best := _ranking(current.points).filter(func(r): return r.delta > 0)
	best.sort_custom(func(a, b): return a.delta > b.delta)
	log_event("%s VOORBIJ" % current.title.to_upper() + (
		" - BESTE: %s (%+d)" % [best[0].name.to_upper(), best[0].delta] if not best.is_empty() else ""), Retro.AMBER)
	_pending_lives = changes
	_set_state(State.SCOREBOARD)
	_timer = INF                                  # held until the lives are done
	if current.ranked and result_time > 0.0:
		_show_round_ranking(changes)
		_result_left = result_time / tempo
		while _result_left > 0.0:                 # (skip(): on to the scoreboard)
			await get_tree().process_frame
			_result_left -= get_process_delta_time()
		if state != State.SCOREBOARD or seq != _score_seq:
			return
	_show_scores("Scorebord", current.title, current.points, changes)
	await get_tree().create_timer(lives_delay / tempo).timeout
	if state != State.SCOREBOARD or seq != _score_seq:
		return
	_lives_shown = true
	reveal_lives()
	_apply_lives(changes)
	_timer = scoreboard_time / tempo
	if doomed.is_empty():
		_celebrate_leader()                       # (else the robot is busy exterminating)


## End of a round: lives change by at most 1 (max the hearts on the tile), and
## everyone who will still have a life survived the round. {tile_id: -1 / 0 / +1}.
func _life_plan(changes: Dictionary) -> Dictionary:
	var plan := {}
	for id in current.players:
		if not arena.is_playing(id) or arena.tiles[id - 1].is_dead:
			continue
		var health: int = arena.tiles[id - 1].health
		var d: int = clampi(changes.get(id, 0), -1, 1)
		if d > 0 and health >= CyberTile.HEART_COUNT:
			d = 0
		plan[id] = d
		if health + d > 0:
			survived[id] = survived.get(id, 0) + 1
	return plan


## The lives change (on the scoreboard): +1 a green flash, -1 the robot fires
## (at 0: the extermination).
func _apply_lives(plan: Dictionary) -> void:
	for id in plan:                               # (what a checkpoint keeps: the animations take a while)
		if arena.is_playing(id) and not arena.tiles[id - 1].is_dead:
			_target_lives[id] = clampi(arena.lives_after_hits(id) + plan[id], 0, CyberTile.HEART_COUNT)
	_pending_lives = {}
	_checkpoint()
	var losers := []
	var doomed := []
	for id in plan:
		if not arena.is_playing(id) or arena.tiles[id - 1].is_dead:
			continue
		if plan[id] > 0:
			arena.give_life(id)
		elif plan[id] < 0:
			if arena.tiles[id - 1].health <= 1:
				doomed.append(id)
			else:
				losers.append(id)
	arena.exterminate(doomed)                    # all at once, the robot from one to the next
	if not losers.is_empty():
		arena.robot_attack(losers)
	for id in plan:
		screen_wall.update_player(id)


## End of the game (the last player left, or stop_game): whoever is still in
## gets their result with a rank, then everyone leaves.
func _finish_game() -> void:
	var rows := _ranking({})
	for i in rows.size():
		_save_result(rows[i].tile, i + 1)
	if db and game_id != 0:
		db.end_game(game_id)
	game_id = 0
	for id in arena.player_ids():
		arena.leave(id)
	_enter_lobby()


func _enter_lobby() -> void:
	current = null
	_set_state(State.LOBBY)
	screen_wall.set_timer("")
	show_view({"kind": "players"})
	arena.npc.mood("lobby")
	_plan_rounds()                       # the web interface shows the coming rounds already


# ---------------------------------------------------------------- events

## Called by the arena when someone presses an icon on a tile with a player.
func on_button(tile_id: int, button: StringName) -> void:
	if mode != Mode.OPEN:
		return                           # paused / closed: presses don't count
	if state == State.PLAYING and current and tile_id in current.players:
		if not arena.tiles[tile_id - 1].is_dead:
			current.button(tile_id, button)


## Playing in the current round (not: joined during it - they wait for the
## scoreboard, where new players come in).
func in_round(tile_id: int) -> bool:
	return current != null and tile_id in current.players


func _waiting_overlay() -> Control:
	var line := StatusLine.new()
	line.source = func(): return "WACHT OP DE VOLGENDE RONDE"
	return line


## Called by the arena when a tile reports a result of its own logic.
func on_result(tile_id: int, data: Dictionary) -> void:
	if state == State.PLAYING and current and tile_id in current.players:
		if not arena.tiles[tile_id - 1].is_dead:
			current.result(tile_id, data)


## Called by the arena after a join or leave.
func on_players_changed() -> void:
	_plan_rounds()                       # e.g. fewer players: no planned personal rounds
	match state:
		State.LOBBY:
			if mode == Mode.OPEN and auto_start_delay > 0.0 and not arena.player_ids().is_empty() and _lobby_timer < 0.0:
				_lobby_timer = auto_start_delay
			if arena.player_ids().is_empty():
				_lobby_timer = -1.0
				screen_wall.set_timer("")
			screen_wall.refresh_all()
		State.PLAYING:
			if current and current.mode == "personal":
				screen_wall.refresh_all()
		_:
			pass
	for id in arena.player_ids():
		if not scores.has(id):
			scores[id] = 0  # activated mid-game: starts at 0 and plays from the next round
			survived[id] = 0
	for id in _started.keys():
		if not arena.is_playing(id):  # left the game: forget lives and counters
			_started.erase(id)
			scores.erase(id)
			survived.erase(id)
			streaks.erase(id)
	_checkpoint()


## Adds points (the total never goes below 0); returns the change actually applied.
## Operator: change the operating mode (see Mode).
func set_mode(m: Mode) -> void:
	if m == mode:
		return
	var was := mode
	mode = m
	match m:
		Mode.SETUP, Mode.CLOSED:
			if state != State.LOBBY or not arena.player_ids().is_empty():
				stop_game()              # everyone out, results saved
			for id in range(1, arena.tiles.size() + 1):
				if arena.is_pending(id):
					arena.leave(id)      # cancel invites
			_lobby_timer = -1.0
			screen_wall.set_timer("")
		Mode.PAUSED:
			_tiles_paused(true)
		Mode.OPEN:
			if was == Mode.PAUSED:
				_tiles_paused(false)
	for t in arena.tiles:                # setup: every tile's hearts show its number (binary)
		t.show_number = m == Mode.SETUP
	log_event({Mode.SETUP: "SETUP", Mode.CLOSED: "SPEL GESLOTEN", Mode.OPEN: "SPEL OPEN",
		Mode.PAUSED: "PAUZE"}[m], Retro.AMBER)
	screen_wall.refresh_all()
	mode_changed.emit(m)
	on_players_changed()


func mode_name() -> String:
	return Mode.keys()[mode].to_lower()


## Players can register and join only while the game is open.
func accepting_players() -> bool:
	return mode == Mode.OPEN


func _tiles_paused(on: bool) -> void:
	if current and current.on_tile:
		for id in current.players:
			arena.send_to_tile(id, {"pause": on})


## May this player lose a life now? At most 1 per round (outside a game: always).
func take_life(tile_id: int) -> bool:
	if state == State.LOBBY:
		return true
	if _life_lost.get(tile_id, -1) == round_number:
		return false
	_life_lost[tile_id] = round_number
	return true


## A player left (or was exterminated): no longer part of the current round.
## During a game their result goes to the database (exterminated: no rank).
func on_player_left(tile_id: int) -> void:
	if state != State.LOBBY:
		_save_result(tile_id, 0)
	if current:
		current.players.erase(tile_id)
	_life_lost.erase(tile_id)


func _load_records() -> void:
	_records.clear()
	if db:
		for r in db.leaderboard():
			_records[int(r.player_id)] = {"name": r.name, "best": int(r.best), "plays": int(r.plays)}


## The overall ranking, live: every player's record (most rounds survived), with
## the players in the game right now counted with this play when that is more.
## [{player_id, name, best, plays, tile}] best first (tile 0 = not playing now).
func overall_ranking() -> Array:
	if arena == null:                      # screens are built before the game is set up
		return []
	var rows := {}
	for pid in _records:
		var r: Dictionary = _records[pid]
		rows[pid] = {"player_id": pid, "name": r.name, "best": r.best, "plays": r.plays, "tile": 0}
	for id in arena.player_ids():
		var pid: int = arena.player_db_id(id)
		if pid <= 0:
			continue                       # joined without the app: not ranked
		var row: Dictionary = rows.get(pid, {"player_id": pid, "name": arena.player_name(id), "best": 0, "plays": 0})
		row.best = maxi(row.best, survived.get(id, 0))
		row.tile = id
		rows[pid] = row
	var out := rows.values()
	out.sort_custom(func(a, b): return a.best > b.best)
	return out


## Overall place of the player on this tile (equal records share it); 0 = not ranked.
func overall_rank(tile_id: int) -> int:
	if arena == null:
		return 0
	var pid: int = arena.player_db_id(tile_id)
	if pid <= 0:
		return 0
	var ranking := overall_ranking()
	var mine := ranking.filter(func(r): return r.player_id == pid)
	if mine.is_empty():
		return 0
	return 1 + ranking.filter(func(r): return r.best > mine[0].best).size()


## The player's record: most rounds survived (this play included).
func record(tile_id: int) -> int:
	var pid: int = arena.player_db_id(tile_id)
	return maxi(_records.get(pid, {}).get("best", 0), survived.get(tile_id, 0))


## rank 0 = no rank (exterminated or left during the game).
func _save_result(tile_id: int, rank: int) -> void:
	if db == null or game_id == 0 or _result_saved.has(tile_id) or not arena.is_playing(tile_id):
		return
	_result_saved[tile_id] = true
	var tile: CyberTile = arena.tiles[tile_id - 1]
	db.save_result(game_id, {"player_id": arena.player_db_id(tile_id), "tile": tile_id,
		"name": arena.player_name(tile_id), "score": survived.get(tile_id, 0), "lives": maxi(tile.health, 0),
		"exterminated": tile.is_dead, "rank": rank if rank > 0 else null})
	_load_records()


func log_event(text: String, color := Retro.CREAM) -> void:
	game_event.emit(text, color)


func add_score(tile_id: int, n: int) -> int:
	var before: int = scores.get(tile_id, 0)
	scores[tile_id] = maxi(0, before + n)
	screen_wall.update_player(tile_id)
	return scores[tile_id] - before


# ---------------------------------------------------------------- helpers

func _set_state(s: State) -> void:
	state = s
	state_changed.emit(s)
	_checkpoint()


func _alive_players() -> Array:
	return current.players.filter(func(id): return arena.is_playing(id) and not arena.tiles[id - 1].is_dead)


## The players in the game, best first: most rounds survived, then most lives,
## then most points. [{name, tile, survived, lives, score, delta (this round's
## points), out, record, rank}]
## changes: this round's lives change {tile_id: -1 / 0 / +1} - "lives" is the
## number after it, "lives_before" before; "out" = exterminated (after it).
func _ranking(round_points: Dictionary, changes := {}) -> Array:
	var rows := []
	for id in scores:
		if not arena.is_playing(id):
			continue
		var before: int = arena.lives_after_hits(id)
		var after: int = maxi(before + int(changes.get(id, 0)), 0)
		rows.append({"name": arena.player_name(id), "tile": id, "survived": survived.get(id, 0),
			"lives": after, "lives_before": before, "change": changes.get(id, 0), "score": scores[id],
			"delta": round_points.get(id, 0), "out": arena.tiles[id - 1].is_dead or after == 0,
			"was_out": arena.tiles[id - 1].is_dead, "record": record(id), "rank": overall_rank(id),
			"new": state == State.SCOREBOARD and current != null and id not in current.players})
	rows.sort_custom(func(a, b):
		if a.survived != b.survived:
			return a.survived > b.survived
		if a.lives != b.lives:
			return a.lives > b.lives
		return a.score > b.score)
	return rows


## The UITSLAG board: this round's places (shared when equal), what decided
## them (points / level / ...) and the life each player will gain or lose.
func _show_round_ranking(changes: Dictionary) -> void:
	var places := current.places()
	var rows := []
	for id in places:
		var d: int = changes.get(id, 0)
		rows.append({"name": arena.player_name(id), "tile": id, "place": places[id],
			"score": current.progress(id), "change": d, "doomed": arena.tiles[id - 1].health + d <= 0})
	rows.sort_custom(func(a, b): return a.place < b.place if a.place != b.place else a.tile < b.tile)
	var title := current.title
	var label := current.progress_label
	screen_wall.set_timer("")
	show_view({"kind": "ranking", "title": title, "label": label, "rows": rows})
	ranking_shown.emit(title, label, rows)
	for r in rows:                                    # each player: their own place (accessible page)
		var change := " Je krijgt er een leven bij." if r.change > 0 else (" Je verliest een leven." if r.change < 0 else "")
		arena.narrator.say_to(r.tile, "place", "Je bent %de met %s %s.%s" % [r.place, str(r.score), label.to_lower(), change])


func _show_scores(title: String, subtitle: String, round_points: Dictionary, changes := {}) -> void:
	var rows := _ranking(round_points, changes)
	screen_wall.set_timer("")
	show_view({"kind": "scores", "title": title, "subtitle": subtitle, "rows": rows})
	scores_shown.emit(title, subtitle, rows)
	arena.cue(&"scoreboard")


## Robot turns to the leader and lights that side gold.
func _celebrate_leader() -> void:
	var rows := _ranking({})
	if rows.is_empty():
		return
	arena.npc.celebrate(int(rows[0].tile))


# ---------------------------------------------------------------- settings

## Every setting with its range, default and current value, per group ("game"
## and each round type) - for the web interface:
## [{group, title, items: [{key, label, min, max, step, unit, default, value}]}].
func settings_schema() -> Array:
	var groups := [{"group": "game", "title": "Spel", "items": GAME_TUNABLES.map(func(t): return t.merged(
		{"default": _game_defaults.get(t.key), "value": _get_game_setting(t.key)}))}]
	for type in ROUND_TYPES:
		var r: GameRound = type.new()
		var own: Dictionary = settings.get(round_type_name(type), {})
		groups.append({"group": round_type_name(type), "title": r.title, "items": r.tunables().map(func(t):
			return t.merged({"default": r.get(t.key), "value": own.get(t.key, r.get(t.key))}))})
	groups.append({"group": "randomizer", "title": "Randomizer", "items": _randomizer_tunables().map(func(t):
		return t.merged({"default": _game_defaults.get(t.key), "value": _get_game_setting(t.key)}))})
	groups.append({"group": "questions", "title": "Vragen", "items": _question_tunables().map(func(t):
		return t.merged({"default": 1.0 if t.key.begins_with("cat:") else _game_defaults.get(t.key),
			"value": _get_game_setting(t.key)}))})
	groups.append({"group": "sound", "title": "Geluid", "items": arena.sound.tunables().map(func(t): return t.merged(
		{"default": _sound_defaults.get(t.key), "value": arena.sound.get(t.key)}))})
	groups.append({"group": "light", "title": "Licht", "items": arena.lights.tunables().map(func(t): return t.merged(
		{"default": _light_defaults.get(t.key), "value": arena.lights.get(t.key)}))})
	groups.append({"group": "voice", "title": "Voorlezen", "items": arena.narrator.tunables().map(func(t): return t.merged(
		{"default": _voice_defaults.get(t.key), "value": arena.narrator.get(t.key)}))})
	return groups


## The operator's settings (all groups at once; missing keys: the default).
## The game ones apply at once, the round ones from the next round.
func apply_settings(values: Dictionary) -> void:
	var clean := {}
	for g in settings_schema():
		var given: Dictionary = values.get(g.group, {}) if values.get(g.group) is Dictionary else {}
		var out := {}
		for t in g.items:
			if given.has(t.key) and (given[t.key] is float or given[t.key] is int):
				var v := clampf(float(given[t.key]), t.min, t.max)
				out[t.key] = roundi(v) if t.default is int else v
		clean[g.group] = out
	settings = clean
	for t in GAME_TUNABLES:
		_set_game_setting(t.key, clean.game.get(t.key, _game_defaults[t.key]))
	for t in _randomizer_tunables():
		_set_game_setting(t.key, clean.randomizer.get(t.key, _game_defaults[t.key]))
	category_weights.clear()
	for t in _question_tunables():
		_set_game_setting(t.key, clean.questions.get(t.key, 1.0 if t.key.begins_with("cat:") else _game_defaults[t.key]))
	for t in arena.sound.tunables():
		arena.sound.set(t.key, clean.sound.get(t.key, _sound_defaults[t.key]))
	for t in arena.lights.tunables():
		arena.lights.set(t.key, clean.light.get(t.key, _light_defaults[t.key]))
	for t in arena.narrator.tunables():
		arena.narrator.set(t.key, clean.voice.get(t.key, _voice_defaults[t.key]))
	arena.lights.refresh()
	_plan_rounds()
	settings_changed.emit()


func _randomizer_tunables() -> Array:
	var items := ROUND_TYPES.map(func(t): return GameRound.setting(
		"use_" + round_type_name(t), "In de randomizer: " + t.new().title + " (1 aan, 0 uit)", 0, 1, 1))
	items.append_array(ROUND_TYPES.map(func(t): return GameRound.setting(
		"weight_" + round_type_name(t), "Gewicht " + t.new().title, 0, 10, 0.5)))
	items.append(GameRound.setting("drought", "Extra kans per ronde niet gespeeld (x gewicht)", 0, 3, 0.1))
	items.append(GameRound.setting("mercy", "Sturing door levens (0 = uit)", 0, 2, 0.1))
	return items


## The categories of the questions there are now (database / JSON).
func _question_tunables() -> Array:
	var items := [GameRound.setting("category_drought", "Extra kans per vraag categorie niet gevraagd (x gewicht)", 0, 3, 0.1)]
	var cats := {}
	for q in all_questions():
		cats[str(q.get("category", ""))] = true
	var names := cats.keys()
	names.sort()
	for c in names:
		items.append(GameRound.setting("cat:" + c, "Gewicht " + (c if c != "" else "(geen categorie)"), 0, 10, 0.5))
	return items


func _get_game_setting(key: String):
	if key.begins_with("cat:"):
		return float(category_weights.get(key.trim_prefix("cat:"), 1.0))
	if key.begins_with("weight_"):
		return round_weights.get(key.trim_prefix("weight_"), 1.0)
	if key.begins_with("use_"):
		return 0 if randomizer_off.has(key.trim_prefix("use_")) else 1
	if key.begins_with("lives_age_"):
		return lives_by_age.get(int(key.trim_prefix("lives_age_")), lives)
	if key in ["clip_wait", "clip_time"]:
		return arena.get(key)
	return get(key)


func _set_game_setting(key: String, value) -> void:
	if key.begins_with("weight_"):
		round_weights[key.trim_prefix("weight_")] = float(value)
	elif key.begins_with("use_"):
		if int(value) == 0:
			randomizer_off[key.trim_prefix("use_")] = true
		else:
			randomizer_off.erase(key.trim_prefix("use_"))
	elif key.begins_with("cat:"):
		category_weights[key.trim_prefix("cat:")] = float(value)
	elif key.begins_with("lives_age_"):
		lives_by_age[int(key.trim_prefix("lives_age_"))] = int(value)
	elif key in ["clip_wait", "clip_time"]:
		arena.set(key, float(value))
	elif get(key) is int:
		set(key, int(value))
	else:
		set(key, float(value))
