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
## ends it at once). Exterminated is the end for a player: no new round for
## them - and when everyone is exterminated, no new round at all (the
## scoreboard waits for their tiles to come free, then the lobby). In the
## database one game = from start to the lobby; every player's result is
## saved when they leave.
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
## Every quiz round is one question. Questions come from the database, which
## also keeps the scores (GameDb).
## A player loses at most 1 life per round (take_life). At 0 lives they are
## exterminated: the tile blinks red, the robot's death animation plays and
## the tile becomes free again (the player leaves the game).
##
## This file is the flow of the game. Its helpers:
##   picker     RoundPicker     which round comes next: the plan, the randomizer
##   questions  QuestionPicker  the quiz's questions and which category is next
##   standings  Standings       the ranking of the event
##   settings   GameSettings    what the operator can change
##   recovery   Recovery        back after a crash / power cut
##   views      GameViews       what the screens show
##   modes      ModeSwitch      the operating mode, the robot's boot / shutdown show

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
@export var streak_bonus := 10         # this many right in a row: +1 life
@export var db_path := "res://data/cybercircle.db"   # standalone: the SQLite file itself
@export var control_url := ""          # installation: the control server owns the database
@export var restore := true            # --no-restore: always a fresh start
@export var restore_max_age := 3600.0  # s: an older checkpoint is a previous day's game

var arena: Arena
var screen_wall: ScreenWall
var picker := RoundPicker.new(self)        # which round comes next: the plan, the randomizer
var questions := QuestionPicker.new(self)  # the quiz's questions and which category is next
var standings := Standings.new(self)       # the ranking of the event (records from the database)
var settings := GameSettings.new(self)     # what the operator can change
var views := GameViews.new(self)           # what the screens show
var modes := ModeSwitch.new(self)          # the operating mode, the robot's shows
var state := State.LOBBY
var mode := Mode.OPEN
var scores := {}                       # tile_id -> total points this play (tie-break)
var survived := {}                     # tile_id -> rounds survived this play (RONDES)
var streaks := {}                      # tile_id -> quiz answers right in a row (OP RIJ)
var current: GameRound
var round_number := 0
var db: DataSource                     # GameDb or ControlApi; null: none (JSON questions, no saving)
var game_id := 0                       # this game's id in the database
var recovery: Recovery                 # crash / power cut: the game comes back where it was

var _timer := 0.0
var _lobby_timer := -1.0
var _result_saved := {}                # tile_id -> true once their result is in the database
var _started := {}                     # tile_id -> true once the player has had lives set
var _life_lost := {}                   # tile_id -> round_number in which they lost a life
var _result_left := 0.0                # s the UITSLAG board still shows
var _score_seq := 0                    # (a skipped scoreboard stops its own sequence)
var _countdown := 0                    # the last second announced (light cue "countdown")
var _current_entry := {}               # the round being played, as it was planned (replayed after a crash)
var _pending_lives := {}               # end of a round: the lives about to change {tile_id: -1/0/+1}
var _target_lives := {}                # ... and once given / taken: what they become (shots still flying)
var _replica_round := 0                # a display node: the master's round it has (instance id there)


# ---------------------------------------------------------------- display nodes (Replica)

## What the display nodes' screens read of the game (ArenaMirror.fields).
func replica_fields() -> Dictionary:
	var r := {}
	if current:
		r = {"id": current.get_instance_id(), "type": RoundPicker.type_name(current.get_script()),
			"init": current.replica_init()}
	return {"g_state": state, "g_mode": mode, "scores": scores, "survived": survived, "streaks": streaks,
		"round_number": round_number, "records": standings.records, "started": _started,
		"tempo": tempo, "round": r, "round_sync": RoundMirror.fields(current) if current else {},
		"lives_shown": views.lives_shown, "view": views.shown}


