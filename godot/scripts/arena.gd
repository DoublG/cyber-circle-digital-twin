extends Node3D
## The player area (scenes/arena.tscn): robot in the middle, 13 tiles around it,
## connected to the robot by cable ducts (models/arena_floor.glb). Everything is
## placed in the scene, so you can see and edit it in the Godot editor.
## Tile_01 stands in front of robot side 0 (-Z), then clockwise seen from above,
## 2.5 m from the robot centre (matches ARENA_R in blender/build_models.py).
## The camera "Camera" is the fixed overview of the room, looking at the robot.
##
## Multiplayer: up to 13 players, one per tile. Joining is done by the external
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
##                       (QR scan; without "tile" a free tile is chosen; "age" is
##                        optional and protects young players from too hard questions)
##   {"assign": 42, "tile": 3}  (player 42 from the database, put there by the app;
##                        name, colour and age are read from it; "tile" optional)
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
##   {"game": "start"} / {"game": "next"} / {"game": "stop"}
##   {"game": "plan", "slot": 0, "round": "quiz", "options": {"categories": ["Computers"]}}
##                                                    (operator: the next round(s); "" = random)
##   {"game": "plan_random"}                          (plan the next rounds at random again)
##   {"room": "door", "open": true}
##   {"room": "light", "color": "#b0d0ff"}               (ceiling ring light)
##   {"tile": 3, "result": {...}}       (result of the tile's own logic, see TileFirmware)
##
## Messages to the tiles go through send_to_tile() / the tile_message signal
## (programs for rounds the tile runs itself). simulate_firmware = true runs
## that tile logic in the twin; with the real tiles connected (MqttBridge)
## set it to false.

@export var packet_speed := 1.6        # cable lengths per second (tile -> robot)
@export var cable_color := Color(0.15, 0.5, 1.0)
@export var activation_timeout := 60.0  # seconds to press all 4 icons after the QR scan
@export var free_delay := 1.5           # s after the death animation before the tile is free again
@export_file("*.ogv") var death_clip := "res://data/videos/exterminate.ogv"  # in the player's view
@export var clip_wait := 30.0           # s the death clip waits for the player's split view (then dropped)
@export var clip_time := 8.0            # s the death screen stays (a shorter clip holds its last frame)
@export var simulate_firmware := true  # run the tiles' own logic in the twin (no real tiles)

const CABLE_SHADER := preload("res://shaders/cable_flow.gdshader")

@onready var robot: CyberRobot = $Robot
@onready var room: SpaceshipRoom = $Room
@onready var screen_wall: ScreenWall = $ScreenWall
@onready var game: GameManager = $Game
var observer: ObserverRig          # floating camera for the overview page (visitors)
var sound := SoundBoard.new()      # sound effects for the game events
var tiles: Array[CyberTile] = []
var _cable_mats: Array[ShaderMaterial] = []   # index = tile_id - 1
var _packets: Array[Dictionary] = []          # {tile, pos, color, on_arrive}
signal registered(tile_id: int, player: String, color: Color)  # e.g. to tell the app the tile
signal activated(tile_id: int, player: String)
signal exterminated(tile_id: int, player: String)   # the robot's shot hit: the death animation starts
signal tile_message(tile_id: int, msg: Dictionary)  # to the real tile (e.g. via MQTT)

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


func _ready() -> void:
	robot.hit.connect(_on_robot_hit)
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
		fw.report = apply_command
		tile.add_child(fw)
	var floor_model: Node = $Room if $Room.baked else $Floor   # baked: the floor is part of the room
	if $Room.baked:
		for mi in $Floor.find_children("*", "MeshInstance3D", true, false):
			mi.visible = false                  # (keeps the floor collider)
	for tile in tiles:
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
	robot.fired.connect(func(_to): sound.play(&"attack"))
	activated.connect(func(_id, _who): sound.play(&"join"))
	observer = ObserverRig.new()
	observer.name = "Observer"
	add_child(observer)
	observer.setup(self)
	screen_wall.setup(self)
	game.setup(self)
	($Mqtt as MqttBridge).setup(self)   # no-op while its url is empty


