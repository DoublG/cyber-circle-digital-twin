class_name RhythmRound
extends GameRound
## Personal round, a variation on dance games: the tile icons fall down in 4
## lanes on the player's own screen (one lane per icon, in its colour). Press
## that icon on your tile when the symbol reaches the bottom:
##   on the line           3 points (points_line)
##   in the yellow band    1 point  (points_band)
##   no symbol there       -1 point (points_wrong: no use pressing everything)
## A symbol that falls through the band is missed (0 points, the combo ends).
## It starts slow with one symbol at a time; the symbols fall faster and come
## closer together, and from `parallel_from` of the round on two at once.
## Places by the points (shared when equal): the 1st places gain a life, the
## last places lose one.
##
## Unlike the other tile games the game judges the presses (the symbols are
## on the screen, not on the tile): a press counts at the moment it arrives,
## minus `latency_ms` (the tile -> game delay of the real installation). The
## band and the line are a part of the fall: the faster the symbols, the less
## time you have. Every player gets the same chart.

var fall_start := 2.6            # s from the top to the line at the start ...
var fall_end := 1.3              # ... and at the end of the round
var gap_start := 1.5             # s between symbols at the start ...
var gap_end := 0.45              # ... and at the end
var parallel_from := 0.35        # part of the round after which two at once can come ...
var parallel_chance := 0.45      # ... with this chance at the end (growing)
var band := 0.13                 # half the yellow band, as a part of the fall
var line := 0.035                # half the line zone, as a part of the fall
var points_line := 3
var points_band := 1
var points_wrong := -1
var latency_ms := 0.0

var notes := []                  # {t: hit time (s since the start), lane: 0..3, fall: s}
var clock := 0.0                 # s since the round started (stops when paused)
var state := {}                  # tile_id -> {judged: {note index: points}, combo, best_combo, lines, last: [lane flashes]}
var _first := 0                  # index of the first note that can still be judged by anyone


func _init() -> void:
	title = "Ritme"
	mode = "personal"
	duration = 45.0
	rules = _rules()


func _rules() -> String:
	return ("Iconen vallen naar beneden op je scherm, elk in de kleur van zijn knop.\nDruk dat icoon op je tegel als het onderaan aankomt:\nin de gele band +%d, precies op de lijn +%d punten. Zomaar drukken: %d.\nEerst traag en één per keer, dan sneller en meerdere tegelijk!\nNa de ronde: meeste punten +1 leven, minste punten -1 leven."
		% [points_band, points_line, points_wrong])


## During the intro: the rules with the points as set.
func prepare(game_manager: GameManager, _tile_ids: Array) -> void:
	game = game_manager
	rules = _rules()


func tunables() -> Array:
	return super() + [
		setting("fall_start", "Valtijd begin", 0.6, 6.0, 0.1, "s"),
		setting("fall_end", "Valtijd einde", 0.4, 6.0, 0.1, "s"),
		setting("gap_start", "Tijd tussen iconen begin", 0.2, 4.0, 0.05, "s"),
		setting("gap_end", "Tijd tussen iconen einde", 0.2, 4.0, 0.05, "s"),
		setting("parallel_from", "Meerdere tegelijk vanaf (deel ronde)", 0.0, 1.0, 0.05),
		setting("parallel_chance", "Kans op twee tegelijk (einde)", 0.0, 1.0, 0.05),
		setting("band", "Gele band (halve hoogte, deel val)", 0.03, 0.4, 0.01),
		setting("line", "Lijn (halve hoogte, deel val)", 0.01, 0.15, 0.005),
		setting("points_line", "Punten op de lijn", 0, 20, 1),
		setting("points_band", "Punten in de gele band", 0, 20, 1),
		setting("points_wrong", "Punten zomaar gedrukt", -20, 0, 1),
		setting("latency_ms", "Vertraging tegel -> spel", 0, 500, 10, "ms"),
	]


func _start() -> void:
	clock = 0.0
	notes = make_chart()
	for id in players:
		state[id] = {"judged": {}, "combo": 0, "best_combo": 0, "lines": 0, "last": [{}, {}, {}, {}]}


