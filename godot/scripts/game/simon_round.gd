class_name SimonRound
extends GameRound
## Personal round, a variation on Simon says: the tile shows a sequence of
## icons (each in its own colour), the player repeats it. Every level the
## sequence is one step longer and shown faster. A mistake (or waiting too
## long) starts again at the shortest sequence - until the time runs out.
## Places by the longest sequence repeated (shared when equal): the 1st places
## gain a life, the last places lose one.
##
## Like the reaction round the tile runs the game itself (see TileFirmware):
## the sequence is generated and uploaded during the intro, all tiles get the
## same one and start together; every player plays at their own pace.

var max_level := 20              # sequence length = the longest possible level
var start_level := 3
var show_on := 700               # ms a step is shown at the start ...
var speedup := 0.93              # ... times this every level ...
var min_on := 300                # ... but never shorter
var show_off := 300
var input_ms := 4000
var pause_ms := 1200
var points_per_level := 1        # a sequence of n steps right: n x this

var program := {}
var state := {}                  # tile_id -> {phase, level, index, fails, best, reason, text}
var _sent := {}
var _last_n := {}                # tile_id -> last result counter seen


func _init() -> void:
	title = "Simon zegt"
	progress_label = "REEKS"
	mode = "personal"
	on_tile = true
	duration = 90.0
	rules = "Je tegel toont een reeks iconen: onthoud ze en druk ze in dezelfde volgorde.\nElke keer komt er een icoon bij. Fout of te traag? Dan begin je opnieuw bij het begin.\nNa de ronde: langste reeks +1 leven, kortste -1 leven."


func tunables() -> Array:
	return super() + [
		setting("start_level", "Start reekslengte", 1, 10, 1),
		setting("show_on", "Toontijd per stap", 100, 2000, 50, "ms"),
		setting("speedup", "Sneller per niveau (x)", 0.5, 1.0, 0.01),
		setting("min_on", "Kortste toontijd", 100, 1000, 50, "ms"),
		setting("input_ms", "Tijd om te herhalen", 1000, 15000, 500, "ms"),
		setting("points_per_level", "Punten per stap", 0, 20, 1),
	]


func prepare(game_manager: GameManager, tile_ids: Array) -> void:
	game = game_manager
	program = make_program()
	for id in tile_ids:
		_upload(id)


func make_program() -> Dictionary:
	var seq := []
	for i in max_level:
		var b: StringName = CyberTile.BUTTONS.pick_random()
		while i >= 2 and seq[i - 1].button == str(b) and seq[i - 2].button == str(b):
			b = CyberTile.BUTTONS.pick_random()     # never 3 the same in a row
		var c: Color = CyberTile.BUTTON_COLORS[b]         # the colour stays with its location
		seq.append({"button": str(b), "color": "#" + c.to_html(false)})
	return {"game": "simon", "id": "simon-%d-%d" % [Time.get_unix_time_from_system(), randi() % 10000],
		"length": roundi(duration * 1000.0), "sequence": seq, "start_level": start_level,
		"show_on": show_on, "show_off": show_off, "speedup": speedup,
		"min_on": min_on, "input_ms": input_ms, "pause_ms": pause_ms}


func _upload(id: int) -> void:
	if not _sent.has(id):
		game.arena.send_to_tile(id, {"program": program})
		_sent[id] = true


func _start() -> void:
	if program.is_empty():
		program = make_program()
	for id in players:
		state[id] = {"phase": "pause", "level": start_level, "index": 0, "fails": 0,
			"best": 0, "reason": "", "text": "KLAAR..."}
		_last_n[id] = 0
		_upload(id)
	for id in players:
		if tile(id).is_dead:
			state[id].phase = "done"
		else:
			game.arena.send_to_tile(id, {"start": program.id})


## Everyone done (whole sequence repeated) ends the round early.
func is_finished() -> bool:
	return time_left <= 0.0 or players.all(func(id): return state[id].phase == "done")


func result(id: int, r: Dictionary) -> void:
	if r.get("program") != program.id or int(r.get("n", 0)) <= _last_n[id]:
		return
	_last_n[id] = int(r.n)
	var st: Dictionary = state[id]
	if r.get("done", false):
		st.phase = "done"
		st.reason = r.get("reason", "")
		st.best = maxi(st.best, int(r.get("best", 0)))
		st.text = {"complete": "ALLES GOED!", "time": "TIJD OP"}.get(st.reason, "KLAAR")
		return
	var level := int(r.level)
	st.level = level
	match r.outcome:
		"watch":
			st.phase = "watch"
			st.index = 0
			st.text = "KIJK GOED"
		"repeat":
			st.phase = "repeat"
			st.index = 0
			st.text = "HERHAAL"
		"press":
			st.index = int(r.index) + 1
			var c := Color(program.sequence[int(r.index)].color)
			game.arena.send_packet(id, c)
		"ok":
			st.phase = "pause"
			st.best = maxi(st.best, level)
			add_points(id, level * points_per_level)
			st.text = "+%d  REEKS %d" % [level * points_per_level, level]
			game.screen_wall.popup(id, "+%d" % (level * points_per_level), Retro.GOOD)
			var arena := game.arena
			arena.npc.feedback(id, Retro.GOOD, 0.3)
		"fail":                            # back to the shortest sequence
			st.phase = "pause"
			st.fails += 1
			st.level = int(r.get("restart", start_level))
			st.text = "TE TRAAG!" if str(r.button) == "" else "FOUT!"
			game.screen_wall.popup(id, st.text, Retro.BAD)
			game.arena.send_packet(id, Color.RED, Callable(), false)


func finish() -> void:
	for id in players:
		game.arena.send_to_tile(id, {"stop": true})


## Places: the longest sequence repeated correctly.
func progress(id: int) -> int:
	return state[id].best


func replica_keys() -> Array:              # (what its overlay reads: Replica)
	return ["state"]


func make_player_overlay(id: int) -> Control:
	var line := StatusLine.new()
	line.source = func():
		var st: Dictionary = state.get(id, {})
		if st.is_empty():
			return ""
		if st.phase == "done":
			return st.text
		return "REEKS %d   BESTE %d" % [st.level, st.best]
	return line
