class_name CodeRound
extends GameRound
## Personal round "Code kraken", a code-breaking game: crack the secret code,
## a row of the tile's icons. Press a row of icons on your tile = one try;
## every icon of the try gets its hint, on your own screen (its box, under
## all your tries) and on the tile's ring (a segment per place, in order):
##   green   the right icon in the right place
##   yellow  this icon is in the code, in another place
##   grey    this icon is not in the code (or not that often)
## Cracked: points (more for fewer tries) and the next, harder code -
## everyone gets the same codes, in the same order, each at their own pace:
##   1. 4 icons, all different   (24 possibilities)
##   2. 4 icons, one can repeat  (256)
##   3. 5 icons                  (1024) ... and so on with 5
## The lesson without words: every extra place makes a code much harder to
## guess (a longer password).
## Places by the points (shared when equal): the 1st places gain a life, the
## last places lose one.
##
## The game judges (not a tile program): the code never leaves the game. The
## tile only shows what the game sends ({"show": ...}, see TileFirmware);
## timing doesn't matter here, so the network delay doesn't either.

const LEVELS := [                 # per code: its length, may an icon come more than once
	{"length": 4, "repeats": false},
	{"length": 4, "repeats": true},
	{"length": 5, "repeats": true},
]
const HINT_GREEN := Color(0.2, 1.0, 0.35)
const HINT_YELLOW := Color(1.0, 0.8, 0.1)
const HINT_OFF := Color(0.13, 0.13, 0.13)

var crack_points := 6            # a code cracked ...
var par_tries := 8               # ... +1 for every try fewer than this
var level_bonus := 2             # ... +this for every level above the first
var hint_time := 1.6             # s the hints stay on the ring after a try
var codes := []                  # [{code: [lane, ...], length, repeats}] - the same for everyone
var state: Dictionary[int, PlayerState] = {}   # per tile
var clock := 0.0


## One player's round.
class PlayerState extends RoundState:
	var level := 0               # the code they are on (index in codes)
	var guess := []              # the icons typed so far (lanes)
	var tries := []              # this code's finished tries: [{guess, marks, green, yellow}]
	var cracked := 0             # codes cracked
	var total_tries := 0
	var last := {}               # the last try's result: {at, text, points} (cracked: + code, tries)
	var hint_until := 0.0        # clock until which the ring shows the hints (0: not)


func _init() -> void:
	title = "Code kraken"
	mode = "personal"
	duration = 75.0
	rules = _rules()


func _rules() -> String:
	return ("Kraak de geheime code: een rij iconen. Druk een rij iconen op je tegel.\n"
		+ "Na elke poging krijgt elk icoon een kleur, op je scherm en je tegel:\n"
		+ "groen = juiste plek, geel = zit erin maar op een andere plek, grijs = zit er niet in.\n"
		+ "Gekraakt: +%d punten, +1 voor elke poging minder dan %d. Dan een moeilijkere code!\n"
		+ "Na de ronde: meeste punten +1 leven, minste punten -1 leven.") % [crack_points, par_tries]


func prepare(game_manager: GameManager, _tile_ids: Array) -> void:
	game = game_manager
	rules = _rules()


func tunables() -> Array:
	return super() + [
		setting("crack_points", "Punten per gekraakte code", 0, 50, 1),
		setting("par_tries", "Bonus: +1 per poging minder dan", 1, 20, 1),
		setting("level_bonus", "Extra punten per moeilijkere code", 0, 20, 1),
		setting("hint_time", "Hints op de tegel", 0.5, 5.0, 0.1, "s"),
	]


func _start() -> void:
	clock = 0.0
	codes = make_codes(12)
	for id in players:
		state[id] = PlayerState.new()
		_show(id)


## The codes, in order: LEVELS, then the last level again.
static func make_codes(count: int) -> Array:
	var out := []
	for i in count:
		var lv: Dictionary = LEVELS[mini(i, LEVELS.size() - 1)]
		var code := []
		if lv.repeats:
			for k in lv.length:
				code.append(randi() % 4)
			if lv.length == 4 and code.duplicate().all(func(x): return code.count(x) == 1):
				code[3] = code[0]          # (level 2: a repeat for real - else it is level 1 again)
		else:
			code = [0, 1, 2, 3]
			code.shuffle()
			code.resize(lv.length)
		out.append({"code": code, "length": lv.length, "repeats": lv.repeats})
	return out


## The hint per place of a guess: 2 = green (right place), 1 = yellow (in the
## code, another place), 0 = grey. An icon is yellow only as often as it is
## left in the code after the greens (code ▢▢△✕, guess ▢△▢▢: green, yellow,
## yellow, grey).
static func marks(code: Array, guess: Array) -> Array:
	var out := []
	var left := [0, 0, 0, 0]               # the code's icons not matched by a green
	for k in code.size():
		out.append(2 if k < guess.size() and guess[k] == code[k] else 0)
		if out[k] != 2:
			left[code[k]] += 1
	for k in mini(guess.size(), code.size()):
		if out[k] == 0 and left[guess[k]] > 0:
			out[k] = 1
			left[guess[k]] -= 1
	return out


