extends Node3D
## The player area (scenes/arena.tscn): robot in the middle, 13 tiles around it,
## connected to the robot by cable ducts (models/arena_floor.glb). Everything is
## placed in the scene, so you can see and edit it in the Godot editor.
## Tile_01 stands in front of robot side 0 (-Z), then clockwise seen from above,
## 2.5 m from the robot centre (matches ARENA_R in blender/build_models.py).
## The camera "Camera" is the fixed overview of the room, looking at the robot.
##
## Multiplayer: up to 18 players: one per floor tile (1-13) and 5 mobile players
## (14-18, DroneTile: a drone flying above the tiles, for players who can't
## stand on a tile - same game, see drone_tile.gd). Joining is done by the external
## registration system:
##   1. the player scans the QR code with the Android app and picks a colour;
##      several people can register at the same time. The app shows the tile
##      number and colour, the system sends
##      {"tile": 3, "register": "Erik", "color": "#ff8800", "age": 10} -> that tile lights
##      up in the colour, so the player can find it. The colour is only used
##      for this; after activation the tile looks like every other one.
##   2. the player activates the tile by pressing all 4 icons
##   3. the player is ready and takes part from the next round
## Every player gets a fixed first-person view on one of the 5 screens (ScreenWall).
## Each spoke duct has a light strip: light flows from the tile to the robot,
## and a button press sends a bright packet down the cable; the robot reacts
## when the packet arrives.
##
## Digital twin hook: feed messages from the real installation (MQTT,
## WebSocket, ...) into apply_command(). Examples:
##   {"tile": 3, "register": "Erik", "color": "#ff8800", "age": 10}
##   {"tile": 14, "register": "Erik", ...}  (a mobile player: always on a chosen
##                       drone, 14-18 = M1-M5; set up at their station first)
##                       (QR scan; without "tile" a free tile is chosen; "age" is
##                        optional and protects young players from too hard questions)
##   {"assign": 42, "tile": 3, "color": "#ff8800", "mobile": true}  (player 42 from the database, put
##                        there by the gamemaster app; name and age are read from it;
##                        "color": the tile lights up in it so the player finds it;
##                        "tile" optional)
##   {"tile": 3, "join": "Erik", "age": 10}               (activate directly, no presses)
##   {"tile": 3, "leave": true}        (also cancels a pending registration)
##   {"tile": 3, "enabled": false}     (out of service: skipped by the game; true = back in)
##   {"tile": 3, "points": 5}          (operator: add or remove points in this round)
##   {"tile": 3, "health": 2}
##   {"tile": 3, "ring": ["#ff0000", "#000000", ...]}
##   {"tile": 3, "led": 12, "color": "#ffff00"}
##   {"tile": 3, "press": "Cross"}                  (simulated tap)
##   {"tile": 3, "pressure": {"Cross": 0.8}}        (raw sensor values 0..1)
##   {"tile": 3, "button_led": "Circle", "color": "#00ff00"}
##   {"robot": "head", "angle": 45}
##   {"robot": "look_at_tile", "tile": 3}
##   {"robot": "fire", "tile": 3}                        (turn + fire the plunger)
##   {"attack": [1, 4, 9], "everyone": false}            (combined player attack on the robot)
##   {"attacked": [2, 7]}                                (combined robot attack: -1 life each)
##   {"tile": 3, "attack": true} / {"tile": 3, "attacked": true}   (single tile)
##   {"robot": "death", "tiles": [3, 7, 11]}             (death animation; also
##                                                        triggered by health -> 0)
##   {"tile": 3, "revive": true}
##   {"robot": "spin", "speed": 30}                      (idle spin, deg/s)
##   {"robot": "bulbs", "side": 2, "color": "#ff0000"}   (side = tile - 1)
##   {"robot": "party", "on": true, "speed": 0.6}        (party lamp in the dome)
##   {"robot": "bulb_effect", "effect": "rainbow"}       (none/rainbow/chase/pulse)
##   {"robot": "smoke", "seconds": 3}                    (the real robot's smoke machine)
##   {"robot": "home", "dir": "cw"} / {"robot": "stop"}  (the real robot: find the start again / stop the motor)
##   {"game": "start"} / {"game": "next"} / {"game": "stop"}
##   {"game": "boot"} / {"game": "shutdown"}       (the robot's show, the mode stays)
##   {"game": "plan", "slot": 0, "round": "quiz", "options": {"categories": ["Computers"]}}
##                                                    (operator: the next round(s); "" = random)
##   {"game": "plan_random"}                          (plan the next rounds at random again)
##   {"sound": "attack"}                                 (play a sound now: a random file of that
##                                                        event / folder, whatever the game is doing)
##   {"sound": "gong", "file": "gong2.ogg", "volume": 60} (one file; volume in % for this sound only)
##   {"sound_stop": true}                                (stop every sound that is playing)
##   {"sound_reload": true}                              (scan the sound folders again: new files)
##   {"room": "door", "open": true}
##   {"room": "light", "color": "#b0d0ff"}               (ceiling ring light)
##   {"tile": 3, "result": {...}}       (result of the tile's own logic, see TileFirmware)
##
## Messages to the tiles go through send_to_tile() / the tile_message signal
## (programs for rounds the tile runs itself). simulate_firmware = true runs
## that tile logic in the twin; with the real tiles connected (MqttBridge)
## set it to false.
##
## Display nodes (Replica, docs/SETUP.md §4): the master serves them
## (--serve-replicas); a display node runs this same scene with --replica: no
## game logic, it follows the master's state (replica_fields / apply_replica)
## and plays its events (the tiles through rt(), sounds, lights, popups) on
## its own screens (--show). The robot is an NPC (RobotNpc): never steered over
## the network - on every node it acts by itself on the game's events.

@export var packet_speed := 1.6        # cable lengths per second (tile -> robot)
@export var cable_color := Color(0.15, 0.5, 1.0)
@export var activation_timeout := 60.0  # seconds to press all 4 icons after the QR scan
@export var free_delay := 1.5           # s after the death animation before the tile is free again
@export_file("*.ogv") var death_clip := "res://data/videos/exterminate.ogv"  # in the player's view
@export var clip_wait := 30.0           # s the death clip waits for the player's split view (then dropped)
@export var clip_time := 8.0            # s the death screen stays (a shorter clip holds its last frame)
@export var simulate_firmware := true  # run the tiles' own logic in the twin (no real tiles)

const CABLE_SHADER := preload("res://shaders/cable_flow.gdshader")
const DRONES := 5                       # mobile players (ids after the floor tiles)

@onready var robot: CyberRobot = $Robot
@onready var room: SpaceshipRoom = $Room
@onready var screen_wall: ScreenWall = $ScreenWall
@onready var game: GameManager = $Game
var observer: ObserverRig          # floating camera for the overview page (visitors)
var sound := SoundBoard.new()      # sound effects for the game events
var lights := LightDirector.new()  # the room's lights (virtual, and the real ones over MQTT)
var narrator := Narrator.new()     # read-aloud: prebaked speech per screen text, its own channel
var tiles: Array[CyberTile] = []
var _cable_mats: Array[ShaderMaterial] = []   # index = tile_id - 1
var _packets: Array[Dictionary] = []          # {tile, pos, color, on_arrive}
signal registered(tile_id: int, player: String, color: Color)  # e.g. to tell the app the tile
signal activated(tile_id: int, player: String)
signal exterminated(tile_id: int, player: String)   # the robot's shot hit: the death animation starts
signal tile_message(tile_id: int, msg: Dictionary)  # to the real tile (e.g. via MQTT)
signal light_cue(event: StringName, data: Dictionary)  # a game moment for the lights (cue(); MQTT light/event)
signal stream_changed(tile_id: int, on: bool, info: Dictionary)  # a companion video stream (CompanionStream)

