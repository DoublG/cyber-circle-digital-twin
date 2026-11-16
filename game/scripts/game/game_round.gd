class_name GameRound
extends RefCounted
## Base class for one round of the game. Subclasses fill in the hooks.
##   mode "personal": every player watches their own first-person view
##                    (make_player_overlay adds round info on top of it)
##   mode "shared":   one view, the same on all 5 screens (make_shared_view)

var title := ""
var rules := ""
var mode := "personal"
var on_tile := false              # played on the tile itself: player cameras tilt down to it
var gives_lives := true           # the round can win a life (the randomizer's director uses it)
var ranked := true                # the round has places (1, 2, 3 ...); the quiz has none
var progress_label := "PUNTEN"     # what decides the places (progress), on the UITSLAG board
var can_repeat := false           # the randomizer may pick it twice in a row (the quiz)
var duration := 45.0              # seconds; shared rounds may end earlier via is_finished()
var game: GameManager
var players: Array[int] = []      # tile ids taking part in this round
var points := {}                  # tile_id -> points scored this round
var time_left := 0.0
## The round's countdown on the tiles: one violet LED once round the outer ring
## (GameManager shows it on the 3D tiles and sends it to the real ones). Off:
## Cyclone (its own green light runs round the ring).
var tile_countdown := true
var countdown := Vector2(-1.0, 0.0)  # (s left, s in all) now; x <= 0: none (to the display nodes too)
## Ages (like a question's min_age / max_age; operator settings per round type):
## a player younger than min_age is protected - a shield on the tile, and the
## last place costs them no life (they can still win one); the randomizer
## picks the round less often when the players are outside min_age .. max_age
## (AgeFit). 0 / 99: for everyone. The quiz has none (each question has its own).
var min_age := 0
var max_age := 99
var age_settings := true          # min_age / max_age are operator settings (not in the quiz)
## Lives at the end of the round (the rounds with places; life_changes) - the
## row of the operator's life table for the occupancy (GameSettings.life_rule,
## set_life_rule at the intro):
##   win_places   the best N places +1 life (1: the 1st place(s); 0: nobody)
##   win_percent  instead (> 0): the best N % of the players +1
##   lose_places  the last N places -1 life (1: the last place(s); 0: nobody)
##   lose_percent instead (> 0): the worst N % of the players -1
## Equal progress, equal outcome: a cut-off between equal players takes them
## all. Both +1 and -1 (overlapping settings): 0. A % is at least 1 player.
var win_places := 1
var win_percent := 0
var lose_places := 1
var lose_percent := 0
## Busy (Pressure): the rule above is the level's; base_rule the life table's as
## it is - for the players with a low score (Pressure.eased). {}: the same.
var base_rule := {}
var tile_clock := TileClock.new()  # the tiles stamp their presses (Ritme, Zwarte Piet)
## Display nodes (RoundMirror): the fields this round type's views read, sent
## on change ...
var replica_keys: Array = []
## ... and those of them that keep a RoundState per player ({field name: its
## class}): sent as plain data and built again on the display node.
var state_fields := {}


## The settings the operator can change for this round type (web interface
## "Instellingen", GameSettings.schema): [{key, label, min, max, step,
## unit}]. Values with unit "s" follow the game's tempo.
func tunables() -> Array:
	return [setting("duration", "Speeltijd", 10, 300, 5, "s")]


## The life rule for this round (a row of the life table, GameSettings.LIFE_ROW).
func set_life_rule(rule: Dictionary, base := {}) -> void:
	for k in ["win_places", "win_percent", "lose_places", "lose_percent"]:
		set(k, int(rule.get(k, get(k))))
	base_rule = base


## The rounds' rules end with "Na de ronde: ... +1 leven, ... -1 leven." for
## the default (1st +1, last -1): other life settings, that line says them.
func adapt_rules() -> void:
	if not ranked or (win_places == 1 and lose_places == 1 and win_percent <= 0 and lose_percent <= 0):
		return
	var lines := Array(rules.split("\n")).filter(func(l): return not l.begins_with("Na de ronde:"))
	var parts := []
	for side in [[win_places, win_percent, "beste", "+1"], [lose_places, lose_percent, "laatste", "-1"]]:
		if side[1] > 0:
			parts.append("de %s %d%% van de spelers %s leven" % [side[2], side[1], side[3]])
		elif side[0] == 1:
			parts.append("%s plaats %s leven" % ["1e" if side[3] == "+1" else "laatste", side[3]])
		elif side[0] > 1:
			parts.append("de %s %d plaatsen %s leven" % [side[2], side[0], side[3]])
	lines.append("Na de ronde: " + (", ".join(parts) if not parts.is_empty() else "geen levens erbij of eraf") + ".")
	rules = "\n".join(lines)


