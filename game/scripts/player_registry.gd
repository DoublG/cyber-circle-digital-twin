class_name PlayerRegistry
extends RefCounted
## Who is on which place (Arena.players): the players in the game and the
## invites waiting for their four presses. A place is a floor tile (1-13) or a
## mobile place (a drone, 14-18); which ones can be used: Arena.installation.
##
## Joining:
##   1. register() / assign(): the tile lights up in the player's colour (the invite);
##   2. the player presses all 4 icons -> activate() -> join(): they play from the next round;
##   3. leave(): the place is free again (also an invite that ran out).

var arena: Arena
var _players := {}                # tile_id -> {name, age, player_id} (activated)
var _pending := {}                # tile_id -> {name, color, age, player_id, time_left} (registered)


func _init(arena_node: Arena) -> void:
	arena = arena_node


## Every frame, the master only: invites that were never activated run out.
func update(delta: float) -> void:
	for id in _pending.keys():
		_pending[id].time_left -= delta
		if _pending[id].time_left <= 0.0:
			leave(id)


## What a display node needs to know (ArenaMirror.fields).
func replica_fields() -> Dictionary:
	var pending := {}
	for id in _pending:
		var p: Dictionary = _pending[id].duplicate()
		p.erase("time_left")                     # (counts down every frame; the master decides)
		pending[id] = p
	return {"players": _players, "pending": pending}


## A display node: the master's fields.
func apply_replica(f: Dictionary) -> void:
	if f.has("players"):
		_players = f.players
	if f.has("pending"):
		_pending = f.pending


func is_playing(tile_id: int) -> bool:
	return _players.has(tile_id)


func player_name(tile_id: int) -> String:
	return _players[tile_id].name if _players.has(tile_id) else ""


## Age given at registration, 0 = unknown.
func player_age(tile_id: int) -> int:
	return _players[tile_id].age if _players.has(tile_id) else 0


## The player's id in the database (0 = joined without the app).
func player_db_id(tile_id: int) -> int:
	return _players[tile_id].player_id if _players.has(tile_id) else 0


## Register a player the app put in the database ({"assign": id}).
## mobile: with no tile given, a free mobile place (drone) when no floor tile is free.
func assign(player_id: int, tile_id := 0, color = null, mobile := false) -> int:
	var p: Dictionary = await arena.game.db.fetch_player(player_id) if arena.game.db else {}
	if p.is_empty():
		push_warning("assign: player %d not in the database" % player_id)
		return 0
	return register(tile_id, p.name, color if color is Color else Color(p.color), int(p.age), player_id, mobile)


## The tile a database player is on now (invited or playing), or 0. A player
## (one QR card) plays on one tile at a time - and comes back as often as they like.
func _tile_of_player(player_id: int) -> int:
	if player_id <= 0:
		return 0
	for id in _pending:
		if _pending[id].player_id == player_id:
			return id
	for id in _players:
		if _players[id].player_id == player_id:
			return id
	return 0


func player_ids() -> Array:
	var ids := _players.keys()
	ids.sort()
	return ids


## The tiles with an invite waiting.
func pending_ids() -> Array:
	return _pending.keys()


func is_pending(tile_id: int) -> bool:
	return _pending.has(tile_id)


## Registered but not activated yet: {name, color, age, time_left}, or {}.
func pending_info(tile_id: int) -> Dictionary:
	return _pending.get(tile_id, {})


## Step 1 (from the registration system after a QR scan): the tile lights up
## in the colour shown in the app (so the player can find it) and waits until
## all 4 icons are pressed.
## tile_id <= 0: pick a free floor tile; mobile = true (the gamemaster's
## choice in the app: "ook mobiele plaatsen"): when none is free, a free mobile
## place (a drone, M1 first). Never on its own. Returns the tile id, or 0 if none is
## free. player_id: the player's id in the database (0 = not from the database).
func register(tile_id: int, player: String, color := Color(1.0, 0.8, 0.1), age := 0, player_id := 0,
	mobile := false) -> int:
	if not arena.game.modes.accepting_players():
		push_warning("register %s: the arena.game is not open (%s)" % [player, arena.game.modes.name()])
		return 0
	var already := _tile_of_player(player_id)
	if already:                         # (two gamemasters scanning the same card at once)
		push_warning("register %s: already on tile %d" % [player, already])
		return 0
	if tile_id <= 0:
		var open := func(t): return t.idle and not is_pending(t.tile_id) and arena.installation.is_enabled(t.tile_id)
		var free := arena.tiles.filter(func(t): return open.call(t) and not t is DroneTile)
		if free.is_empty() and mobile:                    # the gamemaster's choice: a free mobile place, M1 first
			var drones := arena.tiles.filter(func(t): return open.call(t) and t is DroneTile)
			if not drones.is_empty():
				tile_id = drones[0].tile_id
		elif not free.is_empty():
			tile_id = _pick_free_tile(free.map(func(t): return t.tile_id))
		if tile_id <= 0:
			push_warning("register %s: no free tile" % player)
			return 0
	if is_playing(tile_id):
		push_warning("register %s: tile %d is in use" % [player, tile_id])
		return 0
	if not arena.installation.is_enabled(tile_id):
		push_warning("register %s: tile %d is out of service" % [player, tile_id])
		return 0
	for id in _pending:  # same colour twice at once makes tiles hard to tell apart
		if id != tile_id and _pending[id].color.is_equal_approx(color):
			push_warning("register %s: colour already used by a pending player" % player)
	var tile := arena.tiles[tile_id - 1]
	_pending[tile_id] = {"name": player, "color": color, "age": age, "player_id": player_id,
		"time_left": arena.activation_timeout}
	arena.rt(tile).start_activation(color)
	arena.cables.set_flow(tile_id, color, 0.5)
	arena.registered.emit(tile_id, player, color)
	arena.game.log_event("%s SCHRIJFT IN OP %s" % [player.to_upper(), Retro.tile_label(tile_id)], color)
	arena.game.on_players_changed()       # the screens show the invite on this tile
	return tile_id


