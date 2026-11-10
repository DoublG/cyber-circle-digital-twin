class_name Standings
extends RefCounted
## The ranking of the event (GameManager.standings): every player's best play
## from the database (most rounds survived, then most lives left, then the most
## points - the tie-breakers), live with the players in the game right now.

var game: GameManager
var records := {}                  # player_id -> {name, best, plays, lives, points} from the database


func _init(game_node: GameManager) -> void:
	game = game_node


## Read the records from the database again (a result was saved, the control server's list changed).
func load_records() -> void:
	records.clear()
	if game.db:
		for r in game.db.leaderboard():
			records[int(r.player_id)] = {"name": r.name, "best": int(r.best), "plays": int(r.plays),
				"lives": int(r.get("lives", 0)), "points": int(r.get("points", 0))}


## The overall ranking of the event, live: every player's best play, the
## players in the game right now with this play when it is better.
## [{player_id, name, best, lives, points, plays, tile}] best first (tile 0 =
## not playing now).
## lives: {tile: lives} to rank with instead of the tiles' health now (the scoreboard:
## the lives after this round's change, so the place matches the row order).
func ranking(lives := {}) -> Array:
	var arena := game.arena
	if arena == null:                      # screens are built before the game is set up
		return []
	var rows := {}
	for pid in records:
		var r: Dictionary = records[pid]
		rows[pid] = {"player_id": pid, "name": r.name, "best": r.best, "lives": r.get("lives", 0),
			"points": r.get("points", 0), "plays": r.plays, "tile": 0}
	for id in arena.players.player_ids():
		var pid: int = arena.players.player_db_id(id)
		if pid <= 0:
			continue                       # joined without the app: not ranked
		var row: Dictionary = rows.get(pid, {"player_id": pid, "name": arena.players.player_name(id), "best": 0,
			"lives": 0, "points": 0, "plays": 0})
		var now := {"best": game.survived.get(id, 0), "points": game.scores.get(id, 0),
			"lives": int(lives.get(id, maxi(arena.tiles[id - 1].health, 0)))}
		if better(now, row):
			row.merge(now, true)
		row.tile = id
		rows[pid] = row
	var out := rows.values()
	out.sort_custom(better)
	return out


## a ranks above b: more rounds survived, then more lives left, then more points.
static func better(a: Dictionary, b: Dictionary) -> bool:
	if a.best != b.best:
		return a.best > b.best
	if a.get("lives", 0) != b.get("lives", 0):
		return a.get("lives", 0) > b.get("lives", 0)
	return a.get("points", 0) > b.get("points", 0)


## Overall place of the player on this tile at this event (shared only when rounds,
## lives and points are all equal); 0 = not ranked.
func rank(tile_id: int, lives := {}) -> int:
	if game.arena == null:
		return 0
	var pid: int = game.arena.players.player_db_id(tile_id)
	if pid <= 0:
		return 0
	var rows := ranking(lives)
	var mine := rows.filter(func(r): return r.player_id == pid)
	if mine.is_empty():
		return 0
	return 1 + rows.filter(func(r): return better(r, mine[0])).size()


## The player's record: most rounds survived (this play included).
func record(tile_id: int) -> int:
	var pid: int = game.arena.players.player_db_id(tile_id)
	return maxi(records.get(pid, {}).get("best", 0), game.survived.get(tile_id, 0))