## A display node: the game's fields from the master.
func apply_replica(f: Dictionary, full: bool) -> void:
	for k in ["scores", "survived", "streaks", "round_number", "tempo"]:
		if f.has(k):
			set(k, f[k])
	if f.has("records"):
		standings.records = f.records
	if f.has("started"):
		_started = f.started
	if f.has("round"):
		var r: Dictionary = f.round
		if (r.is_empty() or _replica_round != int(r.get("id", 0))) and current:
			current.replica_end()
		if r.is_empty():
			current = null
			_replica_round = 0
		elif current == null or _replica_round != int(r.id):
			var t := RoundPicker.type_named(str(r.type))
			current = t.new() if t else null
			_replica_round = int(r.id)
		if current:
			current.game = self
			RoundMirror.apply(current, r.init)
	if f.has("round_sync") and current:
		RoundMirror.apply(current, f.round_sync)
	if f.has("g_mode") and int(f.g_mode) != mode:
		mode = int(f.g_mode) as Mode
		mode_changed.emit(mode)
	if f.has("g_state") and int(f.g_state) != state:
		state = int(f.g_state) as State
		state_changed.emit(state)
	views.apply_replica(f, full)


func setup(arena_node: Arena) -> void:
	arena = arena_node
	screen_wall = arena.screen_wall
	if Replica.client:                   # a display node: no database, no game logic - only the screens
		restore = false
		views.show({"kind": "players"})
		return
	settings.remember_defaults()
	arena.robot.power_moment.connect(modes.on_power_moment)
	if control_url != "":
		_use_control_server(control_url)
	else:
		use_database(db_path)
	standings.load_records()
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
	views.lives_shown = false
	_score_seq += 1
	var seq := _score_seq
	_set_state(State.SCOREBOARD)
	_timer = INF
	log_event("HET SPEL GAAT VERDER (RONDE %d)" % (round_number + 1), Retro.TEAL)
	_show_scores("Scorebord", "Het spel gaat verder", {}, changes)
	await wait(lives_delay / tempo)
	if state != State.SCOREBOARD or seq != _score_seq:
		return
	views.reveal_lives()
	if not changes.is_empty():
		_apply_lives(changes)
	_timer = scoreboard_time / tempo


## The installation: questions, players and scores through the control server.
func _use_control_server(url: String) -> void:
	var api := ControlApi.new()
	api.name = "ControlApi"
	_set_db(api)
	api.open(url)
	api.changed.connect(standings.load_records)


## Standalone: open the SQLite file directly ("" = no database); e.g. a test database.
func use_database(path: String) -> void:
	if path.begins_with("res://") and not OS.has_feature("editor"):
		# an exported build can't write inside itself: use the folder of the program
		path = OS.get_executable_path().get_base_dir().path_join(path.get_file())
	db_path = path
	var file := GameDb.new()
	if path != "" and file.open(path):
		file.name = "GameDb"
		_set_db(file)
	else:
		file.free()
		_set_db(null)


## The data source is a child node (the control server's needs the tree for its requests).
func _set_db(source: DataSource) -> void:
	if db:
		remove_child(db)
		db.queue_free()
	db = source
	if db:
		add_child(db)


func _process(delta: float) -> void:
	if Replica.client:                   # a display node: the round's clocks run on between the master's updates
		if current and mode != Mode.PAUSED:
			current.replica_tick(delta)
		return
	if mode == Mode.PAUSED:
		return                           # frozen: no timers, no rounds
	match state:
		State.LOBBY:
			if modes.close_pending:
				modes.close_now()
				return
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
	if state != State.LOBBY or arena.players.player_ids().is_empty() or mode != Mode.OPEN:
		return
	game_id = db.start_game() if db else 0
	picker.restart()
	_result_saved.clear()
	scores.clear()
	survived.clear()
	streaks.clear()
	_started.clear()
	for id in arena.players.player_ids():
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
	if modes.close_pending:              # closing after this round: now
		modes.close_now()
		return
	if arena.players.player_ids().is_empty():    # the last player is gone: back to the lobby
		_finish_game()
		return
	if arena.players.player_ids().all(func(id): return arena.tiles[id - 1].is_dead):
		_timer = 0.5                     # everyone exterminated: the end - no new round; the scoreboard
		return                           # waits until their tiles are free (death animation, their clip)
	round_number += 1                    # counts rounds (database, 1 life per round)
	var entry := picker.take_next()
	_current_entry = entry
	_target_lives.clear()
	var type_name := RoundPicker.type_name(entry.type)
	current = entry.type.new()
	settings.configure(current, type_name, entry.get("options", {}))   # the operator's, this round's in the plan
	_apply_tempo(current)
	current.prepare(self, arena.players.player_ids().filter(func(id): return not arena.tiles[id - 1].is_dead))
	Texts.dress(current, type_name)                        # the operator's name and rules for this game
	_set_state(State.INTRO)
	arena.narrator.say("round_" + type_name, "%s. %s" % [current.title, current.rules], "round", {}, true)
	_timer = intro_time / tempo
	screen_wall.set_timer("")
	views.show({"kind": "message"})
	arena.npc.mood("intro")