# ---------------------------------------------------------------- players

## In service: the tile can be used in the game (see set_tile_enabled).
func is_enabled(tile_id: int) -> bool:
	return not _disabled.has(tile_id)


## Take a tile out of the game (setup, a broken or swapped tile) or back in.
## A player on it leaves the game (their result is saved).
func set_tile_enabled(tile_id: int, on: bool) -> void:
	if on == is_enabled(tile_id):
		return
	if on:
		_disabled.erase(tile_id)
	else:
		_disabled[tile_id] = true
		leave(tile_id)
	tiles[tile_id - 1].out_of_service = not on
	set_cable_flow(tile_id, cable_color, 0.15 if on else 0.0)
	game.log_event("T%02d %s" % [tile_id, "WEER IN GEBRUIK" if on else "BUITEN GEBRUIK"], Retro.DIM)
	screen_wall.refresh()


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
func assign(player_id: int, tile_id := 0) -> int:
	var p: Dictionary = await game.db.fetch_player(player_id) if game.db else {}
	if p.is_empty():
		push_warning("assign: player %d not in the database" % player_id)
		return 0
	return register(tile_id, p.name, Color(p.color), int(p.age), player_id)


func player_ids() -> Array:
	var ids := _players.keys()
	ids.sort()
	return ids


func is_pending(tile_id: int) -> bool:
	return _pending.has(tile_id)


## Registered but not activated yet: {name, color, age, time_left}, or {}.
func pending_info(tile_id: int) -> Dictionary:
	return _pending.get(tile_id, {})


## Step 1 (from the registration system after a QR scan): the tile lights up
## in the colour shown in the app (so the player can find it) and waits until
## all 4 icons are pressed.
## tile_id <= 0: pick a free tile. Returns the tile id, or 0 if none is free.
## player_id: the player's id in the database (0 = not from the database).
func register(tile_id: int, player: String, color := Color(1.0, 0.8, 0.1), age := 0, player_id := 0) -> int:
	if not game.accepting_players():
		push_warning("register %s: the game is not open (%s)" % [player, game.mode_name()])
		return 0
	if tile_id <= 0:
		var free := tiles.filter(func(t): return t.idle and not is_pending(t.tile_id) and is_enabled(t.tile_id))
		if free.is_empty():
			push_warning("register %s: no free tile" % player)
			return 0
		tile_id = free.pick_random().tile_id
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
	tile.start_activation(color)
	set_cable_flow(tile_id, color, 0.5)
	registered.emit(tile_id, player, color)
	game.log_event("%s SCHRIJFT IN OP T%02d" % [player.to_upper(), tile_id], color)
	game.on_players_changed()       # the screens show the invite on this tile
	return tile_id


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
	game.log_event("%s DOET MEE (T%02d)" % [who.to_upper(), tile_id], Retro.TEAL)
	var tile := tiles[tile_id - 1]
	tile.fill_ring(color)
	get_tree().create_timer(0.6).timeout.connect(func():
		if not tile.idle and not tile.is_dead:
			tile.clear_ring())
	send_packet(tile_id, color, func(): robot.look_at_side(tile_id - 1))


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
	tile.revive(game.lives_for(tile_id))
	tile.idle = false
	set_cable_flow(tile_id, cable_color)
	game.on_players_changed()


