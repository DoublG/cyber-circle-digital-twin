class_name ArenaMirror
extends RefCounted
## The arena as the display nodes see it (Arena.mirror; Replica talks to it):
## the state their screens read (fields / apply, fast / apply_fast), who a
## relayed event is for (target, skip), and what a display node does itself -
## its own tiles (is_own_tile, tile_msg), lighter 3D views (render_settings).

var arena: Arena


func _init(arena_node: Arena) -> void:
	arena = arena_node


## What the screens of a display node read, as data (sent as deltas on change).
func fields() -> Dictionary:
	var t := []
	for tile in arena.tiles:
		t.append(tile.replica_state())
	var sound := arena.sound
	var narrator := arena.narrator
	var f := arena.players.replica_fields()
	f.merge(arena.installation.replica_fields())
	f.merge({"dying": arena.dying.keys(), "clip_waiting": arena.clip_waiting, "clip_started": arena.clip_started,
		"tiles": t, "texts": Texts.values,
		"sound": {"volume": sound.volume, "music_volume": sound.music_volume, "enabled": sound.enabled},
		"voice": {"enabled": narrator.enabled, "output": narrator.output, "volume": narrator.volume},
		"lights": {"brightness": arena.lights.brightness, "flashes": arena.lights.flashes},
		"robot_on": arena.robot.powered or arena.game.modes.power_show == "boot"})   # (a show: the NPC event plays it)
	f.merge(arena.game.replica_fields(), true)
	return f


## A display node: the master's fields (full: a snapshot, the screens are rebuilt).
func apply(f: Dictionary, full: bool) -> void:
	arena.installation.apply_replica(f)
	arena.players.apply_replica(f)
	if f.has("clip_waiting"):
		arena.clip_waiting = f.clip_waiting
	if f.has("clip_started"):
		arena.clip_started = f.clip_started
	if f.has("dying"):
		arena.dying = {}
		for id in f.dying:
			arena.dying[int(id)] = 1
	if f.has("tiles"):
		for i in mini(arena.tiles.size(), f.tiles.size()):
			arena.tiles[i].apply_replica_state(f.tiles[i])
	if f.has("texts"):
		Texts.apply(f.texts)
	if f.has("robot_on") and full and bool(f.robot_on) != arena.robot.powered:
		arena.robot.set_powered(bool(f.robot_on))      # (joined while it is off / on: no show)
	_apply_settings(f)
	arena.game.apply_replica(f, full)
	if full:
		arena.screen_wall.refresh()


## What changes every frame (sent LIVE_HZ, unreliable): the round's clocks, the robot's head.
func fast() -> Dictionary:
	var current := arena.game.current
	return {"round": current.replica_live() if current else {}, "robot": arena.robot.replica_pose()}


func apply_fast(d: Dictionary) -> void:
	if arena.game.current and d.has("round"):
		RoundMirror.apply(arena.game.current, d.round)
	if d.has("robot"):
		arena.robot.apply_replica_pose(d.robot)


## The object a relayed event is for (Replica.relay targets): "tile:3", its
## LED ring "ring:3", or one of the arena's parts.
func target(name: String) -> Object:
	if name.contains(":"):
		var id := int(name.get_slice(":", 1))
		if id < 1 or id > arena.tiles.size():
			return null
		return arena.tiles[id - 1].ring if name.begins_with("ring:") else arena.tiles[id - 1]
	return {"mirror": self, "cables": arena.cables, "npc": arena.npc, "wall": arena.screen_wall,
		"game": arena.game, "views": arena.game.views, "round": arena.game.current, "sound": arena.sound,
		"narrator": arena.narrator, "lights": arena.lights}.get(name)


## A display node: a relayed event it takes from MQTT itself (its own tiles).
func skip(to: String, method: StringName, args: Array) -> bool:
	if not arena.own_tiles_live:
		return false
	var id := -1
	if to.begins_with("tile:") and method in [&"press_button", &"hold_button", &"release_button"]:
		id = int(to.substr(5))
	elif (to == "npc" and method == &"press") or (to == "mirror" and method == &"tile_msg"):
		id = int(args[0])
	return id >= 0 and is_own_tile(id)


## A display node: a tile on one of its screens.
func is_own_tile(tile_id: int) -> bool:
	var groups: Array = arena.screen_wall.groups()
	for k in arena.replica_screens:
		if int(k) >= 1 and int(k) <= groups.size() and tile_id in groups[int(k) - 1]:
			return true
	return false


## A display node: a message for a tile's own logic (from the master, or MQTT for its own tiles).
func tile_msg(tile_id: int, msg: Dictionary) -> void:
	if tile_id >= 1 and tile_id <= arena.tiles.size():
		(arena.tiles[tile_id - 1].get_node("Firmware") as TileFirmware).receive(msg)


## Tests: a moment both sides note - the master sends its fields' digests, a
## display node compares its own with them and saves its screens (--shots=DIR)
## as drawn at game clock `at`.
func mark(name: String, at: float, digests := {}) -> void:
	if Replica.server:
		Replica.relay("mirror", &"mark", [name, at, Replica.digests(fields())])
		return
	var mine := Replica.digests(fields())
	var diff := digests.keys().filter(func(k): return mine.get(k) != digests[k])
	print("replica: mark %s state %s" % [name, "EQUAL" if diff.is_empty() else "DIFFERENT %s" % [diff]])
	if arena.replica_shots == "":
		return
	await drawn(at)
	DirAccess.make_dir_recursive_absolute(arena.replica_shots)
	for k in arena.replica_screens:
		var vp := arena.screen_wall.screen_viewport(int(k) - 1)
		if vp:
			vp.get_texture().get_image().save_png("%s/%s_screen%d.png" % [arena.replica_shots, name, int(k)])
	print("replica: shot %s" % name)
	if name == "quit":
		arena.get_tree().quit()


## Tests: the frame drawn at game clock `at` - the same picture on the master
## and on a display node, however late the mark got there.
func drawn(at: float) -> void:
	while arena.clock < at:
		await arena.get_tree().process_frame
	await RenderingServer.frame_post_draw


## A display node: its 3D views lighter (a Pi): resolution, MSAA, mesh detail,
## small parts hidden further away.
func render_settings() -> void:
	var view := arena.replica_view
	var wall := arena.screen_wall
	var detail := float(view.get("detail", 3.0))
	var detail_size := float(view.get("detail_size", 0.2))
	if detail > 0.0:
		for g in arena.find_children("*", "GeometryInstance3D", true, false):
			if (g as GeometryInstance3D).get_aabb().get_longest_axis_size() < detail_size:
				(g as GeometryInstance3D).visibility_range_end = detail
	wall.view_scale = float(view.get("view_scale", 0.75))
	wall.view_msaa = {0: Viewport.MSAA_DISABLED, 2: Viewport.MSAA_2X, 4: Viewport.MSAA_4X}.get(
		int(view.get("msaa", 2)), Viewport.MSAA_2X)
	wall.view_lod = float(view.get("lod", 4.0))


## The operator's sound, voice and light settings.
func _apply_settings(f: Dictionary) -> void:
	if f.has("sound"):
		arena.sound.volume = int(f.sound.volume)
		arena.sound.music_volume = int(f.sound.get("music_volume", arena.sound.music_volume))
	if f.has("voice"):
		arena.narrator.enabled = int(f.voice.enabled)
		arena.narrator.output = int(f.voice.output)
		arena.narrator.volume = int(f.voice.volume)
	if f.has("lights"):
		arena.lights.brightness = int(f.lights.brightness)
		arena.lights.flashes = int(f.lights.flashes)
		arena.lights.refresh()