## The age settings (GameSettings adds them to tunables()): min_age, max_age.
func age_tunables() -> Array:
	if not age_settings:
		return []
	return [setting("min_age", "Beschermd onder leeftijd (0 = niemand)", 0, 18, 1),
		setting("max_age", "Geschikt tot leeftijd (minder kans daarboven)", 6, 99, 1)]


static func setting(key: String, label: String, lo: float, hi: float, step: float, unit := "") -> Dictionary:
	return {"key": key, "label": label, "min": lo, "max": hi, "step": step, "unit": unit}


func begin(game_manager: GameManager, tile_ids: Array[int]) -> void:
	game = game_manager
	players = tile_ids
	for id in players:
		points[id] = 0
	time_left = duration
	for id in players:
		if is_protected(id):
			_tile(id).shielded = true      # (GameManager takes it off at the end of the round)
	_start()


## This player is younger than the round's min_age, or new while it is busy
## (Pressure.in_grace: just came from the line): the last place costs no life.
## (The quiz: per question.)
func is_protected(id: int) -> bool:
	var age: int = game.arena.players.player_age(id)
	return (age > 0 and age < min_age) or game.pressure.in_grace(id)


func update(delta: float) -> void:
	time_left -= delta
	_update(delta)
	countdown = countdown_now() if tile_countdown else Vector2(-1.0, 0.0)


## The countdown the tiles show: (s left, s in all); x <= 0: none. Default: the
## round's time; a round with its own timer (the quiz's answer time) says so.
func countdown_now() -> Vector2:
	return Vector2(time_left, duration)


func is_finished() -> bool:
	return time_left <= 0.0


## Called at the start of the intro, before the round begins: upload data to
## the tiles up front (e.g. a program the tile runs on its own).
func prepare(game_manager: GameManager, _tile_ids: Array) -> void:
	game = game_manager


## A result reported by a tile's own logic (see TileFirmware).
func result(_tile_id: int, _data: Dictionary) -> void:
	pass


## Called when a player presses an icon during the round (eliminated players are filtered out).
func button(_tile_id: int, _button: StringName) -> void:
	pass


## Called when a player lets go of an icon (only Ritme's hold notes use it;
## tile_clock.press_time() gives its moment, like for a press).
func button_up(_tile_id: int, _button: StringName) -> void:
	pass


## Clean up LEDs etc. when the round ends.
func finish() -> void:
	pass


## Personal rounds: extra info drawn on top of a player's view (or null).
func make_player_overlay(_tile_id: int) -> Control:
	return null


## Shared rounds: the view shown on every screen (one instance per screen).
func make_shared_view() -> Control:
	return null


# ---------------------------------------------------------------- display nodes (Replica)
# A display node runs no round: it makes the same round type, with the
# master's data (replica_init) and fields (RoundMirror: replica_keys, on
# change; replica_live, every frame), and its views read those as here.

## A shared round's own countdown (the seconds its view shows, e.g. the quiz's
## answer time), for the overview's timer; -1: none.
func shared_countdown() -> float:
	return -1.0


## What is decided at the start (the questions, a chart): sent with the round.
func replica_init() -> Dictionary:
	return {}


## What changes every frame (sent LIVE_HZ, the latest wins).
func replica_live() -> Dictionary:
	return {"time_left": time_left}


## A display node: this round is over there (stop its videos).
func replica_end() -> void:
	pass


## A display node: the clocks run on between the master's updates.
func replica_tick(delta: float) -> void:
	time_left -= delta


## Round points can go below 0 (they decide this round's places); the total
## (a tie-break between equal rounds survived) never does.
func add_points(tile_id: int, n: int) -> void:
	points[tile_id] += n
	game.add_score(tile_id, n)