## The player leaves: back to the idle animation, view removed from the screen.
func leave(tile_id: int) -> void:
	_hits_on_way.erase(tile_id)
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
	for id in tile_ids:
		tiles[id - 1].play_attack(color)
	if everyone:
		game.log_event("IEDEREEN JUIST - OVERLOAD!", Retro.GOOD)
	elif tile_ids.size() > 1:
		game.log_event("%d SPELERS RAKEN DE ROBOT" % tile_ids.size(), Retro.GOOD)
	await get_tree().create_timer(0.35).timeout  # the sweeps reach the robot side
	var sides := tile_ids.map(func(id): return id - 1)
	var arrived := [0]
	var on_arrive := func():
		arrived[0] += 1
		if arrived[0] < tile_ids.size():
			return
		if everyone:  # last packet in: one combined hit
			robot.play_overload(color, sides)
		else:
			robot.take_hit(sides, color)
	for id in tile_ids:
		send_packet(id, color, on_arrive)


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
	if targets.size() == 1:
		robot.look_at_side(targets[0] - 1)
		while not robot.is_facing_target():
			await get_tree().process_frame
	_attacks += 1
	sound.play(&"charge")
	await robot.charge_attack(targets.map(func(id): return id - 1), color)
	get_tree().create_timer(3.0).timeout.connect(func(): _attacks -= 1)   # (the shots land in ~1-2 s)
	if not tile_ids.is_empty():
		game.log_event("ROBOT RAAKT " + ", ".join(tile_ids.map(func(id): return player_name(id).to_upper())), Retro.BAD)
	for id in shielded:
		game.log_event("SCHILD BESCHERMT %s" % player_name(id).to_upper(), Retro.SHIELD)
	for id in targets:
		var tile := tiles[id - 1]
		var blocked: bool = id in shielded
		var on_arrive := func():
			if blocked:
				sound.play(&"shield")
				tile.play_block(color)
				send_packet(id, CyberTile.SHIELD_COLOR)   # bounced back to the robot
			else:
				sound.play(&"hit")
				tile.play_hit(color)
				if id in costs_life:
					_hits_on_way[id] = maxi(_hits_on_way.get(id, 0) - 1, 0)
					tile.health -= 1
				elif damage:                    # max 1 life per round: this hit is free
					screen_wall.popup(id, "♥ VEILIG", CyberTile.SHIELD_COLOR)
		send_packet(id, color, on_arrive, false)


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
func death_clip_pending(tile_id: int) -> bool:
	if clip_started.has(tile_id):
		return clock - float(clip_started[tile_id]) < maxf(death_clip_length(), clip_time)
	return clip_waiting.has(tile_id) and clock - float(clip_waiting[tile_id]) < clip_wait


## The end of a round: these players will be exterminated (their lives reach 0
## on the scoreboard). The robot already turns to the first one and waits.
func aim_at_doomed(tile_ids: Array) -> void:
	if not tile_ids.is_empty():
		robot.lock_on(int(tile_ids[0]) - 1)


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
		robot.release_head()                  # (aimed, but they left in the meantime)


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
	sound.play(&"life")
	tile.fill_ring(Color(0.1, 1.0, 0.3))
	get_tree().create_timer(0.5).timeout.connect(func():
		if not tile.idle and not tile.is_dead:
			tile.clear_ring())
	get_tree().create_timer(1.2).timeout.connect(func():   # after the place popup
		screen_wall.popup(tile_id, "+1 ♥", Retro.GOOD))


## Send a message to a tile's own controller (programs, start, stop).
func send_to_tile(tile_id: int, msg: Dictionary) -> void:
	tile_message.emit(tile_id, msg)
	if simulate_firmware:
		(tiles[tile_id - 1].get_node("Firmware") as TileFirmware).receive(msg)


# ---------------------------------------------------------------- cable lights

## Send a light packet along a tile's cable; on_arrive is called at the end.
## to_robot = false: from the robot to the tile.
func send_packet(tile_id: int, color: Color, on_arrive := Callable(), to_robot := true) -> void:
	_packets.append({"tile": tile_id, "pos": 0.0, "color": color, "on_arrive": on_arrive,
		"to_robot": to_robot})


