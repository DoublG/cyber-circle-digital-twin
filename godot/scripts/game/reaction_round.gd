class_name ReactionRound
extends GameRound
## Personal round: a colour lights up on your tile (ring + the icon in that
## colour). Press that icon as fast as possible. RED (the circle) is a trap:
## don't press it - wait until it goes out or press another icon.
## Every success gives you less time for the next one; a mistake (wrong icon,
## red pressed, too late) starts again at the slowest speed.
## Places by the longest run of successes (shared when equal): the 1st places
## gain a life, the last places lose one.
##
## The tiles do the timing themselves (see TileFirmware): the whole program
## is generated and sent during the intro, every tile gets the same program
## (fair), one "start" sets them all off together. The game scores each
## result when it comes in and plays the animation then.

const NOGO_BUTTON := &"Circle"                  # the red icon
const GO_BUTTONS: Array[StringName] = [&"Square", &"Triangle", &"Cross"]

var window_start := 1.4          # s to react at the slowest ...
var window_end := 0.6            # ... and the fastest, after `speed_steps` successes in a row
var speed_steps := 8
var gap := Vector2(0.6, 1.6)     # random pause between steps (s)
var nogo_chance := 0.25
var points_fast := 10            # a hit at once ...
var points_slow := 3             # ... and at the end of the window
var points_wait := 3             # waited on red (no-go)
var points_wrong := -2           # wrong icon
var points_red := -5             # pressed on red

var program := {}
var _sent := {}                  # tile_id -> true once the program is on the tile
var _results := {}               # tile_id -> {step index: outcome}
var stats := {}                  # tile_id -> {hits, best_ms, streak, best_streak}


func _init() -> void:
	title = "Reactie"
	mode = "personal"
	on_tile = true
	duration = 30.0
	rules = "Er licht een kleur op je tegel op: druk zo snel mogelijk op dat icoon.\nROOD is een val: niet drukken! Wacht of druk een ander icoon.\nElke treffer gaat het sneller, een fout en je begint weer traag.\nNa de ronde: langste reeks treffers +1 leven, kortste -1 leven."


## During the intro: generate the program and upload it to the tiles.
func tunables() -> Array:
	return super() + [
		setting("window_start", "Reactietijd begin", 0.3, 5.0, 0.1, "s"),
		setting("window_end", "Reactietijd snelst", 0.2, 3.0, 0.1, "s"),
		setting("speed_steps", "Treffers tot snelst", 1, 30, 1),
		setting("nogo_chance", "Kans op rood (niet drukken)", 0.0, 0.8, 0.05),
		setting("points_fast", "Punten snelste treffer", 0, 50, 1),
		setting("points_slow", "Punten traagste treffer", 0, 50, 1),
		setting("points_wait", "Punten goed gewacht", 0, 50, 1),
		setting("points_wrong", "Punten verkeerd icoon", -20, 0, 1),
		setting("points_red", "Punten gedrukt op rood", -20, 0, 1),
	]


func prepare(game_manager: GameManager, tile_ids: Array) -> void:
	game = game_manager
	program = make_program()
	for id in tile_ids:
		_upload(id)


func make_program() -> Dictionary:
	var steps := []
	var end := duration - 1.5
	var t := 1.5
	var nogo_run := 0
	while true:
		var window := window_start      # room for the slowest window (a tile may be reset)
		if t + window > end:
			break
		var nogo := randf() < nogo_chance and not steps.is_empty() and nogo_run < 2
		nogo_run = nogo_run + 1 if nogo else 0
		var b: StringName = NOGO_BUTTON if nogo else GO_BUTTONS.pick_random()
		steps.append({"at": roundi(t * 1000.0), "button": str(b),
			"color": "#" + CyberTile.BUTTON_COLORS[b].to_html(false), "nogo": nogo})
		t += window + randf_range(gap.x, gap.y)
	var windows := []                # ms per run of successes: 0 in a row, 1, 2, ...
	for i in speed_steps + 1:
		windows.append(roundi(lerpf(window_start, window_end, float(i) / speed_steps) * 1000.0))
	return {"game": "reaction", "id": "reaction-%d-%d" % [Time.get_unix_time_from_system(), randi() % 10000],
		"length": roundi(duration * 1000.0), "windows": windows, "steps": steps}


func _upload(id: int) -> void:
	if not _sent.has(id):
		game.arena.send_to_tile(id, {"program": program})
		_sent[id] = true


func _start() -> void:
	if program.is_empty():
		program = make_program()
	for id in players:
		_results[id] = {}
		stats[id] = {"hits": 0, "best_ms": 0, "streak": 0, "best_streak": 0}
		_upload(id)
	for id in players:  # all tiles start together
		if not tile(id).is_dead:
			game.arena.send_to_tile(id, {"start": program.id})


func result(id: int, r: Dictionary) -> void:
	if r.get("program") != program.id or r.get("done", false) or _results[id].has(int(r.step)):
		return
	var step: Dictionary = program.steps[int(r.step)]
	var outcome: String = r.outcome
	_results[id][int(r.step)] = outcome
	var pts := 0
	var text := ""
	var col := Retro.CREAM
	match outcome:
		"hit":
			pts = points_slow + roundi((points_fast - points_slow) * clampf(1.0 - float(r.ms) / float(r.window), 0.0, 1.0))
			text = "%d MS" % int(r.ms)
			col = Retro.GOOD
			stats[id].hits += 1
			if stats[id].best_ms == 0 or int(r.ms) < stats[id].best_ms:
				stats[id].best_ms = int(r.ms)
		"nogo_ok":
			pts = points_wait
			text = "GOED GEWACHT"
			col = Retro.SHIELD
		"wrong":
			pts = points_wrong
			text = "VERKEERD ICOON"
			col = Retro.BAD
		"nogo_fail":
			pts = points_red
			text = "ROOD!"
			col = Retro.BAD
		_:
			text = "TE LAAT"
			col = Retro.DIM
	if pts != 0:
		add_points(id, pts)
	stats[id].streak = int(r.get("streak", 0))
	stats[id].best_streak = maxi(stats[id].best_streak, stats[id].streak)
	game.screen_wall.popup(id, "%+d" % pts if pts != 0 else text, col)
	_animate(id, outcome, Color(step.color))


## Hit: the colour runs down the cable and lights the robot side.
## Red pressed: the robot fires a red packet back at the tile.
func _animate(id: int, outcome: String, color: Color) -> void:
	var arena := game.arena
	match outcome:
		"hit", "nogo_ok":
			var c := color if outcome == "hit" else Retro.SHIELD
			arena.send_packet(id, c, func():
				arena.robot.set_side_glow(id - 1, c, 2.0)
				await arena.get_tree().create_timer(0.2).timeout
				arena.robot.set_side_glow(id - 1, Color.BLACK))
		"wrong", "nogo_fail":
			arena.send_packet(id, Color.RED, Callable(), false)


func finish() -> void:
	for id in players:
		game.arena.send_to_tile(id, {"stop": true})


## Places: the longest run of successes in a row.
func progress(id: int) -> int:
	return stats[id].best_streak


func make_player_overlay(id: int) -> Control:
	var line := StatusLine.new()
	line.source = func():
		var best: int = stats.get(id, {}).get("best_ms", 0)
		return "BESTE %d MS" % best if best > 0 else ""
	return line