## The tempo: all of a round's times (network delays are not game times).
func _apply_tempo(r: GameRound) -> void:
	for t in r.tunables():
		if t.unit in ["s", "ms"] and not t.key in GameSettings.NETWORK_TIMES:
			var v = r.get(t.key) / tempo
			r.set(t.key, roundi(v) if r.get(t.key) is int else v)


## Everything the web interface shows of the game (published on MQTT `state`).
func status() -> Dictionary:
	var players := []
	for id in arena.players.player_ids():
		var t: CyberTile = arena.tiles[id - 1]
		players.append({"tile": id, "name": arena.players.player_name(id), "lives": maxi(t.health, 0),
			"max_lives": t.max_health, "survived": survived.get(id, 0), "record": standings.record(id),
			"streak": streaks.get(id, 0),
			"points": current.points.get(id, 0) if current and current.points.has(id) else 0,
			"score": scores.get(id, 0), "rank": standings.rank(id),
			"out": t.is_dead, "player_id": arena.players.player_db_id(id)})
	var pending := []
	for id in range(1, arena.tiles.size() + 1):
		var p: Dictionary = arena.players.pending_info(id)
		if not p.is_empty():
			pending.append({"tile": id, "name": p.name, "color": "#" + p.color.to_html(false),
				"player_id": p.get("player_id", 0)})
	return {"state": State.keys()[state], "mode": modes.name(), "round": current.title if current else "",
		"round_number": round_number, "game_id": game_id,
		"closing": modes.close_pending, "power_show": modes.power_show,
		"uitslag": _result_left > 0.0,              # SCOREBOARD: still the round's places (UITSLAG)
		"ranked": current.ranked if current else false,   # the round has points and places (not the quiz)
		"floor_tiles": Retro.FLOOR_TILES, "tile_count": arena.tiles.size(),
		"timer": screen_wall.timer_text(), "players": players, "pending": pending,
		"plan": picker.planned_rounds(), "round_types": picker.types_status(),
		"disabled": range(1, arena.tiles.size() + 1).filter(func(id): return not arena.installation.is_enabled(id)),
		"dying": _dying(),
		"installed": range(1, arena.tiles.size() + 1).filter(func(id): return arena.installation.is_installed(id))}


## The tiles in an extermination and when they come free: [{tile, free_in}]
## (whole seconds; -1: the robot has not fired yet).
func _dying() -> Array:
	var out := []
	for id in arena.players.player_ids():
		var f: float = arena.free_in(id)
		if f != 0.0:
			out.append({"tile": id, "free_in": -1 if f < 0.0 else ceili(f)})
	return out


