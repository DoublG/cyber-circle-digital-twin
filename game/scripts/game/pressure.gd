class_name Pressure
extends RefCounted
## Busy: visitors are waiting for a tile (GameManager.pressure). A player who
## survives for long keeps a tile that somebody in the line wants, so when the
## gamemasters say it is busy (the switch in the app / web interface: retained
## MQTT `<prefix>/busy`) AND the floor is full, the game gets harder - step by
## step, one level per round (0 = normal .. 3), and back down one per round
## once it has not been full for `pressure_cooldown` rounds (a player
## exterminated frees a tile for a moment: that is no reason to ease off).
## The gamemaster switching it off: normal again at once.
## What a level does (the operator's table, "pressure_levels" in the settings;
## LEVEL_ROW):
##   mercy     % of the director's help when lives run low (RoundPicker.mercy)
##   streak    1: the quiz's streak bonus (+1 life) stays, 0: none
##   win       1: the best places still win a life, 0: nobody
##   lose_min  at least this % of the players loses a life (the life table's
##             rule when that is more already)
##   tempo     % of the speed: 110 = 1.1x as fast, every time shorter (x the game's tempo)
##   quiz      % of the weight of the rounds that only take lives (the quiz)
## Never touched: the ages' protection (shields, lives by age). By score (the
## rounds survived in this play, the ranking): the harder rules are for the
## players who hold a tile long -
##   new         fewer than `grace_rounds`: the shield, no life lost (they have
##               just waited in the line)
##   low score   fewer than `pressure_ease` % of the rounds of the best in the
##               round: the normal rules (the life table as it is, a life to
##               win, the streak bonus) - none of the level's extras
##   the rest    the level's rules Full: the players and invites on the floor tiles that
## can be used (installed, in service, not broken) are at least
## `pressure_full_at` % of them; the mobile players don't count (their own
## handhelds, not the line at the floor).

const LEVEL_ROW := {"mercy": 100, "streak": 1, "win": 1, "lose_min": 0, "tempo": 100, "quiz": 100}
const LEVEL_LIMITS := {"mercy": [0, 100], "streak": [0, 1], "win": [0, 1], "lose_min": [0, 100],
	"tempo": [50, 200], "quiz": [0, 1000]}
const DEFAULT_LEVELS := [
	{"mercy": 50, "streak": 0, "win": 1, "lose_min": 0, "tempo": 100, "quiz": 100},
	{"mercy": 25, "streak": 0, "win": 1, "lose_min": 25, "tempo": 110, "quiz": 150},
	{"mercy": 0, "streak": 0, "win": 0, "lose_min": 40, "tempo": 120, "quiz": 200},
]
const MAX_LEVEL := 3

## The game settings ("Spel", GameSettings.PRESSURE_KEYS)
var pressure_full_at := 100        # % of the usable floor tiles taken = full
var pressure_max := MAX_LEVEL      # the highest level (0: never harder)
var pressure_cooldown := 2         # rounds not full before a level down
var grace_rounds := 1              # a new player's first rounds: no life lost (while busy)
var pressure_ease := 50            # % of the best's rounds survived: below it the normal rules (0: off)

var game: GameManager
var busy := false                  # the gamemasters: visitors are waiting
var busy_by := ""                  # ... who switched it
var level := 0                     # 0 normal .. MAX_LEVEL
var levels: Array = DEFAULT_LEVELS.duplicate(true)   # the operator's table: row i = level i + 1
var _calm := 0                     # rounds in a row not (busy and full)


func _init(game_node: GameManager) -> void:
	game = game_node


## The gamemasters' switch (MQTT `busy`).
func set_busy(on: bool, by := "") -> void:
	if on == busy:
		return
	busy = on
	busy_by = by
	if not busy and level > 0:
		level = 0                      # nobody waiting: normal again at once
		game.log_event("NIET MEER DRUK - GEWOON SPEL", Retro.TEAL)
	elif busy:
		game.log_event("DRUK: ER WACHTEN SPELERS" + (" (%s)" % by.to_upper() if by != "" else ""), Retro.AMBER)
	_calm = 0
	game.picker.plan()


## Before a round (GameManager._next_round): one level up while busy and full,
## one down after `pressure_cooldown` rounds that were not. Returns the change (-1, 0, +1).
func update() -> int:
	var before := level
	var top := clampi(pressure_max, 0, MAX_LEVEL)
	if busy and is_full():
		_calm = 0
		level = mini(level + 1, top)
	else:
		_calm += 1
		if not busy:
			level = 0
		elif _calm >= maxi(pressure_cooldown, 1):
			level = maxi(level - 1, 0)
	level = mini(level, top)
	if level != before:
		game.log_event(("DRUK: MOEILIJKER - NIVEAU %d" if level > before else "MINDER DRUK - NIVEAU %d") % level,
			Retro.AMBER if level > before else Retro.TEAL)
	return signi(level - before)