## The hints counted: [green, yellow].
static func score(code: Array, guess: Array) -> Array:
	var green := 0
	for k in code.size():
		if k < guess.size() and guess[k] == code[k]:
			green += 1
	var common := 0
	for lane in 4:
		common += mini(code.count(lane), guess.count(lane))
	return [green, common - green]


func length_of(id: int) -> int:
	var st := state[id]
	return codes[mini(st.level, codes.size() - 1)].length


func button(id: int, b: StringName) -> void:
	var lane := CyberTile.BUTTONS.find(b)
	if lane < 0 or not state.has(id):
		return
	var st := state[id]
	if st.level >= codes.size():
		return
	st.guess.append(lane)
	st.hint_until = 0.0                    # (typing on: the hints of the last try go)
	if st.guess.size() < length_of(id):
		_show(id)
		return
	var c: Dictionary = codes[st.level]
	var m := marks(c.code, st.guess)
	var h := [m.count(2), m.count(1)]
	st.tries.append({"guess": st.guess.duplicate(), "marks": m, "green": h[0], "yellow": h[1]})
	st.total_tries += 1
	st.guess = []
	if h[0] == c.length:                   # cracked
		var pts: int = crack_points + level_bonus * st.level + maxi(par_tries - st.tries.size(), 0)
		st.cracked += 1
		st.last = {"at": clock, "text": "GEKRAAKT!", "points": pts, "code": c.code, "tries": st.tries.size()}
		add_points(id, pts)
		game.log_event("%s KRAAKT CODE %d (+%d)"
			% [game.arena.players.player_name(id).to_upper(), st.level + 1, pts], Retro.GOOD)
		game.arena.npc.feedback(id, HINT_GREEN, 0.3)
		st.level += 1
		st.tries = []
		st.hint_until = clock + hint_time
		_show(id, true)
		return
	st.last = {"at": clock, "text": "%d GROEN  %d GEEL" % [h[0], h[1]], "points": 0}
	st.hint_until = clock + hint_time
	_show(id)


func _update(delta: float) -> void:
	clock += delta
	for id in players:
		var st := state[id]
		if st.hint_until > 0.0 and clock >= st.hint_until:
			st.hint_until = 0.0
			_show(id)                      # the hints have been seen: ready for the next try


## The tile: while typing, a segment per place (the icons pressed so far in
## their colour, the rest dim); after a try the hint of every place, in order;
## cracked: all green.
func _show(id: int, cracked := false) -> void:
	if tile(id).is_dead:
		return
	var st := state[id]
	var ring := []
	if cracked:
		for k in codes[st.level - 1].length:
			ring.append("#" + HINT_GREEN.to_html(false))
	elif st.hint_until > 0.0 and not st.tries.is_empty():
		var t: Dictionary = st.tries[-1]
		for k in t.marks.size():
			var col: Color = [HINT_OFF, HINT_YELLOW, HINT_GREEN][t.marks[k]]
			ring.append("#" + col.to_html(false))
	elif st.level < codes.size():
		for k in length_of(id):
			var col: Color = CyberTile.BUTTON_COLORS[CyberTile.BUTTONS[st.guess[k]]] if k < st.guess.size() \
				else Color(0.25, 0.25, 0.25)
			ring.append("#" + col.to_html(false))
	var icons := CyberTile.BUTTONS.map(func(b): return "#" + (CyberTile.BUTTON_COLORS[b] as Color).to_html(false))
	game.arena.send_to_tile(id, {"show": {"ring": ring, "icons": icons}})


## The best crack of the round in the event feed.
func finish() -> void:
	for id in players:
		game.arena.send_to_tile(id, {"show": false})
	var best := 0
	var names := []
	for id in state:
		if state[id].cracked > best:
			best = state[id].cracked
			names = []
		if state[id].cracked == best:
			names.append(game.arena.players.player_name(id).to_upper())
	if best >= 1:
		game.log_event("%d CODE%s GEKRAAKT: %s" % [best, "S" if best > 1 else "", ", ".join(names)], Retro.CREAM)


# (Replica: what CodeView reads - not the codes themselves, only their sizes)
func replica_keys() -> Array:
	return ["state", "crack_points", "par_tries"]


## (Its per-player state goes to the display nodes as plain data: RoundState.)
func state_fields() -> Dictionary:
	return {"state": PlayerState}


func replica_init() -> Dictionary:
	return {"codes": codes.map(func(c): return {"code": [], "length": c.length, "repeats": c.repeats})}


func replica_live() -> Dictionary:
	return {"time_left": time_left, "clock": clock}


func replica_tick(delta: float) -> void:
	time_left -= delta
	clock += delta


func make_player_overlay(id: int) -> Control:
	var view := CodeView.new()
	view.round = self
	view.tile_id = id
	return view