var _players := {}                            # tile_id -> {name} (activated)
var _pending := {}                            # tile_id -> {name, color, time_left} (registered)
var _demo_idle := 0.0                          # --demo-idle
var _hits_on_way := {}                        # tile_id -> shots that will cost a life, not landed yet
var _attacks := 0                             # robot attacks under way (charging, shots flying)
var dying := {}                               # tile_id -> msec the robot's shot landed (0: not yet) during the extermination
var clock := 0.0                              # game time (s): follows --fixed-fps, unlike the wall clock
var clip_waiting := {}                        # tile_id -> clock at the hit: death clip not seen yet (no split view)
var _clip_length := {}                        # clip path -> length (s)
var clip_started := {}                        # tile_id -> clock when the death clip started in the player's view
var _disabled := {}                           # tile_id -> true: out of service (not in the game)
var _not_installed := {}                      # tile_id -> true: not part of this installation (hidden, see set_installed)
var _voice_export := ""                        # --voice-export=FILE
var _streams := {}                             # tile_id -> CompanionStream (only while one is asked for)
var replica: Replica                           # --serve-replicas (master) / --replica (a display node)
var npc: RobotNpc                              # the robot's behaviour: the same on every node, from the game's events
var _trelays := {}                             # tile -> TileRelay (rt)
var replica_screens: Array = []                # a display node: the screens it shows (--show)
var replica_view := {}                         # a display node: its render settings (--view-scale, ...)
var own_tiles_live := false                    # a display node: its own tiles' commands come over MQTT
var replica_shots := ""                        # tests: a display node saves its screens at the master's marks


func _ready() -> void:
	npc = RobotNpc.new()
	npc.name = "RobotNpc"
	npc.arena = self
	npc.robot = robot
	add_child(npc)
	robot.hit.connect(_on_robot_hit)
	var floor_tiles: int = $Tiles.get_children().filter(func(c): return c is CyberTile).size()
	for k in DRONES:                          # the mobile players' drones: ids after the floor tiles
		var drone := DroneTile.new()
		drone.name = "Drone_%d" % (k + 1)
		drone.tile_id = floor_tiles + k + 1
		drone.slot = k
		drone.arena = self
		$Tiles.add_child(drone)
	for child in $Tiles.get_children():
		if child is CyberTile:
			tiles.append(child)
	tiles.sort_custom(func(x, y): return x.tile_id < y.tile_id)
	for tile in tiles:
		tile.button_pressed.connect(_on_button_pressed)
		tile.died.connect(_on_tile_died)
		tile.health_changed.connect(func(id, _h): screen_wall.update_player(id))
		tile.idle = true
		var fw := TileFirmware.new()
		fw.name = "Firmware"
		fw.tile = tile
		fw.report = _firmware_report
		tile.add_child(fw)
	var floor_model: Node = $Room if $Room.baked else $Floor   # baked: the floor is part of the room
	if $Room.baked:
		for mi in $Floor.find_children("*", "MeshInstance3D", true, false):
			mi.visible = false                  # (keeps the floor collider)
	for tile in tiles:
		if tile is DroneTile:                   # (no cable: bolts through the air)
			continue
		var strip := floor_model.find_child("Spoke_Light_%02d" % tile.tile_id, true, false) as MeshInstance3D
		var mat := ShaderMaterial.new()
		mat.shader = CABLE_SHADER
		mat.set_shader_parameter("flow_color", cable_color)
		strip.material_override = mat
		_cable_mats.append(mat)
		set_cable_flow(tile.tile_id, cable_color, 0.15)  # idle tiles: faint flow
	_apply_command_line()                    # after the tiles are known, before the screens
	sound.name = "Sound"
	add_child(sound)
	lights.name = "Lights"
	add_child(lights)
	narrator.name = "Narrator"
	narrator.wall = screen_wall
	add_child(narrator)
	registered.connect(func(id, _who, _color):             # read out: where to go
		narrator.say(Narrator.invite_name(id), Narrator.invite_line(id), "invite", {"tile": id}))
	robot.fired.connect(func(_to): cue(&"attack"))
	activated.connect(func(id, _who): cue(&"join", id))
	registered.connect(func(id, who, color): cue(&"registered", id, {"color": "#" + color.to_html(false), "player": who}))
	observer = ObserverRig.new()
	observer.name = "Observer"
	add_child(observer)
	observer.setup(self)
	if Replica.client:
		_replica_render_settings()
	screen_wall.setup(self)
	if Replica.client and ($Mqtt as MqttBridge).node_id == "":
		($Mqtt as MqttBridge).node_id = "display-" + MqttBridge.lan_address().replace(".", "-")
	if replica:
		replica.arena = self
		replica.name = "Replica"
		replica.node_id = ($Mqtt as MqttBridge).node_id
		_start_replica.call_deferred()
	if Replica.client:
		game.setup_replica(self)
	else:
		game.setup(self)
	lights.setup(self)
	if _voice_export != "":
		_export_voice.call_deferred()
	($Mqtt as MqttBridge).setup(self)   # no-op while its url is empty


## The replication node lives at /root/Replica on every node (RPCs need the
## same path on both ends; a test may put the arena elsewhere).
func _start_replica() -> void:
	get_tree().root.add_child(replica)
	tree_exiting.connect(func(): if is_instance_valid(replica): replica.queue_free())
	if Replica.client:
		replica.screens = replica_screens
		replica.online_changed.connect(func(on): screen_wall.set_link(on))
		replica.join()
	elif not replica.serve():
		replica.queue_free()
		replica = null


## A tile's visual actions as the game calls them: here and on the display nodes.
func rt(tile: CyberTile) -> TileRelay:
	if not _trelays.has(tile):
		_trelays[tile] = TileRelay.new(tile)
	return _trelays[tile]


func _firmware_report(cmd: Dictionary) -> void:
	if Replica.client:
		return                                   # (a display's tile logic only shows: the master scores)
	apply_command(cmd)


# ---------------------------------------------------------------- display nodes (Replica)

## What the screens of a display node read, as data (sent as deltas on change).
func replica_fields() -> Dictionary:
	var pending := {}
	for id in _pending:
		var p: Dictionary = _pending[id].duplicate()
		p.erase("time_left")                     # (counts down every frame; the master decides)
		pending[id] = p
	var t := []
	for tile in tiles:
		t.append(tile.replica_state())
	var f := {"players": _players, "pending": pending, "disabled": _disabled, "not_installed": _not_installed,
		"dying": dying.keys(), "clip_waiting": clip_waiting, "clip_started": clip_started, "tiles": t,
		"texts": Texts.values,
		"sound": {"volume": sound.volume, "enabled": sound.enabled},
		"voice": {"enabled": narrator.enabled, "output": narrator.output, "volume": narrator.volume},
		"lights": {"brightness": lights.brightness, "flashes": lights.flashes},
		"robot_on": robot.powered or game.power_show == "boot"}   # (a show: the NPC event plays it)
	f.merge(game.replica_fields(), true)
	return f


