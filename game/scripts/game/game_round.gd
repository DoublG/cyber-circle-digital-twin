class_name GameRound
extends RefCounted
## Base class for one round of the game. Subclasses fill in the hooks.
##   mode "personal": every player watches their own first-person view
##                    (make_player_overlay adds round info on top of it)
##   mode "shared":   one view, the same on all 5 screens (make_shared_view)

const SYNC_BASE := ["title", "rules", "mode", "on_tile", "players", "points", "duration", "progress_label", "ranked"]

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
var tile_clock := {}                 # {"game": "clock", "id": ...} while it runs
var stamped := 0                     # presses timed by their stamp (the rest: on arrival)


## Settings for this round from the round plan (web interface), e.g.
## {"categories": ["Computers"], "duration": 60, "question_count": 5}: every key
## that is a property of the round is set. Future special rounds and difficulty
## steering hook in here.
func configure(options: Dictionary) -> void:
	for key in options:
		if key in self:
			set(key, options[key])
		else:
			push_warning("%s: no setting %s" % [title, key])


## The settings the operator can change for this round type (web interface
## "Instellingen", GameSettings.schema): [{key, label, min, max, step,
## unit}]. Values with unit "s" follow the game's tempo.
func tunables() -> Array:
	return [setting("duration", "Speeltijd", 10, 300, 5, "s")]


static func setting(key: String, label: String, lo: float, hi: float, step: float, unit := "") -> Dictionary:
	return {"key": key, "label": label, "min": lo, "max": hi, "step": step, "unit": unit}


func begin(game_manager: GameManager, tile_ids: Array[int]) -> void:
	game = game_manager
	players = tile_ids
	for id in players:
		points[id] = 0
	time_left = duration
	_start()


func update(delta: float) -> void:
	time_left -= delta
	_update(delta)


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
## press_time() gives its moment, like for a press).
func button_up(_tile_id: int, _button: StringName) -> void:
	pass


## Clean up LEDs etc. when the round ends.
func finish() -> void:
	pass


# ---------------------------------------------------------------- the tiles' clock
# For a round the game judges itself where the moment of a press matters
# (Ritme, Zwarte Piet): the tiles run a "clock" program (nothing on the ring,
# only the time since its one "start", sent with ours) and stamp every press
# with it. press_time() is the press's moment on the round's clock: the
# stamp when there is one (no network jitter; crystal drift over a round
# ~1 ms), else the moment it arrived.

func start_tile_clock() -> void:
	tile_clock = {"game": "clock", "id": "%s-%d" % [title.to_lower().replace(" ", "-"), Time.get_ticks_usec()],
		"length": roundi(duration * 1000.0)}
	for id in players:                   # the program and its start together: their clocks start with ours
		if not tile(id).is_dead:
			game.arena.send_to_tile(id, {"program": tile_clock})
			game.arena.send_to_tile(id, {"start": tile_clock.id})


func stop_tile_clock() -> void:
	if tile_clock.is_empty():
		return
	for id in players:
		game.arena.send_to_tile(id, {"stop": true})
	tile_clock = {}


## The press being handled now: when it happened (s on the round's clock).
## `arrived`: the round's clock now (the fallback).
func press_time(arrived: float) -> float:
	var stamp: Dictionary = game.arena.press_stamp()
	if tile_clock.is_empty() or stamp.get("program", "") != tile_clock.id or not stamp.has("t"):
		return arrived
	var t := float(stamp.t) / 1000.0
	if absf(t - arrived) >= 1.0:         # (not sane: a tile that missed a pause or restarted)
		return arrived
	stamped += 1
	return t


## The press being handled now carries a stamp of this round's clock.
func press_stamped() -> bool:
	return not tile_clock.is_empty() and game.arena.press_stamp().get("program", "") == tile_clock.id


## Personal rounds: extra info drawn on top of a player's view (or null).
func make_player_overlay(_tile_id: int) -> Control:
	return null


## Shared rounds: the view shown on every screen (one instance per screen).
func make_shared_view() -> Control:
	return null


# ---------------------------------------------------------------- display nodes (Replica)
# A display node runs no round: it makes the same round type, with the
# master's data (replica_init) and fields (replica_sync, on change;
# replica_live, every frame), and its views read those as here.

## A shared round's own countdown (the seconds its view shows, e.g. the quiz's
## answer time), for the overview's timer; -1: none.
func shared_countdown() -> float:
	return -1.0


## The fields this round type's views read (besides SYNC_BASE), sent on change.
func replica_keys() -> Array:
	return []


## What is decided at the start (the questions, a chart): sent with the round.
func replica_init() -> Dictionary:
	return {}


## What changes every frame (sent LIVE_HZ, the latest wins).
func replica_live() -> Dictionary:
	return {"time_left": time_left}


## The fields that keep a RoundState per player ({field name: its class}):
## they are sent as plain data and built again on the display node.
func state_fields() -> Dictionary:
	return {}


func replica_sync() -> Dictionary:
	var d := {}
	var states := state_fields()
	for k in SYNC_BASE + replica_keys():
		if k in self:
			d[k] = RoundState.pack(get(k)) if states.has(k) else get(k)
	return d


## A display node: the master's round.
func replica_begin(game_manager: GameManager, init: Dictionary) -> void:
	game = game_manager
	_replica_set(init)


func apply_replica_sync(d: Dictionary) -> void:
	_replica_set(d)


func apply_replica_live(d: Dictionary) -> void:
	_replica_set(d)


## A display node: this round is over there (stop its videos).
func replica_end() -> void:
	pass


## A display node: the clocks run on between the master's updates.
func replica_tick(delta: float) -> void:
	time_left -= delta


func _replica_set(d: Dictionary) -> void:
	var states := state_fields()
	for k in d:
		if not (k in self):
			continue
		var cur = get(k)
		if states.has(k):
			RoundState.unpack(cur, d[k], states[k])
		elif cur is Array and (cur as Array).is_typed():
			(cur as Array).assign(d[k])
		else:
			set(k, d[k])


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
## personal rounds): the 1st places +1, the last places -1 (see rank_result).
func life_changes() -> Dictionary:
	var places := rank_result()
	var last: int = places.values().max() if not places.is_empty() else 0
	var out := {}
	if last < 2:
		return out                         # everyone equally far
	for id in places:
		if places[id] == 1:
			out[id] = 1
		elif places[id] == last:
			out[id] = -1
	return out


## Places by progress (players still alive), shared when equal: there can be
## several 1st and several 2nd places. Shows them (popups, event feed).
## Returns {tile_id: place}.
func rank_result() -> Dictionary:
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
	var alive := players.filter(func(id): return not tile(id).is_dead and game.arena.players.is_playing(id))
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


func tile(tile_id: int) -> CyberTile:
	return game.arena.tiles[tile_id - 1]


func _start() -> void:
	pass


func _update(_delta: float) -> void:
	pass