## Starting lives for the player on a tile, from their age (see lives_by_age).
func lives_for(tile_id: int) -> int:
	var age: int = arena.players.player_age(tile_id)
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
	ids.assign(arena.players.player_ids())
	for id in ids:
		if not scores.has(id) or not _started.has(id):  # activated since the last round
			scores[id] = scores.get(id, 0)
			var t: CyberTile = arena.tiles[id - 1]
			arena.rt(t).revive(lives_for(id))
			_started[id] = true
	current.begin(self, ids)
	arena.cue(&"round_start", 0, {"round": RoundPicker.type_name(current.get_script())})
	log_event("%s BEGINT" % current.title.to_upper(), Retro.TEAL)
	_set_state(State.PLAYING)
	arena.npc.mood("playing")
	if current.mode == "personal":
		views.show({"kind": "players", "overlay": true, "look_down": current.on_tile})
	else:
		screen_wall.set_timer("")
		views.show({"kind": "round"})


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
	views.lives_shown = false
	_score_seq += 1
	var seq := _score_seq
	if db and game_id != 0:
		var type: String = current.get_script().resource_path.get_file().get_basename().trim_suffix("_round")
		var rows := current.points.keys().filter(func(id): return arena.players.is_playing(id)).map(func(id): return {
			"player_id": arena.players.player_db_id(id), "tile": id, "points": current.points[id],
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
			if mode != Mode.PAUSED:
				_result_left -= get_process_delta_time()
		if state != State.SCOREBOARD or seq != _score_seq:
			return
	_show_scores("Scorebord", current.title, current.points, changes)
	await wait(lives_delay / tempo)
	if state != State.SCOREBOARD or seq != _score_seq:
		return
	views.reveal_lives()
	_apply_lives(changes)
	_timer = scoreboard_time / tempo
	if doomed.is_empty():
		_celebrate_leader()                       # (else the robot is busy exterminating)


## End of a round: lives change by at most 1 (max the hearts on the tile), and
## everyone who will still have a life survived the round. {tile_id: -1 / 0 / +1}.
func _life_plan(changes: Dictionary) -> Dictionary:
	var plan := {}
	for id in current.players:
		if not arena.players.is_playing(id) or arena.tiles[id - 1].is_dead:
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
		if arena.players.is_playing(id) and not arena.tiles[id - 1].is_dead:
			_target_lives[id] = clampi(arena.lives_after_hits(id) + plan[id], 0, CyberTile.HEART_COUNT)
	_pending_lives = {}
	_checkpoint()
	var losers := []
	var doomed := []
	for id in plan:
		if not arena.players.is_playing(id) or arena.tiles[id - 1].is_dead:
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
	for id in arena.players.player_ids():
		arena.players.leave(id)
	_enter_lobby()


func _enter_lobby() -> void:
	current = null
	_set_state(State.LOBBY)
	screen_wall.set_timer("")
	views.show({"kind": "players"})
	arena.npc.mood("lobby")
	picker.plan()                        # the web interface shows the coming rounds already


# ---------------------------------------------------------------- events

## Called by the arena when someone presses an icon on a tile with a player
## (down = false: they let go of it - Ritme's hold notes).
func on_button(tile_id: int, button: StringName, down := true) -> void:
	if mode != Mode.OPEN:
		return                           # paused / closed: presses don't count
	if state == State.PLAYING and current and tile_id in current.players:
		if arena.tiles[tile_id - 1].is_dead:
			return
		if down:
			current.button(tile_id, button)
		else:
			current.button_up(tile_id, button)


## Playing in the current round (not: joined during it - they wait for the
## scoreboard, where new players come in).
func in_round(tile_id: int) -> bool:
	return current != null and tile_id in current.players


## Called by the arena when a tile reports a result of its own logic.
func on_result(tile_id: int, data: Dictionary) -> void:
	if state == State.PLAYING and current and tile_id in current.players:
		if not arena.tiles[tile_id - 1].is_dead:
			current.result(tile_id, data)


## Called by the arena after a join or leave.
func on_players_changed() -> void:
	picker.plan()                        # e.g. fewer players: no planned personal rounds
	if modes.power_show == "boot" and views.is_kind("power") and not Replica.client \
			and (not arena.players.player_ids().is_empty() or not arena.players.pending_ids().is_empty()):
		views.show({"kind": "players"})   # someone came in during the boot: their invite (the robot boots on)
	match state:
		State.LOBBY:
			if mode == Mode.OPEN and auto_start_delay > 0.0 and not arena.players.player_ids().is_empty() and _lobby_timer < 0.0:
				_lobby_timer = auto_start_delay
			if arena.players.player_ids().is_empty():
				_lobby_timer = -1.0
				screen_wall.set_timer("")
			screen_wall.refresh_all()
		State.PLAYING:
			if current and current.mode == "personal":
				screen_wall.refresh_all()
		_:
			pass
	for id in arena.players.player_ids():
		if not scores.has(id):
			scores[id] = 0  # activated mid-game: starts at 0 and plays from the next round
			survived[id] = 0
	for id in _started.keys():
		if not arena.players.is_playing(id):  # left the game: forget lives and counters
			_started.erase(id)
			scores.erase(id)
			survived.erase(id)
			streaks.erase(id)
	_checkpoint()


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


## The overview's timer: the screens' timer, else the countdown the screens
## show in their own view (the round intro's START OVER, the quiz's answer time).
func overview_timer() -> String:
	var t: String = screen_wall.timer_text() if screen_wall else ""
	if t != "":
		return t
	if state == State.INTRO and current:
		return "Start over %d" % ceili(maxf(_timer, 0.0))
	if state == State.PLAYING and current:
		var left := current.shared_countdown()
		if left >= 0.0:
			return "%d" % ceili(left)
	return ""


## rank 0 = no rank (exterminated or left during the game).
func _save_result(tile_id: int, rank: int) -> void:
	if db == null or game_id == 0 or _result_saved.has(tile_id) or not arena.players.is_playing(tile_id):
		return
	_result_saved[tile_id] = true
	var tile: CyberTile = arena.tiles[tile_id - 1]
	db.save_result(game_id, {"player_id": arena.players.player_db_id(tile_id), "tile": tile_id,
		"name": arena.players.player_name(tile_id), "score": survived.get(tile_id, 0), "lives": maxi(tile.health, 0),
		"exterminated": tile.is_dead, "rank": rank if rank > 0 else null})
	standings.load_records()


func log_event(text: String, color := Retro.CREAM) -> void:
	game_event.emit(text, color)


## Adds points (the total never goes below 0); returns the change actually applied.
func add_score(tile_id: int, n: int) -> int:
	var before: int = scores.get(tile_id, 0)
	scores[tile_id] = maxi(0, before + n)
	screen_wall.update_player(tile_id)
	return scores[tile_id] - before


# ---------------------------------------------------------------- helpers

## Wait `seconds` of game time: it stands still while the game is paused (a
## SceneTree timer would run on, and the game would go on behind the pause).
func wait(seconds: float) -> void:
	while seconds > 0.0:
		await get_tree().process_frame
		if mode != Mode.PAUSED:
			seconds -= get_process_delta_time()


func _set_state(s: State) -> void:
	state = s
	state_changed.emit(s)
	_checkpoint()


func _alive_players() -> Array:
	return current.players.filter(func(id): return arena.players.is_playing(id) and not arena.tiles[id - 1].is_dead)


## The players in the game, best first: most rounds survived, then most lives,
## then most points. [{name, tile, survived, lives, score, delta (this round's
## points), out, record, rank}]
## changes: this round's lives change {tile_id: -1 / 0 / +1} - "lives" is the
## number after it, "lives_before" before; "out" = exterminated (after it).
func _ranking(round_points: Dictionary, changes := {}) -> Array:
	var rows := []
	var lives_after := {}
	for id in scores:
		if arena.players.is_playing(id):
			lives_after[id] = maxi(arena.lives_after_hits(id) + int(changes.get(id, 0)), 0)
	for id in scores:
		if not arena.players.is_playing(id):
			continue
		var before: int = arena.lives_after_hits(id)
		var after: int = lives_after[id]
		rows.append({"name": arena.players.player_name(id), "tile": id, "survived": survived.get(id, 0),
			"lives": after, "lives_before": before, "change": changes.get(id, 0), "score": scores[id],
			"delta": round_points.get(id, 0), "out": arena.tiles[id - 1].is_dead or after == 0,
			"was_out": arena.tiles[id - 1].is_dead, "record": standings.record(id), "rank": standings.rank(id, lives_after),
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
		rows.append({"name": arena.players.player_name(id), "tile": id, "place": places[id],
			"score": current.progress(id), "change": d, "doomed": arena.tiles[id - 1].health + d <= 0})
	rows.sort_custom(func(a, b): return a.place < b.place if a.place != b.place else a.tile < b.tile)
	var title := current.title
	var label := current.progress_label
	screen_wall.set_timer("")
	views.show({"kind": "ranking", "title": title, "label": label, "rows": rows})
	ranking_shown.emit(title, label, rows)
	arena.sound.play(&"ranking")
	for r in rows:                                    # each player: their own place (accessible page)
		var change := " Je krijgt er een leven bij." if r.change > 0 else (" Je verliest een leven." if r.change < 0 else "")
		arena.narrator.say_to(r.tile, "place", "Je bent %de met %s %s.%s" % [r.place, str(r.score), label.to_lower(), change])


func _show_scores(title: String, subtitle: String, round_points: Dictionary, changes := {}) -> void:
	var rows := _ranking(round_points, changes)
	screen_wall.set_timer("")
	views.show({"kind": "scores", "title": title, "subtitle": subtitle, "rows": rows})
	scores_shown.emit(title, subtitle, rows)
	arena.cue(&"scoreboard")


## Robot turns to the leader and lights that side gold.
func _celebrate_leader() -> void:
	var rows := _ranking({})
	if rows.is_empty():
		return
	arena.npc.celebrate(int(rows[0].tile))
