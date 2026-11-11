class_name TileClock
extends RefCounted
## The tiles' clock (GameRound.tile_clock), for a round the game judges itself
## where the moment of a press matters (Ritme, Zwarte Piet): the tiles run a
## "clock" program (nothing on the ring, only the time since its one "start",
## sent with ours) and stamp every press with it. press_time() is the press's
## moment on the round's clock: the stamp when there is one (no network
## jitter; crystal drift over a round ~1 ms), else the moment it arrived.

var program := {}                 # {"game": "clock", "id": ...} while it runs
var stamped := 0                  # presses timed by their stamp (the rest: on arrival)
var _arena: Arena
var _players: Array[int] = []


func start(r: GameRound) -> void:
	_arena = r.game.arena
	_players = r.players
	program = {"game": "clock", "id": "%s-%d" % [r.title.to_lower().replace(" ", "-"), Time.get_ticks_usec()],
		"length": roundi(r.duration * 1000.0)}
	for id in _players:                  # the program and its start together: their clocks start with ours
		if not _arena.tiles[id - 1].is_dead:
			_arena.send_to_tile(id, {"program": program})
			_arena.send_to_tile(id, {"start": program.id})


func stop() -> void:
	if program.is_empty():
		return
	for id in _players:
		_arena.send_to_tile(id, {"stop": true})
	program = {}


## The press being handled now: when it happened (s on the round's clock).
## `arrived`: the round's clock now (the fallback).
func press_time(arrived: float) -> float:
	if program.is_empty():
		return arrived
	var stamp: Dictionary = _arena.press_stamp()
	if stamp.get("program", "") != program.id or not stamp.has("t"):
		return arrived
	var t := float(stamp.t) / 1000.0
	if absf(t - arrived) >= 1.0:         # (not sane: a tile that missed a pause or restarted)
		return arrived
	stamped += 1
	return t


## The press being handled now carries a stamp of this round's clock.
func press_stamped() -> bool:
	return not program.is_empty() and _arena.press_stamp().get("program", "") == program.id