## The chart: one symbol at a time first, then faster and closer together,
## later sometimes two at once (always on different icons).
func make_chart() -> Array:
	var out := []
	var t := fall_start + 1.0              # the first symbol falls the whole way
	var last_lane := -1
	while t < duration - 0.6:
		var p := t / duration
		var fall := lerpf(fall_start, fall_end, p)
		var lanes := range(4)
		lanes.shuffle()
		if lanes[0] == last_lane:          # not the same icon twice in a row
			lanes.append(lanes.pop_front())
		var count := 1
		if p >= parallel_from and parallel_from < 1.0:
			var chance := parallel_chance * clampf((p - parallel_from) / (1.0 - parallel_from) * 1.5, 0.0, 1.0)
			if randf() < chance:
				count = 2
		for k in count:
			out.append({"t": t, "lane": lanes[k], "fall": fall})
		last_lane = lanes[0]
		t += lerpf(gap_start, gap_end, pow(p, 0.8)) * (1.4 if count > 1 else 1.0)
	return out


func _update(delta: float) -> void:
	clock += delta
	# symbols that fell through the band: missed by everyone who didn't press them
	while _first < notes.size() and _past(notes[_first]):
		for id in players:
			var st: Dictionary = state[id]
			if not st.judged.has(_first):
				st.judged[_first] = 0
				if not tile(id).is_dead:
					st.combo = 0
					st.last[notes[_first].lane] = {"at": clock, "text": "GEMIST", "points": 0}
		_first += 1


func _past(note: Dictionary) -> bool:
	return (clock - note.t) / note.fall > band


func button(id: int, b: StringName) -> void:
	var lane := CyberTile.BUTTONS.find(b)
	if lane < 0 or not state.has(id):
		return
	var at := clock - latency_ms / 1000.0
	var st: Dictionary = state[id]
	var best := -1
	var best_d := INF
	for i in range(_first, notes.size()):
		var n: Dictionary = notes[i]
		if (n.t - at) / n.fall > band:
			break                          # further notes are still higher up
		if n.lane != lane or st.judged.has(i):
			continue
		var d: float = absf(at - n.t) / n.fall
		if d <= band and d < best_d:
			best = i
			best_d = d
	var pts := points_wrong
	var text := "MIS"
	if best >= 0:
		pts = points_line if best_d <= line else points_band
		text = "LIJN!" if best_d <= line else "GOED"
		st.judged[best] = pts
		st.combo += 1
		st.best_combo = maxi(st.best_combo, st.combo)
		if best_d <= line:
			st.lines += 1
			_flash(id, CyberTile.BUTTON_COLORS[b])
		if st.combo > 0 and st.combo % 10 == 0:
			game.screen_wall.popup(id, "COMBO %d" % st.combo, Retro.GOOD, false)
	else:
		st.combo = 0
	st.last[lane] = {"at": clock, "text": text, "points": pts}
	if pts != 0:
		add_points(id, pts)


## On the line: the icon's colour runs down the cable and lights the robot side.
func _flash(id: int, color: Color) -> void:
	var arena := game.arena
	arena.send_packet(id, color, func():
		arena.robot.set_side_glow(arena.robot_side(id), color, 2.0)
		await arena.get_tree().create_timer(0.15).timeout
		arena.robot.set_side_glow(arena.robot_side(id), Color.BLACK))


## The longest combo of the round in the event feed.
func finish() -> void:
	var best := 0
	var names := []
	for id in state:
		if state[id].best_combo > best:
			best = state[id].best_combo
			names = []
		if state[id].best_combo == best:
			names.append(game.arena.player_name(id).to_upper())
	if best >= 5:
		game.log_event("LANGSTE COMBO %d: %s" % [best, ", ".join(names)], Retro.CREAM)


func make_player_overlay(id: int) -> Control:
	var view := RhythmView.new()
	view.round = self
	view.tile_id = id
	return view