## The usable floor tiles and how many of them are taken (playing, not
## exterminated, or an invite waiting): {usable, taken}.
func occupancy() -> Dictionary:
	var a := game.arena
	var usable := 0
	var taken := 0
	for id in range(1, mini(Retro.FLOOR_TILES, a.tiles.size()) + 1):
		if not a.installation.is_installed(id) or not a.installation.is_enabled(id) or a.installation.is_broken(id):
			continue
		usable += 1
		if (a.players.is_playing(id) and not a.tiles[id - 1].is_dead) or not a.players.pending_info(id).is_empty():
			taken += 1
	return {"usable": usable, "taken": taken}


func is_full() -> bool:
	var o := occupancy()
	return o.usable > 0 and o.taken * 100 >= o.usable * clampi(pressure_full_at, 1, 100)


## The level's row (level 0: LEVEL_ROW, nothing changes).
func row() -> Dictionary:
	if level <= 0 or levels.is_empty():
		return LEVEL_ROW
	return levels[mini(level, levels.size()) - 1]


func mercy_factor() -> float:
	return row().mercy / 100.0


func tempo_factor() -> float:
	return row().tempo / 100.0


func quiz_factor() -> float:
	return row().quiz / 100.0


## The life table's rule for this round, made harder by the level: nobody wins
## (win 0); at least lose_min % lose a life (players: the players in the round).
func apply_to_rule(rule: Dictionary, players: int) -> Dictionary:
	var r := rule.duplicate()
	var p := row()
	if int(p.win) == 0:
		r.win_places = 0
		r.win_percent = 0
	var lose_min: int = p.lose_min
	if lose_min > 0 and players > 0:
		var share: float = r.lose_percent if r.lose_percent > 0 else r.lose_places * 100.0 / players
		if share < lose_min:
			r.lose_percent = lose_min
	return r


## A new player while it is busy: their first `grace_rounds` rounds cost no life.
func in_grace(tile_id: int) -> bool:
	return level > 0 and grace_rounds > 0 and game.survived.get(tile_id, 0) < grace_rounds


## A low score while it is busy: fewer than `pressure_ease` % of the rounds of the
## best player still in the game - the normal rules for them (GameRound.life_changes).
func eased(tile_id: int) -> bool:
	if level <= 0 or pressure_ease <= 0:
		return false
	var best := 0
	for id in game.arena.players.player_ids():
		if not game.arena.tiles[id - 1].is_dead:
			best = maxi(best, game.survived.get(id, 0))
	return best > 0 and game.survived.get(tile_id, 0) * 100 < best * pressure_ease


## The streak bonus: off from level 1, except for a low score (eased) - id 0: the level's.
func streak_ok(tile_id := 0) -> bool:
	return int(row().streak) == 1 or (tile_id > 0 and eased(tile_id))


## The line for the round's rules (the intro): "" at level 0.
func rules_line() -> String:
	if level <= 0:
		return ""
	var parts := []
	var p := row()
	if int(p.win) == 0:
		parts.append("geen levens erbij")
	if int(p.streak) == 0:
		parts.append("geen bonus voor juist op rij")
	if int(p.tempo) > 100:
		parts.append("sneller")
	if grace_rounds > 0:
		parts.append("nieuwe spelers %s beschermd" % ("1 ronde" if grace_rounds == 1 else "%d rondes" % grace_rounds))
	if pressure_ease > 0:
		parts.append("minder dan %s de rondes van de beste: gewone regels"
			% ("de helft van" if pressure_ease == 50 else "%d%% van" % pressure_ease))
	return "DRUK (niveau %d): er wachten spelers, het wordt moeilijker%s." % [level,
		(" - " + ", ".join(parts)) if not parts.is_empty() else ""]


## For the web interface / the app (the game's state): {busy, by, level, max, full, usable, taken}.
func status() -> Dictionary:
	var o := occupancy()
	var ids: Array = game.arena.players.player_ids()
	return {"busy": busy, "by": busy_by, "level": level, "max": clampi(pressure_max, 0, MAX_LEVEL),
		"grace": ids.filter(func(id): return in_grace(id)),
		"eased": ids.filter(func(id): return not in_grace(id) and eased(id)),
		"full": o.usable > 0 and o.taken * 100 >= o.usable * clampi(pressure_full_at, 1, 100),
		"usable": o.usable, "taken": o.taken}


## The operator's table made safe: MAX_LEVEL rows of whole numbers within
## LEVEL_LIMITS (missing rows / values: the default's).
static func clean_levels(given: Variant) -> Array:
	var out := []
	for i in MAX_LEVEL:
		var g: Variant = given[i] if given is Array and i < given.size() and given[i] is Dictionary else {}
		var row := {}
		for k in LEVEL_ROW:
			var v = g.get(k, DEFAULT_LEVELS[i][k])
			row[k] = clampi(int(v) if (v is int or v is float) else DEFAULT_LEVELS[i][k],
				LEVEL_LIMITS[k][0], LEVEL_LIMITS[k][1])
		out.append(row)
	return out
