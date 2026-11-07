class_name CycloneRound
extends GameRound
## Personal round: a green light runs around the player's own tile. Press any
## icon at the exact moment it is on the red LED. The yellow bands next to it
## also count, but every success they get narrower (and the light faster);
## a miss starts again at the first level - until the time runs out.
## Red = 3 points + the level, yellow = 1 point, next to it = -2 points (settings).
## Places by the highest level reached (shared when equal): the 1st places
## gain a life, the last places lose one.
##
## The tile runs it (see TileFirmware): it judges the press to the exact LED,
## so network delay doesn't matter. Levels and red positions are generated
## and uploaded during the intro; every tile gets the same program.

const LEVELS := [            # yellow LEDs on each side of the red one, light speed (LEDs/s)
	{"yellow": 4, "speed": 14}, {"yellow": 3, "speed": 16}, {"yellow": 2, "speed": 18},
	{"yellow": 2, "speed": 21}, {"yellow": 1, "speed": 23}, {"yellow": 1, "speed": 26},
	{"yellow": 0, "speed": 28}, {"yellow": 0, "speed": 32},
]
const RESULT_MS := 900


var points_red := 3           # + the level
var points_yellow := 1
var points_miss := -2
var light_speed := 1.0        # x the speeds in LEVELS
var program := {}
var state := {}              # tile_id -> {level, yellow, best, last}
var _sent := {}
var _last_n := {}


func _init() -> void:
	title = "Cyclone"
	progress_label = "LEVEL"
	mode = "personal"
	on_tile = true
	duration = 40.0
	rules = "Een groen lampje draait rondjes op jouw tegel.\nDruk op een knop op het moment dat het op het RODE lampje staat.\nGeel mag ook, maar na elke treffer worden de gele stroken kleiner!\nErnaast? Dan begin je opnieuw bij het eerste niveau.\nNa de ronde: hoogste niveau +1 leven, laagste niveau -1 leven."


func tunables() -> Array:
	return super() + [
		setting("light_speed", "Snelheid lichtje (x)", 0.3, 3.0, 0.1),
		setting("points_red", "Punten rood (+ niveau)", 0, 20, 1),
		setting("points_yellow", "Punten geel", 0, 20, 1),
		setting("points_miss", "Punten mis", -20, 0, 1),
	]


func prepare(game_manager: GameManager, tile_ids: Array) -> void:
	game = game_manager
	program = make_program()
	for id in tile_ids:
		_upload(id)


func make_program() -> Dictionary:
	var targets := []
	var last := -100
	for i in 40:
		var led := randi_range(0, CyberTile.LED_COUNT - 1)
		while absi(led - last) < 8:          # the red LED really moves every turn
			led = randi_range(0, CyberTile.LED_COUNT - 1)
		last = led
		targets.append({"led": led, "dir": 1 if i % 3 != 2 else -1})
	return {"game": "cyclone", "id": "cyclone-%d-%d" % [Time.get_unix_time_from_system(), randi() % 10000],
		"length": roundi(duration * 1000.0), "targets": targets,
		"levels": LEVELS.map(func(l): return {"yellow": l.yellow, "speed": l.speed * light_speed}),
		"result_ms": RESULT_MS}


func _upload(id: int) -> void:
	if not _sent.has(id):
		game.arena.send_to_tile(id, {"program": program})
		_sent[id] = true


func _start() -> void:
	if program.is_empty():
		program = make_program()
	for id in players:
		state[id] = {"level": 0, "yellow": LEVELS[0].yellow, "best": 0, "last": ""}
		_last_n[id] = 0
		_upload(id)
	for id in players:
		if not tile(id).is_dead:
			game.arena.send_to_tile(id, {"start": program.id})


func result(id: int, r: Dictionary) -> void:
	if r.get("program") != program.id or int(r.get("n", 0)) <= _last_n[id] or r.get("done", false):
		return
	_last_n[id] = int(r.n)
	var st: Dictionary = state[id]
	var level := int(r.level)
	var pts := points_miss
	var col := Retro.BAD
	match r.outcome:
		"red":
			pts = points_red + level
			col = Retro.GOOD
		"yellow":
			pts = points_yellow
			col = Retro.AMBER
	add_points(id, pts)
	if r.outcome != "miss":
		st.level = mini(level + 1, LEVELS.size() - 1)
		st.best = maxi(st.best, st.level)
	else:
		st.level = 0                     # a miss: back to the first level
	st.yellow = LEVELS[st.level].yellow
	st.last = {"red": "ROOD!", "yellow": "GEEL"}.get(r.outcome, "ERNAAST")
	game.screen_wall.popup(id, "%+d" % pts, col)
	var arena := game.arena
	if r.outcome == "miss":
		arena.npc.feedback(id, Color.RED, 0.0, false)
	else:
		arena.npc.feedback(id, col, 0.25)


func finish() -> void:
	for id in players:
		game.arena.send_to_tile(id, {"stop": true})


## Places: the highest level reached.
func progress(id: int) -> int:
	return state[id].best


func replica_keys() -> Array:              # (what its overlay reads: Replica)
	return ["state"]


func make_player_overlay(id: int) -> Control:
	var line := StatusLine.new()
	line.source = func(): return "NIVEAU %d" % (state.get(id, {}).get("level", 0) + 1)
	return line
