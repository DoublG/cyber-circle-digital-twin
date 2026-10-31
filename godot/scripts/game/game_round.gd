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
var duration := 45.0              # seconds; shared rounds may end earlier via is_finished()
var game: GameManager
var players: Array[int] = []      # tile ids taking part in this round
var points := {}                  # tile_id -> points scored this round
var time_left := 0.0


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
## "Instellingen", GameManager.settings_schema): [{key, label, min, max, step,
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


## Clean up LEDs etc. when the round ends.
func finish() -> void:
	pass


## Personal rounds: extra info drawn on top of a player's view (or null).
func make_player_overlay(_tile_id: int) -> Control:
	return null


## Shared rounds: the view shown on every screen (one instance per screen).
func make_shared_view() -> Control:
	return null


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
	var alive := players.filter(func(id): return not tile(id).is_dead and game.arena.is_playing(id))
	var levels := []
	for id in alive:
		if progress(id) not in levels:
			levels.append(progress(id))
	levels.sort()
	levels.reverse()                       # best first
	var places := {}
	for id in alive:
		places[id] = levels.find(progress(id)) + 1
	if levels.size() < 2:
		return places                      # everyone equally far
	for place in range(1, levels.size() + 1):
		var names := alive.filter(func(id): return places[id] == place).map(
			func(id): return game.arena.player_name(id).to_upper())
		game.log_event("%dE PLAATS: %s" % [place, ", ".join(names)], Retro.AMBER if place == 1 else Retro.CREAM)
	for id in alive:
		var last: bool = places[id] == levels.size()
		game.screen_wall.popup(id, "LAATSTE" if last else "%dE PLAATS" % places[id],
			Retro.BAD if last else (Retro.GOOD if places[id] == 1 else Retro.CREAM), false)
	return places


func tile(tile_id: int) -> CyberTile:
	return game.arena.tiles[tile_id - 1]


func _start() -> void:
	pass


func _update(_delta: float) -> void:
	pass
