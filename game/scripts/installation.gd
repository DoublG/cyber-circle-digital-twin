class_name Installation
extends RefCounted
## Which places can be used (Arena.installation): the places that are part of
## this installation, and the ones taken out of service. A place is a floor
## tile (1-13) or a mobile place (a drone, 14-18).

var arena: Arena
var _disabled := {}               # tile_id -> true: out of service (not in the game)
var _not_installed := {}          # tile_id -> true: not part of this installation (hidden, see set_installed)


func _init(arena_node: Arena) -> void:
	arena = arena_node


## What a display node needs to know (ArenaMirror.fields).
func replica_fields() -> Dictionary:
	return {"disabled": _disabled, "not_installed": _not_installed}


## A display node: the master's fields.
func apply_replica(f: Dictionary) -> void:
	if f.has("not_installed"):
		_not_installed = f.not_installed
		for tile in arena.tiles:
			tile.installed = is_installed(tile.tile_id)
			tile.visible = tile.installed
		arena.show_installed()
	if f.has("disabled"):
		_disabled = f.disabled


## In service: the tile can be used in the game (see set_enabled).
func is_enabled(tile_id: int) -> bool:
	return not _disabled.has(tile_id) and not _not_installed.has(tile_id)


func is_installed(tile_id: int) -> bool:
	return not _not_installed.has(tile_id)


## The places that are part of this installation: e.g. only half the floor
## tiles, or only the mobile places (control server: Tegels › Installatie;
## --installed=1-7,14-18). The others are hidden - the tile or drone, its
## ducts, cable and light strip - get no slot on the screens and are never
## used. A player on one that goes leaves the game.
func set_installed(ids: Array) -> void:
	var keep := {}
	for id in ids:
		keep[int(id)] = true
	var changed := false
	for tile in arena.tiles:
		var id := tile.tile_id
		var on := keep.has(id)
		if on == is_installed(id):
			continue
		changed = true
		if on:
			_not_installed.erase(id)
		else:
			_not_installed[id] = true
			arena.players.leave(id)
		tile.installed = on
		tile.visible = on
		arena.cables.set_flow(id, arena.cable_color, 0.15 if on and is_enabled(id) else 0.0)
	if changed:
		arena.show_installed()
		arena.game.log_event("INSTALLATIE: %d PLAATSEN" % (arena.tiles.size() - _not_installed.size()), Retro.DIM)
		arena.game.on_players_changed()
		arena.screen_wall.refresh_all()


## Take a tile out of the game (setup, a broken or swapped tile) or back in.
## A player on it leaves the game (their result is saved).
func set_enabled(tile_id: int, on: bool) -> void:
	if on != _disabled.has(tile_id):
		return
	if on:
		_disabled.erase(tile_id)
	else:
		_disabled[tile_id] = true
		arena.players.leave(tile_id)
	arena.tiles[tile_id - 1].out_of_service = not on
	arena.cables.set_flow(tile_id, arena.cable_color, 0.15 if on else 0.0)
	arena.game.log_event("%s %s" % [Retro.tile_label(tile_id), "WEER IN GEBRUIK" if on else "BUITEN GEBRUIK"], Retro.DIM)
	arena.screen_wall.refresh_all()