## Idle flow on one cable (e.g. dark red for a dead player).
func set_cable_flow(tile_id: int, color: Color, strength := 0.5) -> void:
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
##   --control=URL        the control server (installation): questions, players and scores
##                        through its HTTP API, e.g. --control=http://192.168.1.10:8080
##   --db=PATH            standalone: the SQLite file itself ("none": no database)
##   --no-sound           no sound effects
##   --sounds=DIR         extra sound files: DIR/<event>/*.ogg (see SoundBoard)
##   --settings=FILE      game settings (JSON, as the web interface's "Instellingen"):
##                        {"game": {"tempo": 1.2}, "quiz": {"question_time": 20}, ...}
func _apply_command_line() -> void:
	var mqtt: MqttBridge = $Mqtt
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
				screen_wall.screen_groups = _parse_screens(value)
			"--monitors":
				screen_wall.monitors = Array(value.split(",", false)).map(func(v): return int(v))
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
			"--no-sound":
				sound.enabled = false
			"--sounds":
				sound.extra_dir = value
			"--settings":
				var data = JSON.parse_string(FileAccess.get_file_as_string(value))
				if data is Dictionary:
					game.apply_settings.call_deferred(data)    # (after game.setup: the defaults)
				else:
					push_warning("--settings: cannot read %s" % value)
			_:
				push_warning("unknown option %s" % a)


## "1,2,3/4,5,6/..." -> [[1, 2, 3], [4, 5, 6], ...]; warns about tiles that are
## missing or on two screens.
func _parse_screens(text: String) -> Array:
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
		if not seen.has(t.tile_id):
			push_warning("--screens: tile %d is on no screen" % t.tile_id)
	return groups


func _process(delta: float) -> void:
	clock += delta
	_update_packets(delta)
	for id in _pending.keys():  # registrations that were never activated
		_pending[id].time_left -= delta
		if _pending[id].time_left <= 0.0:
			leave(id)


func _on_button_pressed(tile_id: int, button: StringName) -> void:
	var tile := tiles[tile_id - 1]
	if is_pending(tile_id):  # activation: press all 4 icons
		if tile.activation_press(button):
			_activate(tile_id)
		return
	if tile.idle:  # nobody registered on this tile
		return
	var color: Color = CyberTile.BUTTON_COLORS[button]
	# the press travels down the cable; the robot looks at the player when it arrives
	send_packet(tile_id, color, func(): robot.look_at_side(tile_id - 1))
	game.on_button(tile_id, button)


## Last life lost: queue the robot's death animation; the tile plays its effect
## when the shot lands. Several tiles can die at the same moment.
## 0 lives: exterminated. The tile blinks red until the robot has turned to
## it and fired; then the death animation plays on the tile and the death clip
## in the player's view, after which the player leaves and the tile is free.
func _on_tile_died(tile_id: int) -> void:
	var tile := tiles[tile_id - 1]
	var who := player_name(tile_id)
	game.log_event("%s IS GEËXTERMINEERD!" % who.to_upper(), Retro.BAD)
	sound.play(&"death")
	dying[tile_id] = 0
	if dying.size() == 1:                        # the overview drifts over to watch
		observer.focus(tile.global_position, 9.0)
	else:                                        # several: a wide view on the robot
		observer.focus(Vector3.ZERO, 9.0 + dying.size() * 1.5)
	tile.blink_doomed()
	robot.queue_death(tile_id - 1, tile.global_position + Vector3(0, 0.05, 0), func():
		set_cable_flow(tile_id, Color(0.6, 0.0, 0.0), 0.25)
		_death_sounds()
		dying[tile_id] = Time.get_ticks_msec()
		exterminated.emit(tile_id, who)
		clip_waiting[tile_id] = clock
		screen_wall.play_death_clips()             # their movie, from the start, once their split view shows
		await tile.play_death()
		await get_tree().create_timer(free_delay).timeout
		dying.erase(tile_id)
		while death_clip_pending(tile_id):         # the tile stays theirs until they have seen it
			await get_tree().process_frame
		clip_waiting.erase(tile_id)
		clip_started.erase(tile_id)
		if player_name(tile_id) == who:            # still the same player
			leave(tile_id)
			game.log_event("T%02d IS WEER VRIJ" % tile_id, Retro.DIM))


## The tile's death (CyberTile.play_death): 1 s electrocution, then the explosion.
func _death_sounds() -> void:
	sound.play(&"zap")
	get_tree().create_timer(1.0).timeout.connect(func(): sound.play(&"explosion"))