## A display node: the master's fields (full: a snapshot, the screens are rebuilt).
func apply_replica(f: Dictionary, full: bool) -> void:
	if f.has("not_installed"):
		_not_installed = f.not_installed
		for tile in tiles:
			tile.installed = is_installed(tile.tile_id)
			tile.visible = tile.installed
		_show_installed()
	if f.has("players"):
		_players = f.players
	if f.has("pending"):
		_pending = f.pending
	if f.has("disabled"):
		_disabled = f.disabled
	if f.has("clip_waiting"):
		clip_waiting = f.clip_waiting
	if f.has("clip_started"):
		clip_started = f.clip_started
	if f.has("dying"):
		dying = {}
		for id in f.dying:
			dying[int(id)] = 1
	if f.has("tiles"):
		for i in mini(tiles.size(), f.tiles.size()):
			tiles[i].apply_replica_state(f.tiles[i])
	if f.has("texts"):
		Texts.apply(f.texts)
	if f.has("robot_on") and full and bool(f.robot_on) != robot.powered:
		robot.set_powered(bool(f.robot_on))      # (joined while it is off / on: no show)
	if f.has("sound"):
		sound.volume = int(f.sound.volume)
	if f.has("voice"):
		narrator.enabled = int(f.voice.enabled)
		narrator.output = int(f.voice.output)
		narrator.volume = int(f.voice.volume)
	if f.has("lights"):
		lights.brightness = int(f.lights.brightness)
		lights.flashes = int(f.lights.flashes)
		lights.refresh()
	game.apply_replica(f, full)
	if full:
		screen_wall.refresh()


## What changes every frame (sent LIVE_HZ, unreliable): the round's clocks, the robot's head.
func replica_fast() -> Dictionary:
	return {"round": game.current.replica_live() if game.current else {}, "robot": robot.replica_pose()}


func apply_replica_fast(d: Dictionary) -> void:
	if game.current and d.has("round"):
		game.current.apply_replica_live(d.round)
	if d.has("robot"):
		robot.apply_replica_pose(d.robot)


## The object a relayed event is for (Replica.relay targets).
func replica_target(target: String) -> Object:
	if target.begins_with("tile:"):
		var id := int(target.substr(5))
		return tiles[id - 1] if id >= 1 and id <= tiles.size() else null
	match target:
		"arena": return self
		"npc": return npc
		"wall": return screen_wall
		"game": return game
		"round": return game.current
		"sound": return sound
		"narrator": return narrator
		"lights": return lights
	return null


## A display node: a relayed event it takes from MQTT itself (its own tiles).
func replica_skip(target: String, method: StringName, args: Array) -> bool:
	if not own_tiles_live:
		return false
	if target.begins_with("tile:") and method == &"press_button":
		return is_own_tile(int(target.substr(5)))
	if target == "npc" and method == &"press":
		return is_own_tile(int(args[0]))
	if target == "arena" and method == &"replica_tile_msg":
		return is_own_tile(int(args[0]))
	return false


## A display node: a tile on one of its screens.
func is_own_tile(tile_id: int) -> bool:
	var groups: Array = screen_wall.groups()
	for k in replica_screens:
		if int(k) >= 1 and int(k) <= groups.size() and tile_id in groups[int(k) - 1]:
			return true
	return false


## A display node: a message for a tile's own logic (from the master, or MQTT for its own tiles).
func replica_tile_msg(tile_id: int, msg: Dictionary) -> void:
	if tile_id >= 1 and tile_id <= tiles.size():
		(tiles[tile_id - 1].get_node("Firmware") as TileFirmware).receive(msg)


## Tests: a moment both sides note - the master sends its fields' digests,
## a display node compares its own with them and saves its screens (--shots=DIR).
func replica_mark(name: String, digests := {}) -> void:
	if Replica.server:
		Replica.relay("arena", &"replica_mark", [name, Replica.digests(replica_fields())])
		return
	var mine := Replica.digests(replica_fields())
	var diff := digests.keys().filter(func(k): return mine.get(k) != digests[k])
	print("replica: mark %s state %s" % [name, "EQUAL" if diff.is_empty() else "DIFFERENT %s" % [diff]])
	if replica_shots == "":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(replica_shots)
	for k in replica_screens:
		var vp := screen_wall.screen_viewport(int(k) - 1)
		if vp:
			vp.get_texture().get_image().save_png("%s/%s_screen%d.png" % [replica_shots, name, int(k)])
	print("replica: shot %s" % name)
	if name == "quit":
		get_tree().quit()


func replica_packet(tile_id: int, color: Color, to_robot: bool) -> void:
	packet(tile_id, color, Callable(), to_robot)


## A display node: its 3D views lighter (a Pi): resolution, MSAA, mesh detail,
## small parts hidden further away.
func _replica_render_settings() -> void:
	var detail := float(replica_view.get("detail", 3.0))
	var detail_size := float(replica_view.get("detail_size", 0.2))
	if detail > 0.0:
		for g in find_children("*", "GeometryInstance3D", true, false):
			if (g as GeometryInstance3D).get_aabb().get_longest_axis_size() < detail_size:
				(g as GeometryInstance3D).visibility_range_end = detail
	screen_wall.view_scale = float(replica_view.get("view_scale", 0.75))
	screen_wall.view_msaa = {0: Viewport.MSAA_DISABLED, 2: Viewport.MSAA_2X, 4: Viewport.MSAA_4X}.get(
		int(replica_view.get("msaa", 2)), Viewport.MSAA_2X)
	screen_wall.view_lod = float(replica_view.get("lod", 4.0))


# ---------------------------------------------------------------- players

## In service: the tile can be used in the game (see set_tile_enabled).
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
	for tile in tiles:
		var id := tile.tile_id
		var on := keep.has(id)
		if on == is_installed(id):
			continue
		changed = true
		if on:
			_not_installed.erase(id)
		else:
			_not_installed[id] = true
			leave(id)
		tile.installed = on
		tile.visible = on
		set_cable_flow(id, cable_color, 0.15 if on and is_enabled(id) else 0.0)
	if changed:
		_show_installed()
		game.log_event("INSTALLATIE: %d PLAATSEN" % (tiles.size() - _not_installed.size()), Retro.DIM)
		game.on_players_changed()
		screen_wall.refresh_all()


## Hide the floor parts of the places that are not installed: the duct to the
## robot with its cable, label and light strip, and the duct between two
## neighbours (when either of them is not installed). Baked room: the per-tile
## meshes Tile_Ducts_NN / Ring_NN (bake_models.py); unbaked: the floor's parts.
func _show_installed() -> void:
	var floor_model: Node = $Room if $Room.baked else $Floor
	var n := Retro.FLOOR_TILES
	for id in range(1, n + 1):
		var on := is_installed(id)
		for part in ["Tile_Ducts_%02d", "Spoke_%02d", "Cable_%02d", "Label_%02d", "Spoke_Light_%02d"]:
			var node := floor_model.find_child(part % id, true, false) as Node3D
			if node:
				node.visible = on
		var ring := floor_model.find_child("Ring_%02d" % id, true, false) as Node3D   # to the next tile
		if ring:
			ring.visible = on and is_installed(id % n + 1)


## Take a tile out of the game (setup, a broken or swapped tile) or back in.
## A player on it leaves the game (their result is saved).
func set_tile_enabled(tile_id: int, on: bool) -> void:
	if on == not _disabled.has(tile_id):
		return
	if on:
		_disabled.erase(tile_id)
	else:
		_disabled[tile_id] = true
		leave(tile_id)
	tiles[tile_id - 1].out_of_service = not on
	set_cable_flow(tile_id, cable_color, 0.15 if on else 0.0)
	game.log_event("%s %s" % [Retro.tile_label(tile_id), "WEER IN GEBRUIK" if on else "BUITEN GEBRUIK"], Retro.DIM)
	screen_wall.refresh_all()


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
	var p: Dictionary = await game.db.fetch_player(player_id) if game.db else {}
	if p.is_empty():
		push_warning("assign: player %d not in the database" % player_id)
		return 0
	return register(tile_id, p.name, color if color is Color else Color(p.color), int(p.age), player_id, mobile)


