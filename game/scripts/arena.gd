class_name Arena
extends Node3D
## The player area (scenes/arena.tscn): robot in the middle, 13 tiles around it,
## connected to the robot by cable ducts (models/arena_floor.glb). Everything is
## placed in the scene, so you can see and edit it in the Godot editor.
## Tile_01 stands in front of robot side 0 (-Z), then clockwise seen from above,
## 2.5 m from the robot centre (matches ARENA_R in assets/blender/build_models.py).
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
## The real installation: its messages (MQTT, WebSocket, ...) come in through
## apply_command(); ArenaCommands lists them all and handles them.
## Who is on which place: PlayerRegistry (players); which places can be used:
## Installation (installation); the light strips in the ducts: CableLights
## (cables); the command line: LaunchOptions.
##
## Messages to the tiles go through send_to_tile() / the tile_message signal
## (programs for rounds the tile runs itself). simulate_firmware = true runs
## that tile logic in the game; with the real tiles connected (MqttBridge)
## set it to false.
##
## Display nodes (Replica, docs/SETUP.md §4): the master serves them
## (--serve-replicas); a display node runs this same scene with --replica: no
## game logic, it follows the master's state (ArenaMirror: mirror)
## and plays its events (the tiles through rt(), sounds, lights, popups) on
## its own screens (--show). The robot is an NPC (RobotNpc): never steered over
## the network - on every node it acts by itself on the game's events.

signal registered(tile_id: int, player: String, color: Color)  # e.g. to tell the app the tile
signal activated(tile_id: int, player: String)
signal exterminated(tile_id: int, player: String)   # the robot's shot hit: the death animation starts
signal tile_message(tile_id: int, msg: Dictionary)  # to the real tile (e.g. via MQTT)
signal light_cue(event: StringName, data: Dictionary)  # a game moment for the lights (cue(); MQTT light/event)
signal stream_changed(tile_id: int, on: bool, info: Dictionary)  # a companion video stream (CompanionStream)

const DRONES := 5                       # mobile players (ids after the floor tiles)
const DEATH_ANIMATION := 3.6            # s: the tile's / drone's death animation after the shot lands
## What a game moment means for the player it happens to (Narrator.say_to).
const PERSONAL := {
	&"hit": "Geraakt!", &"shield": "Je schild houdt de aanval tegen.", &"life": "Je krijgt er een leven bij.",
	&"death": "Je bent geëxtermineerd.", &"join": "Je doet mee. Je speelt vanaf de volgende ronde.",
	&"leave": "Je bent uit het spel.",
}

@export var packet_speed := 1.6        # cable lengths per second (tile -> robot)
@export var cable_color := Color(0.15, 0.5, 1.0)
@export var activation_timeout := 60.0  # seconds to press all 4 icons after the QR scan
@export var free_delay := 1.5           # s after the death animation before the tile is free again
@export_file("*.ogv") var death_clip := "res://data/videos/exterminate.ogv"  # in the player's view
@export var clip_wait := 30.0           # s the death clip waits for the player's split view (then dropped)
@export var clip_time := 8.0            # s the death screen stays (a shorter clip holds its last frame)
@export var simulate_firmware := true  # run the tiles' own logic in the game (no real tiles)

var tiles: Array[CyberTile] = []
var players := PlayerRegistry.new(self)    # who is on which place
var installation := Installation.new(self) # the places that can be used (installed, in service)
var cables := CableLights.new(self)        # the light strips between the tiles and the robot
var commands := ArenaCommands.new(self)    # the installation's messages (apply_command)
var observer: ObserverRig          # floating camera for the overview page (visitors)
var sound := SoundBoard.new()      # sound effects for the game events
var lights := LightDirector.new()  # the room's lights (virtual, and the real ones over MQTT)
var narrator := Narrator.new()     # read-aloud: prebaked speech per screen text, its own channel
var npc: RobotNpc                  # the robot's behaviour: the same on every node, from the game's events
var clock := 0.0                   # game time (s): follows --fixed-fps, unlike the wall clock
var hits_on_way := {}              # tile_id -> shots that will cost a life, not landed yet
var dying := {}                    # tile_id -> msec the robot's shot landed (0: not yet) during the extermination
var clip_waiting := {}             # tile_id -> clock at the hit: death clip not seen yet (no split view)
var clip_started := {}             # tile_id -> clock when the death clip started in the player's view
var streams := {}                  # tile_id -> CompanionStream (only while one is asked for)
var voice_export := ""             # --voice-export=FILE: write the lines, then quit
var replica: Replica               # --serve-replicas (master) / --replica (a display node)
var mirror := ArenaMirror.new(self)  # what the display nodes follow, and what a display node does itself
var replica_screens: Array = []    # a display node: the screens it shows (--show)
var replica_view := {}             # a display node: its render settings (--view-scale, ...)
var own_tiles_live := false        # a display node: its own tiles' commands come over MQTT
var replica_shots := ""            # tests: a display node saves its screens at the master's marks
var _attacks := 0                  # robot attacks under way (charging, shots flying)
var _clip_length := {}             # clip path -> length (s)
var _trelays := {}                 # tile -> TileRelay (rt)