## "Any free floor tile", fake random: fill the emptiest part of the circle -
## the free tile furthest (around the circle) from the taken and invited ones,
## at random among the equally good ones. Players spread out evenly.
func _pick_free_tile(free: Array) -> int:
	var floor_count := arena.tiles.filter(func(t): return not t is DroneTile).size()
	var taken := range(1, floor_count + 1).filter(func(id): return is_playing(id) or is_pending(id))
	if taken.is_empty():
		return free.pick_random()
	var best := []
	var best_d := -1
	for id in free:
		var d := floor_count
		for o in taken:
			var gap := absi(int(id) - int(o))
			d = mini(d, mini(gap, floor_count - gap))   # distance around the circle
		if d > best_d:
			best_d = d
			best = [id]
		elif d == best_d:
			best.append(id)
	return best.pick_random()


## Step 2 done: all 4 icons pressed. The player is ready and takes part from
## the next round; the robot greets them.
func activate(tile_id: int) -> void:
	var who: String = _pending[tile_id].name
	var color: Color = _pending[tile_id].color
	var age: int = _pending[tile_id].age
	var player_id: int = _pending[tile_id].player_id
	_pending.erase(tile_id)
	join(tile_id, who, age, player_id)
	arena.activated.emit(tile_id, who)
	arena.game.log_event("%s DOET MEE (%s)" % [who.to_upper(), Retro.tile_label(tile_id)], Retro.TEAL)
	arena.npc.greet(tile_id, color)


## Make a player active on a tile (normally via register + 4 presses).
func join(tile_id: int, player := "", age := 0, player_id := 0) -> void:
	if not arena.game.modes.accepting_players():
		push_warning("join %s: the arena.game is not open (%s)" % [player, arena.game.modes.name()])
		return
	if not arena.installation.is_enabled(tile_id):
		push_warning("join %s: tile %d is out of service" % [player, tile_id])
		return
	var tile := arena.tiles[tile_id - 1]
	_players[tile_id] = {"name": player if player != "" else "Speler %d" % tile_id, "age": age,
		"player_id": player_id}
	arena.rt(tile).revive(arena.game.lives_for(tile_id))
	tile.idle = false
	arena.cables.set_flow(tile_id, arena.cable_color)
	arena.game.on_players_changed()


## After a crash (Recovery): a player back on their tile as they were - no
## invite, no greeting; the game calls on_players_changed once afterwards.
func restore_player(tile_id: int, player: String, age: int, player_id: int, lives: int, max_lives: int) -> void:
	var tile := arena.tiles[tile_id - 1]
	_players[tile_id] = {"name": player, "age": age, "player_id": player_id}
	arena.rt(tile).revive(max_lives)
	tile.health = clampi(lives, 0, CyberTile.HEART_COUNT)
	tile.idle = false
	arena.cables.set_flow(tile_id, arena.cable_color)


## After a crash: an invite waiting for its player again (a fresh time to activate).
func restore_invite(tile_id: int, player: String, color: Color, age: int, player_id: int) -> void:
	var tile := arena.tiles[tile_id - 1]
	_pending[tile_id] = {"name": player, "color": color, "age": age, "player_id": player_id,
		"time_left": arena.activation_timeout}
	arena.rt(tile).start_activation(color)
	arena.cables.set_flow(tile_id, color, 0.5)


## The player leaves: back to the idle animation, view removed from the screen.
func leave(tile_id: int) -> void:
	arena.hits_on_way.erase(tile_id)
	if _pending.has(tile_id) or _players.has(tile_id):
		arena.cue(&"leave", tile_id)
	if _pending.erase(tile_id):
		arena.tiles[tile_id - 1].idle = true
		arena.cables.set_flow(tile_id, arena.cable_color, 0.15)
		arena.game.on_players_changed()
	if not _players.has(tile_id):
		return
	arena.game.on_player_left(tile_id)         # saves their result while name/score are known
	_players.erase(tile_id)
	var tile := arena.tiles[tile_id - 1]
	tile.is_dead = false
	tile.idle = true
	arena.cables.set_flow(tile_id, arena.cable_color, 0.15)
	arena.game.on_players_changed()
