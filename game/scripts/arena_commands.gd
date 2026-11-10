class_name ArenaCommands
extends RefCounted
## The messages from the real installation (MQTT, WebSocket, the tiles' own
## logic, the web interface): Arena.apply_command() hands every one of them to
## apply(). One function per kind of message. Examples:
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
##   {"game": "mode", "mode": "setup"}                (setup / closed / open / paused)
##   {"sound": "attack"}                                 (play a sound now: a random file of that
##                                                        event / folder, whatever the game is doing)
##   {"sound": "gong", "file": "gong2.ogg", "volume": 60} (one file; volume in % for this sound only)
##   {"sound_stop": true}                                (stop every sound that is playing)
##   {"sound_reload": true}                              (scan the sound folders again: new files)
##   {"room": "door", "open": true}
##   {"room": "light", "color": "#b0d0ff"}               (ceiling ring light)
##   {"tile": 3, "result": {...}}       (result of the tile's own logic, see TileFirmware)
##   {"stream": {"tile": 3, "on": true, "url": "rtsp://..."}}   (a player's screen as video, CompanionStream)

var arena: Arena
## The press being handled now came from a tile with a time stamp
## ({"t": ms since the program's start, "program": id}); {} = none.
var press_stamp := {}


func _init(arena_node: Arena) -> void:
	arena = arena_node


func apply(cmd: Dictionary) -> void:
	if cmd.get("stream") is Dictionary:
		arena.stream_command(cmd.stream)
		return
	if _sound(cmd) or _attack(cmd) or _invite(cmd):
		return
	if cmd.has("tile") and not cmd.has("robot"):
		_tile(cmd)
	_game(cmd)
	_room(cmd)
	_robot(cmd)


## An external sound trigger (web interface, show control, ...).
func _sound(cmd: Dictionary) -> bool:
	var sound := arena.sound
	if cmd.has("sound"):
		var event := StringName(str(cmd.sound))
		if not sound.play_external(event, str(cmd.get("file", "")), int(cmd.get("volume", -1))):
			push_warning("sound: no sound %s %s" % [cmd.sound, cmd.get("file", "")])
	elif cmd.get("sound_stop", false):
		sound.stop_all()
	elif cmd.get("sound_reload", false):
		sound.reload()
	else:
		return false
	return true


## A combined attack: the players on the robot, or the robot on the players.
func _attack(cmd: Dictionary) -> bool:
	if cmd.get("attack") is Array:
		arena.players_attack(cmd.attack.map(func(v): return int(v)), bool(cmd.get("everyone", false)))
	elif cmd.get("attacked") is Array:
		arena.robot_attack(cmd.attacked.map(func(v): return int(v)))
	else:
		return false
	return true


## A player invited to a tile: from the database ("assign", the gamemaster
## app) or by name ("register", a QR scan).
func _invite(cmd: Dictionary) -> bool:
	var tile_id := int(cmd.get("tile", 0))
	var mobile := bool(cmd.get("mobile", false))
	if cmd.has("assign"):
		arena.players.assign(int(cmd.assign), tile_id, Color(cmd.color) if cmd.has("color") else null, mobile)
	elif cmd.has("register"):
		arena.players.register(tile_id, str(cmd.register), Color(cmd.get("color", "#ffcc1a")),
			int(cmd.get("age", 0)), 0, mobile)
	else:
		return false
	return true


## {"tile": n, ...}: everything about one tile and its player.
func _tile(cmd: Dictionary) -> void:
	var id := int(cmd.tile)
	var tile := arena.tiles[id - 1]
	_tile_player(cmd, id)
	_tile_state(cmd, id, tile)
	_tile_buttons(cmd, tile)
	if cmd.get("result") is Dictionary:
		arena.game.on_result(id, cmd.result)


func _tile_player(cmd: Dictionary, id: int) -> void:
	if cmd.has("attack"):
		arena.players_attack([id])
	if cmd.has("attacked"):
		arena.robot_attack([id])
	if cmd.has("join"):
		arena.players.join(id, str(cmd.join), int(cmd.get("age", 0)))
	if cmd.has("leave"):
		arena.players.leave(id)
	if cmd.has("enabled"):
		arena.players.set_tile_enabled(id, bool(cmd.enabled))
	if cmd.has("points") and arena.players.is_playing(id):   # operator: round points + / -
		var n := int(cmd.points)
		var game := arena.game
		if game.current and game.current.points.has(id):
			game.current.add_points(id, n)
		else:
			game.add_score(id, n)
		arena.screen_wall.popup(id, "%+d" % n, Retro.GOOD if n > 0 else Retro.BAD)


## The tile's lives and ring.
func _tile_state(cmd: Dictionary, id: int, tile: CyberTile) -> void:
	if cmd.has("revive"):
		arena.rt(tile).revive()
		arena.cables.set_flow(id, arena.cable_color)
	if cmd.has("health"):
		tile.health = int(cmd.health)
	if cmd.has("ring"):
		arena.rt(tile).set_ring(cmd.ring.map(func(c): return Color(c)))
	if cmd.has("led"):
		arena.rt(tile).set_ring_led(int(cmd.led), Color(cmd.color))


## The tile's four icons: pressed, let go, their raw sensor values, their LEDs.
func _tile_buttons(cmd: Dictionary, tile: CyberTile) -> void:
	if cmd.has("press"):
		press_stamp = cmd if cmd.has("t") else {}    # (a real tile's time stamp: the round reads it now)
		if cmd.get("hold", 0):                       # (a real tile: down until its "release")
			arena.rt(tile).hold_button(StringName(cmd.press))
		else:
			arena.rt(tile).press_button(StringName(cmd.press))
		press_stamp = {}
	if cmd.has("release"):
		press_stamp = cmd if cmd.has("t") else {}
		arena.rt(tile).release_button(StringName(cmd.release))
		press_stamp = {}
	if cmd.has("pressure"):
		for b in cmd.pressure:
			tile.set_pressure(StringName(b), float(cmd.pressure[b]))
	if cmd.has("button_led"):
		arena.rt(tile).set_button_led(StringName(cmd.button_led), Color(cmd.color))


## The operator's commands for the game.
func _game(cmd: Dictionary) -> void:
	var game := arena.game
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


func _room(cmd: Dictionary) -> void:
	match cmd.get("room", ""):
		"door":
			if cmd.get("open", true):
				arena.room.open_door()
			else:
				arena.room.close_door()
		"light":
			arena.room.set_ring_color(Color(cmd.color))


func _robot(cmd: Dictionary) -> void:
	var npc := arena.npc
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
				arena.tiles[tid - 1].is_dead = true
				npc.doom(tid, func():
					arena.death_sounds(tid)
					arena.cables.set_flow(tid, Color(0.6, 0.0, 0.0), 0.25))
		_:                                       # the operator's commands: the npc obeys them (everywhere)
			npc.command(cmd)