@onready var robot: CyberRobot = $Robot
@onready var room: SpaceshipRoom = $Room
@onready var screen_wall: ScreenWall = $ScreenWall
@onready var game: GameManager = $Game


func _ready() -> void:
	_add_robot_npc()
	_add_tiles()
	_add_cables()
	LaunchOptions.apply(self)                # after the tiles are known, before the screens
	_add_sound_and_light()
	observer = ObserverRig.new()
	observer.name = "Observer"
	add_child(observer)
	observer.setup(self)
	if Replica.client:
		mirror.render_settings()
	screen_wall.setup(self)
	_add_replica()
	game.setup(self)
	lights.setup(self)
	if voice_export != "":
		_export_voice.call_deferred()
	($Mqtt as MqttBridge).setup(self)   # no-op while its url is empty


## The robot acts by itself on the game's events (the same on every node).
func _add_robot_npc() -> void:
	npc = RobotNpc.new()
	npc.name = "RobotNpc"
	npc.arena = self
	npc.robot = robot
	add_child(npc)
	robot.hit.connect(_on_robot_hit)
	robot.fired.connect(func(_to): cue(&"attack"))


## The floor tiles of the scene and the mobile players' drones (ids after the
## floor tiles), each with its own logic (TileFirmware).
func _add_tiles() -> void:
	var floor_tiles: int = $Tiles.get_children().filter(func(c): return c is CyberTile).size()
	for k in DRONES:
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
		tile.button_released.connect(_on_button_released)
		tile.died.connect(_on_tile_died)
		tile.health_changed.connect(func(id, _h): screen_wall.update_player(id))
		tile.idle = true
		var fw := TileFirmware.new()
		fw.name = "Firmware"
		fw.tile = tile
		fw.report = _firmware_report
		tile.add_child(fw)


## The light strips in the floor's ducts. Baked: the floor is part of the room
## (the floor scene only keeps its collider).
func _add_cables() -> void:
	if $Room.baked:
		for mi in $Floor.find_children("*", "MeshInstance3D", true, false):
			mi.visible = false
	cables.setup(_floor_model())


## The model with the floor's parts (ducts, cables, light strips).
func _floor_model() -> Node:
	return $Room if $Room.baked else $Floor


## Sound effects, the room's lights and the read-aloud voice, and the moments
## of joining they react to.
func _add_sound_and_light() -> void:
	sound.name = "Sound"
	sound.setup(self)
	add_child(sound)
	lights.name = "Lights"
	add_child(lights)
	narrator.name = "Narrator"
	narrator.setup(self)
	add_child(narrator)
	registered.connect(func(id, who, color):
		narrator.say(Narrator.invite_name(id), Narrator.invite_line(id), "invite", {"tile": id})   # where to go
		cue(&"registered", id, {"color": "#" + color.to_html(false), "player": who}))
	activated.connect(func(id, _who): cue(&"join", id))


## A master serving display nodes, or a display node itself (LaunchOptions).
func _add_replica() -> void:
	var mqtt := $Mqtt as MqttBridge
	if Replica.client and mqtt.node_id == "":
		mqtt.node_id = "display-" + MqttBridge.lan_address().replace(".", "-")
	if replica:
		replica.arena = self
		replica.name = "Replica"
		replica.node_id = mqtt.node_id
		_start_replica.call_deferred()


## The replication node lives at /root/Replica on every node (RPCs need the
## same path on both ends; a test may put the arena elsewhere).
func _start_replica() -> void:
	get_tree().root.add_child(replica)
	tree_exiting.connect(func():
		if is_instance_valid(replica):
			replica.queue_free())
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


# ---------------------------------------------------------------- the floor