## The tile a database player is on now (invited or playing), or 0. A player
## (one QR card) plays on one tile at a time - and comes back as often as they like.
func tile_of_player(player_id: int) -> int:
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


func pending_count() -> int:
	return _pending.size()


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
func register(tile_id: int, player: String, color := Color(1.0, 0.8, 0.1), age := 0, player_id := 0, mobile := false) -> int:
	if not game.accepting_players():
		push_warning("register %s: the game is not open (%s)" % [player, game.mode_name()])
		return 0
	var already := tile_of_player(player_id)
	if already:                         # (two gamemasters scanning the same card at once)
		push_warning("register %s: already on tile %d" % [player, already])
		return 0
	if tile_id <= 0:
		var open := func(t): return t.idle and not is_pending(t.tile_id) and is_enabled(t.tile_id)
		var free := tiles.filter(func(t): return open.call(t) and not t is DroneTile)
		if free.is_empty() and mobile:                    # the gamemaster's choice: a free mobile place, M1 first
			var drones := tiles.filter(func(t): return open.call(t) and t is DroneTile)
			if not drones.is_empty():
				tile_id = drones[0].tile_id
		elif not free.is_empty():
			tile_id = pick_free_tile(free.map(func(t): return t.tile_id))
		if tile_id <= 0:
			push_warning("register %s: no free tile" % player)
			return 0
	if is_playing(tile_id):
		push_warning("register %s: tile %d is in use" % [player, tile_id])
		return 0
	if not is_enabled(tile_id):
		push_warning("register %s: tile %d is out of service" % [player, tile_id])
		return 0
	for id in _pending:  # same colour twice at once makes tiles hard to tell apart
		if id != tile_id and _pending[id].color.is_equal_approx(color):
			push_warning("register %s: colour already used by a pending player" % player)
	var tile := tiles[tile_id - 1]
	_pending[tile_id] = {"name": player, "color": color, "age": age, "player_id": player_id,
		"time_left": activation_timeout}
	rt(tile).start_activation(color)
	set_cable_flow(tile_id, color, 0.5)
	registered.emit(tile_id, player, color)
	game.log_event("%s SCHRIJFT IN OP %s" % [player.to_upper(), Retro.tile_label(tile_id)], color)
	game.on_players_changed()       # the screens show the invite on this tile
	return tile_id


## "Any free floor tile", fake random: fill the emptiest part of the circle -
## the free tile furthest (around the circle) from the taken and invited ones,
## at random among the equally good ones. Players spread out evenly.
func pick_free_tile(free: Array) -> int:
	var floor_count := tiles.filter(func(t): return not t is DroneTile).size()
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
func _activate(tile_id: int) -> void:
	var who: String = _pending[tile_id].name
	var color: Color = _pending[tile_id].color
	var age: int = _pending[tile_id].age
	var player_id: int = _pending[tile_id].player_id
	_pending.erase(tile_id)
	join(tile_id, who, age, player_id)
	activated.emit(tile_id, who)
	game.log_event("%s DOET MEE (%s)" % [who.to_upper(), Retro.tile_label(tile_id)], Retro.TEAL)
	npc.greet(tile_id, color)


## Make a player active on a tile (normally via register + 4 presses).
func join(tile_id: int, player := "", age := 0, player_id := 0) -> void:
	if not game.accepting_players():
		push_warning("join %s: the game is not open (%s)" % [player, game.mode_name()])
		return
	if not is_enabled(tile_id):
		push_warning("join %s: tile %d is out of service" % [player, tile_id])
		return
	var tile := tiles[tile_id - 1]
	_players[tile_id] = {"name": player if player != "" else "Speler %d" % tile_id, "age": age,
		"player_id": player_id}
	rt(tile).revive(game.lives_for(tile_id))
	tile.idle = false
	set_cable_flow(tile_id, cable_color)
	game.on_players_changed()


## After a crash (Recovery): a player back on their tile as they were - no
## invite, no greeting; the game calls on_players_changed once afterwards.
func restore_player(tile_id: int, player: String, age: int, player_id: int, lives: int, max_lives: int) -> void:
	var tile := tiles[tile_id - 1]
	_players[tile_id] = {"name": player, "age": age, "player_id": player_id}
	rt(tile).revive(max_lives)
	tile.health = clampi(lives, 0, CyberTile.HEART_COUNT)
	tile.idle = false
	set_cable_flow(tile_id, cable_color)


## After a crash: an invite waiting for its player again (a fresh time to activate).
func restore_invite(tile_id: int, player: String, color: Color, age: int, player_id: int) -> void:
	var tile := tiles[tile_id - 1]
	_pending[tile_id] = {"name": player, "color": color, "age": age, "player_id": player_id,
		"time_left": activation_timeout}
	rt(tile).start_activation(color)
	set_cable_flow(tile_id, color, 0.5)


## The player leaves: back to the idle animation, view removed from the screen.
func leave(tile_id: int) -> void:
	_hits_on_way.erase(tile_id)
	if _pending.has(tile_id) or _players.has(tile_id):
		cue(&"leave", tile_id)
	if _pending.erase(tile_id):
		tiles[tile_id - 1].idle = true
		set_cable_flow(tile_id, cable_color, 0.15)
		game.on_players_changed()
	if not _players.has(tile_id):
		return
	game.on_player_left(tile_id)         # saves their result while name/score are known
	_players.erase(tile_id)
	var tile := tiles[tile_id - 1]
	tile.is_dead = false
	tile.idle = true
	set_cable_flow(tile_id, cable_color, 0.15)
	game.on_players_changed()


# ---------------------------------------------------------------- attacks

## Combined attack of all players who got it right (1-13 at once): green
## sweeps over their tiles, packets run down their cables together, and the
## robot takes one combined hit when they arrive. everyone = all players were
## right: the robot plays its special overload animation.
func players_attack(tile_ids: Array, everyone := false, color := Color(0.2, 1.0, 0.3)) -> void:
	if tile_ids.is_empty():
		return
	if everyone:
		game.log_event("IEDEREEN JUIST - OVERLOAD!", Retro.GOOD)
	elif tile_ids.size() > 1:
		game.log_event("%d SPELERS RAKEN DE ROBOT" % tile_ids.size(), Retro.GOOD)
	npc.players_attack(tile_ids, everyone, color)


## The other way around (e.g. wrong answers), also combined: the robot charges
## the sides facing all targets at once and fires red packets down their cables
## together; every target is hit and loses a life when its packet arrives.
## Targets in shielded (e.g. the question was too hard for their age) are shot
## at too, but their shield blocks it and bounces the packet back: no life lost.
## damage = false: only the animation (e.g. a wrong quiz answer: the lives
## change at the end of the round).
func robot_attack(tile_ids: Array, color := Color(1.0, 0.1, 0.05), shielded: Array = [], damage := true) -> void:
	var targets := tile_ids + shielded
	if targets.is_empty():
		return
	# max 1 life per round, decided now: the hit may land after the round ended
	var costs_life := tile_ids.filter(func(id): return game.take_life(id)) if damage else []
	for id in costs_life:
		_hits_on_way[id] = _hits_on_way.get(id, 0) + 1
	_attacks += 1
	await npc.attack(targets, color, shielded,
		func(): cue(&"charge", 0, {"tiles": targets.duplicate()}),
		func():
			cue(&"attack", 0, {"tiles": targets.duplicate()})   # the bolts leave the robot
			get_tree().create_timer(3.0).timeout.connect(func(): _attacks -= 1)   # (the shots land in ~1-2 s)
			if not tile_ids.is_empty():
				game.log_event("ROBOT RAAKT " + ", ".join(tile_ids.map(func(id): return player_name(id).to_upper())), Retro.BAD)
			for id in shielded:
				game.log_event("SCHILD BESCHERMT %s" % player_name(id).to_upper(), Retro.SHIELD),
		func(id: int, blocked: bool):                  # the shot landed (the tile's hit / block: the npc)
			if blocked:
				cue(&"shield", id)
			else:
				cue(&"hit", id)
				if id in costs_life:
					_hits_on_way[id] = maxi(_hits_on_way.get(id, 0) - 1, 0)
					tiles[id - 1].health -= 1
				elif damage:                    # max 1 life per round: this hit is free
					screen_wall.popup(id, "♥ VEILIG", CyberTile.SHIELD_COLOR))