## How far a player got this round (personal rounds: e.g. the longest sequence).
## The round's places are based on this; default: the round's points.
func progress(tile_id: int) -> int:
	return points[tile_id]


## How the lives change at the end of this round: {tile_id: +1 / -1}. Lives
## only ever change here, by at most 1 (GameManager applies it). Default (the
## rounds with places): the best +1, the worst -1 as the life settings say
## (win_places / win_percent, lose_places / lose_percent; see _rank_result),
## except the protected ones (younger than min_age): their shield blocks the -1.
func life_changes() -> Dictionary:
	var places := _rank_result()
	var last: int = places.values().max() if not places.is_empty() else 0
	var out := {}
	if last < 2:
		return out                         # everyone equally far
	var up := _cut(places, win_places, win_percent, true)
	var down := _cut(places, lose_places, lose_percent, false)
	var b := base_rule
	var up_base := _cut(places, int(b.win_places), int(b.win_percent), true) if not b.is_empty() else up
	var down_base := _cut(places, int(b.lose_places), int(b.lose_percent), false) if not b.is_empty() else down
	for id in places:
		var easy: bool = game.pressure.eased(id)          # busy, a low score: the normal rules
		var d := (1 if id in (up_base if easy else up) else 0) - (1 if id in (down_base if easy else down) else 0)
		if d < 0 and is_protected(id):
			var who := game.arena.players.player_name(id).to_upper()
			game.log_event("%s: SCHILD - GEEN LEVEN KWIJT" % who, Retro.SHIELD)
			game.arena.narrator.say_to(id, "shielded_last", "Bijna laatst, maar je schild beschermt je."
				if places[id] < last else "Laatste, maar je schild beschermt je.")
		elif d != 0:
			out[id] = d
	return out


## The players at the top (best) or bottom of the places: the n best / last
## places, or (percent > 0) that share of the players - with everyone equal to
## the one at the cut-off.
static func _cut(places: Dictionary, n: int, percent: int, best: bool) -> Array:
	var ids := places.keys()
	if percent > 0:
		ids.sort_custom(func(a, b): return places[a] < places[b] if best else places[a] > places[b])
		var count := clampi(roundi(ids.size() * percent / 100.0), 1, ids.size())
		var edge: int = places[ids[count - 1]]
		return ids.filter(func(id): return places[id] <= edge if best else places[id] >= edge)
	if n <= 0:
		return []
	var last: int = places.values().max()
	return ids.filter(func(id): return places[id] <= n if best else places[id] > last - n)


## Places by progress (players still alive), shared when equal: there can be
## several 1st and several 2nd places. Shows them (popups, event feed).
## Returns {tile_id: place}.
func _rank_result() -> Dictionary:
	var result := places()
	var alive := result.keys()
	var levels: int = result.values().max() if not result.is_empty() else 0
	if levels < 2:
		return result                      # everyone equally far
	for place in range(1, levels + 1):
		var names := alive.filter(func(id): return result[id] == place).map(
			func(id): return game.arena.players.player_name(id).to_upper())
		game.log_event("%dE PLAATS: %s" % [place, ", ".join(names)], Retro.AMBER if place == 1 else Retro.CREAM)
	for id in alive:
		var last: bool = result[id] == levels
		game.screen_wall.popup(id, "LAATSTE" if last else "%dE PLAATS" % result[id],
			Retro.BAD if last else (Retro.GOOD if result[id] == 1 else Retro.CREAM), false)
	return result


## The places only (no popups): {tile_id: place}, 1 = best, shared when equal
## (1, 1, 2, ...): the UITSLAG board after the round.
## Rounds without places (ranked = false): {}.
func places() -> Dictionary:
	if not ranked:
		return {}
	var alive := players.filter(func(id): return not _tile(id).is_dead and game.arena.players.is_playing(id))
	var levels := []
	for id in alive:
		if progress(id) not in levels:
			levels.append(progress(id))
	levels.sort()
	levels.reverse()                       # best first
	var out := {}
	for id in alive:
		out[id] = levels.find(progress(id)) + 1
	return out


func _start() -> void:
	pass


func _update(_delta: float) -> void:
	pass


func _tile(tile_id: int) -> CyberTile:
	return game.arena.tiles[tile_id - 1]