## Hide the floor parts of the places that are not installed: the duct to the
## robot with its cable, label and light strip, and the duct between two
## neighbours (when either of them is not installed). Baked room: the per-tile
## meshes Tile_Ducts_NN / Ring_NN (bake_models.py); unbaked: the floor's parts.
func show_installed() -> void:
	var floor_model := _floor_model()
	var n := Retro.FLOOR_TILES
	for id in range(1, n + 1):
		var on := installation.is_installed(id)
		for part in ["Tile_Ducts_%02d", "Spoke_%02d", "Cable_%02d", "Label_%02d", "Spoke_Light_%02d"]:
			var node := floor_model.find_child(part % id, true, false) as Node3D
			if node:
				node.visible = on
		var ring := floor_model.find_child("Ring_%02d" % id, true, false) as Node3D   # to the next tile
		if ring:
			ring.visible = on and installation.is_installed(id % n + 1)


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
		hits_on_way[id] = hits_on_way.get(id, 0) + 1
	_attacks += 1
	await npc.attack(targets, color, shielded,
		func(): cue(&"charge", 0, {"tiles": targets.duplicate()}),
		func():
			cue(&"attack", 0, {"tiles": targets.duplicate()})   # the bolts leave the robot
			get_tree().create_timer(3.0).timeout.connect(func(): _attacks -= 1)   # (the shots land in ~1-2 s)
			if not tile_ids.is_empty():
				game.log_event("ROBOT RAAKT "
					+ ", ".join(tile_ids.map(func(id): return players.player_name(id).to_upper())), Retro.BAD)
			for id in shielded:
				game.log_event("SCHILD BESCHERMT %s" % players.player_name(id).to_upper(), Retro.SHIELD),
		func(id: int, blocked: bool):                  # the shot landed (the tile's hit / block: the npc)
			if blocked:
				cue(&"shield", id)
			else:
				cue(&"hit", id)
				if id in costs_life:
					hits_on_way[id] = maxi(hits_on_way.get(id, 0) - 1, 0)
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
		npc.aim(int(tile_ids[0]))


## The exterminations of a round, all at once (the scoreboard shows them):
## every doomed tile blinks red, the robot fires at the first, and while its
## death animation plays it turns to the next one, and so on (CyberRobot's
## death queue). Nothing waits for it: the game goes on, this runs on top.
func exterminate(tile_ids: Array) -> void:
	var any := false
	for id in tile_ids:
		if players.is_playing(id) and not tiles[id - 1].is_dead:
			game.take_life(id)
			tiles[id - 1].health = 0          # -> died -> _on_tile_died (queued on the robot)
			any = true
	if not any and not tile_ids.is_empty():
		npc.release()                         # (aimed, but they left in the meantime)


## An attack under way or a shot on its way (the scoreboard waits for it).
func attacks_busy() -> bool:
	return _attacks > 0 or hits_on_way.values().any(func(n): return n > 0)


## The lives a player will have once the robot's shots on the way have landed
## (the scoreboard can appear before the hit).
func lives_after_hits(tile_id: int) -> int:
	return maxi(tiles[tile_id - 1].health - hits_on_way.get(tile_id, 0), 0)


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


## The press being handled now came from a tile with a time stamp
## ({"t": ms since the program's start, "program": id}); {} = none (a simulated
## tile, an old firmware): the round uses the moment it arrived.
func press_stamp() -> Dictionary:
	return commands.press_stamp


## Send a message to a tile's own controller (programs, start, stop).
func send_to_tile(tile_id: int, msg: Dictionary) -> void:
	Replica.relay("mirror", &"tile_msg", [tile_id, msg])   # (the display nodes run the tile logic too: it shows)
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


func _process(delta: float) -> void:
	clock += delta
	Retro.game_clock = clock
	cables.update(delta)
	if not Replica.client:                       # (the master decides when an invite runs out)
		players.update(delta)


func _on_button_pressed(tile_id: int, button: StringName) -> void:
	var tile := tiles[tile_id - 1]
	if Replica.client:                           # a display: show the press at once (the master decides)
		if players.is_pending(tile_id):
			tile.activation_press(button)
		elif own_tiles_live and mirror.is_own_tile(tile_id) and not tile.idle:
			npc.press(tile_id, CyberTile.BUTTON_COLORS[button])   # (its own tiles: from MQTT, at once)
		return
	if players.is_pending(tile_id):  # activation: press all 4 icons
		if tile.activation_press(button):
			players.activate(tile_id)
		return
	if tile.idle:  # nobody registered on this tile
		return
	var color: Color = CyberTile.BUTTON_COLORS[button]
	# the press travels down the cable; the robot looks at the player when it arrives
	npc.press(tile_id, color)
	game.on_button(tile_id, button)


## Let go of an icon (Ritme's hold notes): only for a player in the game.
func _on_button_released(tile_id: int, button: StringName) -> void:
	if Replica.client or players.is_pending(tile_id) or tiles[tile_id - 1].idle:
		return
	game.on_button(tile_id, button, false)


## Last life lost: queue the robot's death animation; the tile plays its effect
## when the shot lands. Several tiles can die at the same moment.
## 0 lives: exterminated. The tile blinks red until the robot has turned to
## it and fired; then the death animation plays on the tile and the death clip
## in the player's view, after which the player leaves and the tile is free.
func _on_tile_died(tile_id: int) -> void:
	if Replica.client:
		return                                   # (the master runs the extermination; it comes as events)
	var tile := tiles[tile_id - 1]
	var who := players.player_name(tile_id)
	game.log_event("%s IS GEËXTERMINEERD!" % who.to_upper(), Retro.BAD)
	cue(&"death", tile_id, {"player": who})
	dying[tile_id] = 0
	if dying.size() == 1:                        # the overview drifts over to watch
		observer.focus(tile.global_position, 9.0)
	else:                                        # several: a wide view on the robot
		observer.focus(Vector3.ZERO, 9.0 + dying.size() * 1.5)
	npc.doom(tile_id, func():                       # the shot landed
			cables.set_flow(tile_id, Color(0.6, 0.0, 0.0), 0.25)
			death_sounds(tile_id)
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
			if players.player_name(tile_id) == who:            # still the same player
				players.leave(tile_id)
				game.log_event("%s IS WEER VRIJ" % Retro.tile_label(tile_id), Retro.DIM))


## The tile's death (CyberTile.play_death): 1 s electrocution, then the explosion.
func death_sounds(tile_id: int) -> void:
	cue(&"zap", tile_id)
	get_tree().create_timer(1.0).timeout.connect(func(): cue(&"explosion", tile_id))


## --voice-export=FILE: every line the narrator can say, as CSV; then quit
## (waits a moment for the questions from the control server).
func _export_voice() -> void:
	for i in 50:                                   # (the control server's list, not the JSON fallback)
		if game.db == null or not game.db.questions().is_empty():
			break
		await get_tree().create_timer(0.2).timeout
	var n := Narrator.export_csv(game, voice_export)
	print("voice: %d lines written to %s" % [n, voice_export])
	get_tree().quit()


## {"stream": {"tile": 3, "on": true, "url": "rtsp://...", "fps": 15, "encoder": "auto"}}:
## start / keep alive / stop the video of that player's screen (CompanionStream).
## Nothing exists until one is asked for.
func stream_command(s: Dictionary) -> void:
	var id := int(s.get("tile", 0))
	if id < 1 or id > tiles.size():
		return
	var cs: CompanionStream = streams.get(id)
	if not bool(s.get("on", true)):
		if is_instance_valid(cs):
			cs.stop("asked")
			cs.queue_free()
		streams.erase(id)
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
			streams.erase(t)
		stream_changed.emit(t, on, info))
	streams[id] = cs
	add_child(cs)
	cs.start()


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
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_F:
			npc.command({"robot": "fire", "tile": randi() % tiles.size() + 1})
		KEY_R:
			var free := tiles.filter(func(t): return t.idle and not players.is_pending(t.tile_id))
			if not free.is_empty():
				var t: CyberTile = free.pick_random()
				players.register(t.tile_id, "Speler %d" % t.tile_id, Color.from_hsv(randf(), 0.8, 1.0))
		KEY_J:
			var free := tiles.filter(func(t): return t.idle)
			if not free.is_empty():
				players.join(free.pick_random().tile_id)
		KEY_L:
			var ids := players.player_ids()
			if not ids.is_empty():
				players.leave(ids.pick_random())
		KEY_S:
			game.start_game()
		KEY_N:
			game.skip()
		KEY_O:
			room.toggle_door()
		KEY_K:
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
				tile.ring.fill(Color.RED)
				await get_tree().create_timer(0.1).timeout
				tile.ring.clear()
				await get_tree().create_timer(0.1).timeout


## Single entry point for state coming from the real installation (ArenaCommands).
func apply_command(cmd: Dictionary) -> void:
	commands.apply(cmd)