## Length of the death clip in s (to time the free tile; 4 without a clip).
func death_clip_length() -> float:
	if _clip_length.has(death_clip):
		return _clip_length[death_clip]
	var length := 0.0
	if ResourceLoader.exists(death_clip):
		var p := VideoStreamPlayer.new()
		p.stream = load(death_clip)
		length = p.get_stream_length()
		p.free()
	_clip_length[death_clip] = length if length > 0.0 else 4.0
	return _clip_length[death_clip]


## The death clip of this tile still has to be shown (waiting for the split
## view, at most clip_wait s) or is on screen (the clip, at least clip_time s).
const DEATH_ANIMATION := 3.6           # s: the tile's / drone's death animation after the shot lands

## An exterminated player's tile: seconds until it is free again (the death
## animation, free_delay, and their death clip in their view), -1 while the
## robot has not fired yet, 0 = not in the extermination. For the gamemasters
## (state "dying"): when a tile comes free.
func free_in(tile_id: int) -> float:
	if dying.has(tile_id) and int(dying[tile_id]) == 0:
		return -1.0
	var left := 0.0
	if dying.has(tile_id):
		left = DEATH_ANIMATION + free_delay - (Time.get_ticks_msec() - int(dying[tile_id])) / 1000.0
	var clip := maxf(death_clip_length(), clip_time)
	if clip_started.has(tile_id):
		left = maxf(left, clip - (clock - float(clip_started[tile_id])))
	elif clip_waiting.has(tile_id) or dying.has(tile_id):
		left = maxf(left, clip)                  # (the clip starts once their view is on screen)
	return maxf(left, 0.01) if (dying.has(tile_id) or death_clip_pending(tile_id)) else 0.0


func death_clip_pending(tile_id: int) -> bool:
	if clip_started.has(tile_id):
		return clock - float(clip_started[tile_id]) < maxf(death_clip_length(), clip_time)
	return clip_waiting.has(tile_id) and clock - float(clip_waiting[tile_id]) < clip_wait


## The end of a round: these players will be exterminated (their lives reach 0
## on the scoreboard). The robot already turns to the first one and waits.
func aim_at_doomed(tile_ids: Array) -> void:
	if not tile_ids.is_empty():
		npc.aim(int(tile_ids[0]))


## The exterminations of a round, all at once (the scoreboard shows them):
## every doomed tile blinks red, the robot fires at the first, and while its
## death animation plays it turns to the next one, and so on (CyberRobot's
## death queue). Nothing waits for it: the game goes on, this runs on top.
func exterminate(tile_ids: Array) -> void:
	var any := false
	for id in tile_ids:
		if is_playing(id) and not tiles[id - 1].is_dead:
			game.take_life(id)
			tiles[id - 1].health = 0          # -> died -> _on_tile_died (queued on the robot)
			any = true
	if not any and not tile_ids.is_empty():
		npc.release()                         # (aimed, but they left in the meantime)


## An attack under way or a shot on its way (the scoreboard waits for it).
func attacks_busy() -> bool:
	return _attacks > 0 or _hits_on_way.values().any(func(n): return n > 0)


## The lives a player will have once the robot's shots on the way have landed
## (the scoreboard can appear before the hit).
func lives_after_hits(tile_id: int) -> int:
	return maxi(tiles[tile_id - 1].health - _hits_on_way.get(tile_id, 0), 0)


## Reward: one life more (max the 5 hearts on the tile), with a green flash.
func give_life(tile_id: int) -> void:
	var tile := tiles[tile_id - 1]
	if tile.is_dead or tile.health >= CyberTile.HEART_COUNT:
		return
	tile.max_health = maxi(tile.max_health, tile.health + 1)
	tile.health += 1
	tile.fx.emit(tile_id, "life", Color(0.1, 1.0, 0.3))
	cue(&"life", tile_id)
	rt(tile).fill_ring(Color(0.1, 1.0, 0.3))
	get_tree().create_timer(0.5).timeout.connect(func():
		if not tile.idle and not tile.is_dead:
			rt(tile).clear_ring())
	get_tree().create_timer(1.2).timeout.connect(func():   # after the place popup
		screen_wall.popup(tile_id, "+1 ♥", Retro.GOOD))


## Send a message to a tile's own controller (programs, start, stop).
## The press being handled now came from a tile with a time stamp
## ({"t": ms since the program's start, "program": id}); {} = none (a simulated
## tile, an old firmware): the round uses the moment it arrived.
func press_stamp() -> Dictionary:
	return _press_stamp


var _press_stamp := {}


func send_to_tile(tile_id: int, msg: Dictionary) -> void:
	Replica.relay("arena", &"replica_tile_msg", [tile_id, msg])   # (the display nodes run the tile logic too: it shows)
	tile_message.emit(tile_id, msg)
	if simulate_firmware:
		(tiles[tile_id - 1].get_node("Firmware") as TileFirmware).receive(msg)


# ---------------------------------------------------------------- cable lights

## The robot side (0-12) facing a player: a floor tile's own side, for a
## drone the side it is flying in front of now.
func robot_side(tile_id: int) -> int:
	var tile := tiles[tile_id - 1]
	if tile is DroneTile:
		var p := robot.to_local(tile.global_position)
		return CyberRobot.nearest_side(atan2(-p.x, -p.z))
	return tile_id - 1


## Send a light packet along a tile's cable; on_arrive is called at the end.
## to_robot = false: from the robot to the tile. A drone has no cable: a bolt
## flies through the air.
func send_packet(tile_id: int, color: Color, on_arrive := Callable(), to_robot := true) -> void:
	Replica.relay("arena", &"replica_packet", [tile_id, color, to_robot])
	packet(tile_id, color, on_arrive, to_robot)


## The same, here only (RobotNpc: its choreography runs on every node).
func packet(tile_id: int, color: Color, on_arrive := Callable(), to_robot := true) -> void:
	if tiles[tile_id - 1] is DroneTile:
		(tiles[tile_id - 1] as DroneTile).send_bolt(color, to_robot, on_arrive)
		return
	_packets.append({"tile": tile_id, "pos": 0.0, "color": color, "on_arrive": on_arrive,
		"to_robot": to_robot})


## Idle flow on one cable (e.g. dark red for a dead player).
func set_cable_flow(tile_id: int, color: Color, strength := 0.5) -> void:
	if tile_id > _cable_mats.size():           # (a drone: no cable)
		return
	Replica.relay("arena", &"set_cable_flow", [tile_id, color, strength])
	var mat := _cable_mats[tile_id - 1]
	mat.set_shader_parameter("flow_color", color)
	mat.set_shader_parameter("idle_strength", strength)


