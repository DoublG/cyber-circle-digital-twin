class_name DataSource
extends Node
## Where the game gets its questions and players and keeps its scores. Two
## kinds, with the same methods, so the game doesn't care which one it has:
##   GameDb      standalone: the SQLite file itself
##   ControlApi  the installation: the control server's HTTP API
## This base class is "no data": every method has an answer that means none,
## so a caller never has to ask whether a method exists.

signal changed                    # the ranking was refreshed


## Open the file / the server. false = not available.
func open(_where: String) -> bool:
	return false


func is_open() -> bool:
	return false


## The database this is (a checkpoint belongs to one, see Recovery); "" = not known yet.
func db_id() -> String:
	return ""


## Active questions, in the format QuizRound uses.
func questions() -> Array:
	return []


## Every player's best play: [{player_id, name, best, plays, lives, points}].
func leaderboard() -> Array:
	return []


## A player the app registered: {name, color, age}, {} = unknown. Await it
## (the control server is asked).
func fetch_player(_id: int) -> Dictionary:
	return {}


## A new game: its id (0 = not saved).
func start_game() -> int:
	return 0


func end_game(_game_id: int) -> void:
	pass


func save_round(_game_id: int, _round: int, _round_type: String, _rows: Array) -> void:
	pass


func save_result(_game_id: int, _r: Dictionary) -> void:
	pass


## Fetch the questions and the ranking again (they changed).
func refresh() -> void:
	pass


## Writes not in the database yet (0 = in sync).
func pending() -> int:
	return 0


## The database's own id of a game (a control server that was away gives a
## temporary one first).
func server_game_id(id: int) -> int:
	return id


## The game is (or will be) in the database.
func knows_game(id: int) -> bool:
	return id > 0


## The game's state for after a crash (Recovery); only the control server keeps it.
func save_checkpoint(_data: Dictionary) -> void:
	pass


## Await it: {db, checkpoint} as the control server keeps it; null = none / not reachable.
func fetch_checkpoint() -> Variant:
	return null