## Operator / demo keys: S = start game, N = next phase,
## R = simulate a QR registration on a random free tile (then click its 4 icons),
## J = random tile joins directly, L = random player leaves,
## F = fire the plunger at a random tile, K = kill 3 random players, O = door.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
		var tile := tiles[randi() % tiles.size()]
		robot.fire_at(tile.global_position + Vector3(0, 0.05, 0))
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
			for i in 3:
				tile.fill_ring(Color.RED)
				await get_tree().create_timer(0.1).timeout
				tile.clear_ring()
				await get_tree().create_timer(0.1).timeout


## Single entry point for state coming from the real installation.
func apply_command(cmd: Dictionary) -> void:
	if cmd.get("attack") is Array:
		players_attack(cmd.attack.map(func(v): return int(v)), bool(cmd.get("everyone", false)))
		return
	if cmd.get("attacked") is Array:
		robot_attack(cmd.attacked.map(func(v): return int(v)))
		return
	if cmd.has("assign"):    # the app put the player in the database: {"assign": id, "tile"?: n}
		assign(int(cmd.assign), int(cmd.get("tile", 0)))
		return
	if cmd.has("register"):  # QR scan: {"register": name, "color": "#rrggbb", "tile"?: n}
		register(int(cmd.get("tile", 0)), str(cmd.register), Color(cmd.get("color", "#ffcc1a")),
			int(cmd.get("age", 0)))
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
			tile.revive()
			set_cable_flow(int(cmd.tile), cable_color)
		if cmd.has("health"):
			tile.health = int(cmd.health)
		if cmd.has("ring"):
			tile.set_ring(cmd.ring.map(func(c): return Color(c)))
		if cmd.has("led"):
			tile.set_ring_led(int(cmd.led), Color(cmd.color))
		if cmd.has("press"):
			tile.press_button(StringName(cmd.press))
		if cmd.has("pressure"):
			for b in cmd.pressure:
				tile.set_pressure(StringName(b), float(cmd.pressure[b]))
		if cmd.has("button_led"):
			tile.set_button_led(StringName(cmd.button_led), Color(cmd.color))
		if cmd.get("result") is Dictionary:
			game.on_result(int(cmd.tile), cmd.result)
	match cmd.get("game", ""):
		"start":
			game.start_game()
		"next":
			game.skip()
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
		"head":
			robot.turn_head_to(float(cmd.angle))
		"fire":
			if cmd.has("tile"):
				robot.fire_at(tiles[int(cmd.tile) - 1].global_position + Vector3(0, 0.05, 0))
			else:
				robot.fire()
		"spin":
			robot.idle_spin_deg = float(cmd.get("speed", 30.0))
			robot.release_head()
		"death":  # {"tile": 3} or {"tiles": [1, 5, 9]}
			var ids: Array = cmd.get("tiles", [cmd.get("tile", 1)])
			for id in ids:
				var t := tiles[int(id) - 1]
				t.is_dead = true
				var tid := int(id)
				robot.queue_death(tid - 1, t.global_position + Vector3(0, 0.05, 0), func():
					_death_sounds()
					t.play_death()
					set_cable_flow(tid, Color(0.6, 0.0, 0.0), 0.25))
		"look_at_tile":
			robot.look_at_side(int(cmd.tile) - 1)
		"bulb_effect":
			robot.set_bulb_effect(str(cmd.effect), float(cmd.get("speed", 1.0)))
		"bulbs":
			robot.set_bulb_effect("none")
			if cmd.has("side"):
				robot.set_side_bulbs(int(cmd.side), Color(cmd.color))
			else:
				robot.set_all_bulbs(Color(cmd.color))
		"dome":
			robot.set_dome_color(Color(cmd.color))
		"party":
			robot.set_party_lamp(bool(cmd.get("on", true)))
			if cmd.has("speed"):
				robot.set_party_spin_speed(float(cmd.speed))