func _update_packets(delta: float) -> void:
	for p in _packets:
		p.pos += delta * packet_speed
	for p in _packets.filter(func(p): return p.pos >= 1.0):
		_packets.erase(p)
		if p.on_arrive.is_valid():
			p.on_arrive.call()
	for i in _cable_mats.size():
		var slots := Vector4(-1, -1, -1, -1)
		var dirs := Vector4(1, 1, 1, 1)
		var n := 0
		var color := Color.WHITE
		for p in _packets:
			if p.tile == i + 1 and n < 4:
				slots[n] = p.pos if p.to_robot else 1.0 - p.pos
				dirs[n] = 1.0 if p.to_robot else -1.0
				color = p.color
				n += 1
		_cable_mats[i].set_shader_parameter("packets", slots)
		_cable_mats[i].set_shader_parameter("packet_dirs", dirs)
		_cable_mats[i].set_shader_parameter("packet_color", color)


## Settings from the command line (after "--"), so the installation can be
## started without the editor, e.g.
##   godot-4 --path godot -- --windows --mqtt=ws://broker:9001/mqtt --db=/srv/cc/cybercircle.db
##   --windows            the 5 screens (+ overview) as full-screen windows on their monitors
##   --screens=1,2,3/4,5,6/7,8,9/10,11/12,13   which tiles each screen shows ("/" between screens)
##   --mobile-screens=14,15/16,17,18            the same for the mobile players' screens (drones)
##   --monitors=0,1,2,3,4,5                     monitor of screen 1, 2, ... and then the overview
##   --preview            all screens in one window (default)
##   --no-overview        no overview page for visitors
##   --mqtt=URL           MQTT over WebSocket ("" / not given: no MQTT, tiles simulated)
##   --mqtt-user=NAME --mqtt-password=SECRET
##   --sim-tiles          with MQTT: still simulate the tile logic in the twin
##   --node=NAME          this process' name in the web interface (default godot-<ip>)
##   --demo[=N]           N (default 6) bot players keep the game going (showing it without visitors)
##   --demo-idle=S        the bots only walk up after S seconds (the game idles until then)
##   --rounds=quiz,simon  only these round types (cyclone, quiz, reaction, rhythm, simon, zwarte_piet)
##   --texts=FILE         texts (JSON, see Texts): {"cta": "...", "rules.quiz": "...", ...}
##   --control=URL        the control server (installation): questions, players and scores
##                        through its HTTP API, e.g. --control=http://192.168.1.10:8080
##   --ca=FILE            trust this CA for wss:// and https:// (the installation's own, deploy/certs/ca.pem)
##   --no-restore         after a crash: a fresh start (default: back where it was, see Recovery)
##   --restore-max-age=S  an older checkpoint is a previous day's game (default 3600)
##   --db=PATH            standalone: the SQLite file itself ("none": no database)
##   --no-sound           no sound effects
##   --sounds=DIR         extra sound files: DIR/<event>/*.ogg (see SoundBoard)
##   --settings=FILE      game settings (JSON, as the web interface's "Instellingen"):
##                        {"game": {"tempo": 1.2}, "quiz": {"question_time": 20}, ...}
##   --serve-replicas[=7350]  the master: display nodes (Pis) follow this game (Replica, UDP)
##   --remote-screens=1-7|all the screens the display nodes show: not rendered here
##   a display node (a Pi): --replica --show=1,2 [--master=HOST[:7350]] [--monitors=0,1]
##                        [--mqtt=... (only its own tiles, read-only)] [--windowed]
##                        [--view-scale=0.75 --msaa=2 --detail=3 --detail-size=0.2 --lod=4]
func _apply_command_line() -> void:
	var mqtt: MqttBridge = $Mqtt
	var remote := ""
	for a in OS.get_cmdline_user_args():
		var key := a.get_slice("=", 0)
		var value := a.substr(key.length() + 1) if "=" in a else ""
		match key:
			"--windows":
				screen_wall.multi_window = true
			"--preview":
				screen_wall.multi_window = false
			"--no-overview":
				screen_wall.observer_page = false
			"--screens":
				screen_wall.screen_groups = _parse_screens(value, false)
			"--installed":                                 # standalone: only these places, e.g. 1-7,14-18
				var ids := []
				for part in value.split(",", false):
					var ab := part.split("-")
					for id in range(int(ab[0]), int(ab[-1]) + 1):
						ids.append(id)
				set_installed.call_deferred(ids)
			"--mobile-screens":
				screen_wall.mobile_groups = _parse_screens(value, true)
			"--monitors":
				screen_wall.monitors = Array(value.split(",", false)).map(func(v): return int(v))
			"--serve-replicas", "--serve-displays":        # the display nodes follow this game (Replica)
				if replica == null:
					replica = Replica.new()
				if value != "":
					replica.port = int(value)
				mqtt.display_port = replica.port
			"--remote-screens":                            # rendered by display nodes, not here: 1,2,5-7 / all
				remote = value
			"--replica", "--display":                      # this is a display node: no game, it follows the master
				if replica == null:
					replica = Replica.new()
				Replica.client = true
				mqtt.role = "display"
			"--show":                                      # a display node: the screens it shows, e.g. 1,2
				replica_screens = _parse_list(value, 99)
			"--master":                                    # a display node: the master (default: its beacon)
				if replica == null:
					replica = Replica.new()
				replica.master_host = value.get_slice(":", 0)
				if ":" in value:
					replica.port = int(value.get_slice(":", 1))
			"--view-scale", "--msaa", "--detail", "--detail-size", "--lod":   # a display node's 3D views
				replica_view[key.trim_prefix("--").replace("-", "_")] = float(value)
			"--windowed":                                  # a display node: windows instead of full screen
				screen_wall.windowed = true
			"--shots":                                     # tests: a display node saves its screens at each mark
				replica_shots = value
			"--mqtt":
				mqtt.url = value
			"--mqtt-user":
				mqtt.username = value
			"--mqtt-password":
				mqtt.password = value
			"--sim-tiles":
				mqtt.real_tiles = false
			"--node":
				mqtt.node_id = value
			"--advertise":                                 # the address the displays connect to
				mqtt.advertise = value
			"--rounds":
				var types := []
				for n in value.split(",", false):
					var t: Script = game._round_type(n.strip_edges())
					if t:
						types.append(t)
					else:
						push_warning("--rounds: unknown round type %s" % n)
				if not types.is_empty():
					game.round_types = types
			"--demo":
				var bots := DemoBots.new()
				bots.name = "DemoBots"
				bots.arena = self
				if value != "":
					bots.players = clampi(int(value), 0, tiles.size())
				bots.ready.connect(func(): bots._next_join = _demo_idle)
				add_child.call_deferred(bots)
			"--demo-idle":
				_demo_idle = float(value)
			"--db":
				game.db_path = "" if value == "none" else value
			"--control":
				game.control_url = value
			"--ca":
				TlsTrust.load_ca(value)
			"--no-restore":
				game.restore = false
			"--restore-max-age":
				game.restore_max_age = float(value)
			"--texts":                                     # the operator's texts as JSON (Texts)
				var t = JSON.parse_string(FileAccess.get_file_as_string(value))
				if t is Dictionary:
					Texts.apply(t)
				else:
					push_warning("--texts: no JSON object in %s" % value)
			"--no-sound":
				sound.enabled = false
			"--sounds":
				sound.extra_dir = value
			"--voice":                                     # prebaked speech outside the project
				narrator.extra_dir = value
			"--voice-export":                              # the lines to record, as CSV; then quit
				_voice_export = value
			"--settings":
				var data = JSON.parse_string(FileAccess.get_file_as_string(value))
				if data is Dictionary:
					game.apply_settings.call_deferred(data)    # (after game.setup: the defaults)
				else:
					push_warning("--settings: cannot read %s" % value)
			_:
				push_warning("unknown option %s" % a)
	var count := screen_wall.screen_groups.size() + screen_wall.mobile_groups.size()
	if remote != "":                                       # (after --screens / --mobile-screens)
		screen_wall.remote_screens = _parse_list(remote, count)
	if Replica.client:                                     # a display node: only its own screens, no overview
		if replica_screens.is_empty():
			replica_screens = [1]
		screen_wall.remote_screens = range(1, count + 1).filter(func(k): return k not in replica_screens)
		screen_wall.observer_page = false
		screen_wall.multi_window = true
		screen_wall.monitors = _replica_monitors(screen_wall.monitors, count)
		game.restore = false
		game.db_path = ""


## A display node's --monitors lists the monitor of each screen it shows (in
## order); ScreenWall counts per screen number: spread them out.
func _replica_monitors(given: Array, count: int) -> Array:
	var out := []
	out.resize(count + 1)
	out.fill(0)
	for i in replica_screens.size():
		var k: int = int(replica_screens[i])
		if k >= 1 and k <= count:
			out[k - 1] = int(given[i]) if i < given.size() else i
	return out


## "1,2,5-7" -> [1, 2, 5, 6, 7]; "all" -> 1 .. count.
static func _parse_list(text: String, count: int) -> Array:
	if text.strip_edges() == "all":
		return range(1, count + 1)
	var out := []
	for part in text.split(",", false):
		var ab := part.split("-")
		for v in range(int(ab[0]), int(ab[-1]) + 1):
			if v not in out:
				out.append(v)
	return out


## "1,2,3/4,5,6/..." -> [[1, 2, 3], [4, 5, 6], ...]; warns about tiles that are
## missing or on two screens.
func _parse_screens(text: String, mobile: bool) -> Array:
	var groups := []
	var seen := {}
	for part in text.split("/", false):
		var ids := []
		for v in part.split(",", false):
			var id := int(v)
			if id < 1 or id > tiles.size():
				push_warning("--screens: there is no tile %s" % v)
				continue
			if seen.has(id):
				push_warning("--screens: tile %d is on two screens" % id)
			seen[id] = true
			ids.append(id)
		groups.append(ids)
	for t in tiles:
		if not seen.has(t.tile_id) and (t is DroneTile) == mobile:
			push_warning("--screens: tile %d is on no screen" % t.tile_id)
	return groups


func _process(delta: float) -> void:
	clock += delta
	Retro.game_clock = clock
	_update_packets(delta)
	if Replica.client:
		return                                   # (the master decides when an invite runs out)
	for id in _pending.keys():  # registrations that were never activated
		_pending[id].time_left -= delta
		if _pending[id].time_left <= 0.0:
			leave(id)


func _on_button_pressed(tile_id: int, button: StringName) -> void:
	var tile := tiles[tile_id - 1]
	if Replica.client:                           # a display: show the press at once (the master decides)
		if is_pending(tile_id):
			tile.activation_press(button)
		elif own_tiles_live and is_own_tile(tile_id) and not tile.idle:
			npc.press(tile_id, CyberTile.BUTTON_COLORS[button])   # (its own tiles: from MQTT, at once)
		return
	if is_pending(tile_id):  # activation: press all 4 icons
		if tile.activation_press(button):
			_activate(tile_id)
		return
	if tile.idle:  # nobody registered on this tile
		return
	var color: Color = CyberTile.BUTTON_COLORS[button]
	# the press travels down the cable; the robot looks at the player when it arrives
	npc.press(tile_id, color)
	game.on_button(tile_id, button)


## Last life lost: queue the robot's death animation; the tile plays its effect
## when the shot lands. Several tiles can die at the same moment.
## 0 lives: exterminated. The tile blinks red until the robot has turned to
## it and fired; then the death animation plays on the tile and the death clip
## in the player's view, after which the player leaves and the tile is free.
func _on_tile_died(tile_id: int) -> void:
	if Replica.client:
		return                                   # (the master runs the extermination; it comes as events)
	var tile := tiles[tile_id - 1]
	var who := player_name(tile_id)
	game.log_event("%s IS GEËXTERMINEERD!" % who.to_upper(), Retro.BAD)
	cue(&"death", tile_id, {"player": who})
	dying[tile_id] = 0
	if dying.size() == 1:                        # the overview drifts over to watch
		observer.focus(tile.global_position, 9.0)
	else:                                        # several: a wide view on the robot
		observer.focus(Vector3.ZERO, 9.0 + dying.size() * 1.5)
	npc.doom(tile_id, func():                       # the shot landed
			set_cable_flow(tile_id, Color(0.6, 0.0, 0.0), 0.25)
			_death_sounds(tile_id)
			dying[tile_id] = Time.get_ticks_msec()
			exterminated.emit(tile_id, who)
			clip_waiting[tile_id] = clock
			screen_wall.play_death_clips()             # their movie, from the start, once their split view shows
			Replica.relay("wall", &"play_death_clips", []),
		func():                                        # the tile's death animation is over
			await get_tree().create_timer(free_delay).timeout
			dying.erase(tile_id)
			while death_clip_pending(tile_id):         # the tile stays theirs until they have seen it
				await get_tree().process_frame
			clip_waiting.erase(tile_id)
			clip_started.erase(tile_id)
			if player_name(tile_id) == who:            # still the same player
				leave(tile_id)
				game.log_event("%s IS WEER VRIJ" % Retro.tile_label(tile_id), Retro.DIM))


## The tile's death (CyberTile.play_death): 1 s electrocution, then the explosion.
func _death_sounds(tile_id: int) -> void:
	cue(&"zap", tile_id)
	get_tree().create_timer(1.0).timeout.connect(func(): cue(&"explosion", tile_id))


## --voice-export=FILE: every line the narrator can say, as CSV; then quit
## (waits a moment for the questions from the control server).
func _export_voice() -> void:
	for i in 50:                                   # (the control server's list, not the JSON fallback)
		if game.db == null or not game.db.questions().is_empty():
			break
		await get_tree().create_timer(0.2).timeout
	var n := Narrator.export_csv(game, _voice_export)
	print("voice: %d lines written to %s" % [n, _voice_export])
	get_tree().quit()


## {"stream": {"tile": 3, "on": true, "url": "rtsp://...", "fps": 15, "encoder": "auto"}}:
## start / keep alive / stop the video of that player's screen (CompanionStream).
## Nothing exists until one is asked for.
func _stream_command(s: Dictionary) -> void:
	var id := int(s.get("tile", 0))
	if id < 1 or id > tiles.size():
		return
	var cs: CompanionStream = _streams.get(id)
	if not bool(s.get("on", true)):
		if is_instance_valid(cs):
			cs.stop("asked")
			cs.queue_free()
		_streams.erase(id)
		return
	if is_instance_valid(cs):
		cs.keep_alive()
		return
	cs = CompanionStream.new()
	cs.name = "Stream_%d" % id
	cs.arena = self
	cs.tile_id = id
	cs.configure(s)
	cs.state_changed.connect(func(t, on, info):
		if not on:
			_streams.erase(t)
		stream_changed.emit(t, on, info))
	_streams[id] = cs
	add_child(cs)
	cs.start()


## What a game moment means for the player it happens to (Narrator.say_to).
const PERSONAL := {
	&"hit": "Geraakt!", &"shield": "Je schild houdt de aanval tegen.", &"life": "Je krijgt er een leven bij.",
	&"death": "Je bent geëxtermineerd.", &"join": "Je doet mee. Je speelt vanaf de volgende ronde.",
	&"leave": "Je bent uit het spel.",
}


## A game moment: its sound (SoundBoard: data/sounds/<event>/, if there is
## one) and its light cue (the virtual lights, and MQTT light/event for the
## real ones). tile_id > 0: at that tile (adds "tile" and "angle", in degrees
## clockwise from T01 seen from above).
func cue(event: StringName, tile_id := 0, data := {}) -> void:
	if Replica.client:
		return                                   # (a display node: the master's sounds and light cues come to it)
	sound.play(event)
	var d := data.duplicate()
	if tile_id > 0 and tile_id <= tiles.size():
		d["tile"] = tile_id
		d["angle"] = snappedf(LightDirector.angle_of(tiles[tile_id - 1].global_position), 0.1)
	lights.on_cue(event, d)
	Replica.relay("lights", &"on_cue", [event, d])
	light_cue.emit(event, d)
	if tile_id > 0 and PERSONAL.has(event):                # the player's own line (accessible page)
		narrator.say_to(tile_id, String(event), PERSONAL[event])


## Operator / demo keys: S = start game, N = next phase,
## R = simulate a QR registration on a random free tile (then click its 4 icons),
## J = random tile joins directly, L = random player leaves,
## F = fire the plunger at a random tile, K = kill 3 random players, O = door.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
		npc.command({"robot": "fire", "tile": randi() % tiles.size() + 1})
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		var free := tiles.filter(func(t): return t.idle and not is_pending(t.tile_id))
		if not free.is_empty():
			var t: CyberTile = free.pick_random()
			register(t.tile_id, "Speler %d" % t.tile_id, Color.from_hsv(randf(), 0.8, 1.0))
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_J:
		var free := tiles.filter(func(t): return t.idle)
		if not free.is_empty():
			join(free.pick_random().tile_id)
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_L:
		if not _players.is_empty():
			leave(_players.keys().pick_random())
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_S:
		game.start_game()
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_N:
		game.skip()
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_O:
		room.toggle_door()
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_K:
		var alive := tiles.filter(func(t): return not t.is_dead and not t.idle)
		alive.shuffle()
		for t in alive.slice(0, 3):
			t.health = 0


## Shot landed: flash the ring of the tile that was hit.
func _on_robot_hit(target: Vector3) -> void:
	for tile in tiles:
		if tile.is_dead or tile.idle:
			continue
		if Vector2(tile.global_position.x, tile.global_position.z).distance_to(Vector2(target.x, target.z)) < 0.4:
			for i in 3:                              # (the robot's own hit: on every node by itself)
				tile.fill_ring(Color.RED)
				await get_tree().create_timer(0.1).timeout
				tile.clear_ring()
				await get_tree().create_timer(0.1).timeout


## Single entry point for state coming from the real installation.
func apply_command(cmd: Dictionary) -> void:
	if cmd.get("stream") is Dictionary:       # a companion video stream of one player's screen
		_stream_command(cmd.stream)
		return
	if cmd.has("sound"):     # external trigger (web interface, show control, ...)
		if not sound.play_external(StringName(str(cmd.sound)), str(cmd.get("file", "")), int(cmd.get("volume", -1))):
			push_warning("sound: no sound %s %s" % [cmd.sound, cmd.get("file", "")])
		return
	if cmd.get("sound_stop", false):
		sound.stop_all()
		return
	if cmd.get("sound_reload", false):
		sound.reload()
		return
	if cmd.get("attack") is Array:
		players_attack(cmd.attack.map(func(v): return int(v)), bool(cmd.get("everyone", false)))
		return
	if cmd.get("attacked") is Array:
		robot_attack(cmd.attacked.map(func(v): return int(v)))
		return
	if cmd.has("assign"):    # the app put the player in the database: {"assign": id, "tile"?: n}
		assign(int(cmd.assign), int(cmd.get("tile", 0)), Color(cmd.color) if cmd.has("color") else null,
			bool(cmd.get("mobile", false)))
		return
	if cmd.has("register"):  # QR scan: {"register": name, "color": "#rrggbb", "tile"?: n}
		register(int(cmd.get("tile", 0)), str(cmd.register), Color(cmd.get("color", "#ffcc1a")),
			int(cmd.get("age", 0)), 0, bool(cmd.get("mobile", false)))
		return
	if cmd.has("tile") and not cmd.has("robot"):
		var tile := tiles[int(cmd.tile) - 1]
		if cmd.has("attack"):
			players_attack([int(cmd.tile)])
		if cmd.has("attacked"):
			robot_attack([int(cmd.tile)])
		if cmd.has("join"):
			join(int(cmd.tile), str(cmd.join), int(cmd.get("age", 0)))
		if cmd.has("leave"):
			leave(int(cmd.tile))
		if cmd.has("enabled"):
			set_tile_enabled(int(cmd.tile), bool(cmd.enabled))
		if cmd.has("points") and is_playing(int(cmd.tile)):      # operator: round points + / -
			var n := int(cmd.points)
			if game.current and game.current.points.has(int(cmd.tile)):
				game.current.add_points(int(cmd.tile), n)
			else:
				game.add_score(int(cmd.tile), n)
			screen_wall.popup(int(cmd.tile), "%+d" % n, Retro.GOOD if n > 0 else Retro.BAD)
		if cmd.has("revive"):
			rt(tile).revive()
			set_cable_flow(int(cmd.tile), cable_color)
		if cmd.has("health"):
			tile.health = int(cmd.health)
		if cmd.has("ring"):
			rt(tile).set_ring(cmd.ring.map(func(c): return Color(c)))
		if cmd.has("led"):
			rt(tile).set_ring_led(int(cmd.led), Color(cmd.color))
		if cmd.has("press"):
			_press_stamp = cmd if cmd.has("t") else {}    # (a real tile's time stamp: the round reads it now)
			rt(tile).press_button(StringName(cmd.press))
			_press_stamp = {}
		if cmd.has("pressure"):
			for b in cmd.pressure:
				tile.set_pressure(StringName(b), float(cmd.pressure[b]))
		if cmd.has("button_led"):
			rt(tile).set_button_led(StringName(cmd.button_led), Color(cmd.color))
		if cmd.get("result") is Dictionary:
			game.on_result(int(cmd.tile), cmd.result)
	match cmd.get("game", ""):
		"start":
			game.start_game()
		"next":
			game.skip()
		"boot", "shutdown":                      # the robot's show, without changing the mode (a test)
			game.play_power_show(str(cmd.game))
		"stop":
			game.stop_game()
		"plan":                     # {"game": "plan", "slot": 0, "round": "simon"} ("" = random)
			game.set_planned_round(int(cmd.get("slot", 0)), str(cmd.get("round", "")), cmd.get("options", {}))
		"plan_random":
			game.clear_planned_rounds()
		"mode":                     # {"game": "mode", "mode": "setup" | "closed" | "open" | "paused"}
			var m := GameManager.Mode.keys().find(str(cmd.get("mode", "")).to_upper())
			if m >= 0:
				game.set_mode(m)
	match cmd.get("room", ""):
		"door":
			if cmd.get("open", true):
				room.open_door()
			else:
				room.close_door()
		"light":
			room.set_ring_color(Color(cmd.color))
	match cmd.get("robot", ""):
		"":
			pass
		"spin":
			npc.command({"robot": "spin", "speed": float(cmd.get("speed", 30.0))})
			npc.release()
		"death":  # {"tile": 3} or {"tiles": [1, 5, 9]}
			var ids: Array = cmd.get("tiles", [cmd.get("tile", 1)])
			for id in ids:
				var tid := int(id)
				tiles[tid - 1].is_dead = true
				npc.doom(tid, func():
					_death_sounds(tid)
					set_cable_flow(tid, Color(0.6, 0.0, 0.0), 0.25))
		_:                                       # the operator's commands: the npc obeys them (everywhere)
			npc.command(cmd)
