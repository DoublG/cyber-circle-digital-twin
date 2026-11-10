class_name MqttBridge
extends MqttClient
## Connects the game to the installation over MQTT (WebSocket). Topics
## (prefix = topic_prefix, payloads are JSON):
##   <prefix>/tile/<n>/cmd     game -> tile   programs, start, stop ({"program": ...}),
##                                            one-off effects {"fx": "hit", "color": "#ff1a0d"}
##   <prefix>/tile/<n>/state   game -> tile   retained: what it shows (CyberTile.display_state:
##                                            mode, lives, shield, icon colours, number)
##   <prefix>/tile/<n>/event   tile -> game   {"result": {...}}, {"press": "Cross", "hold": 1},
##                                            {"release": "Cross"} (hold: a release follows),
##                                            {"pressure": {"Cross": 0.8}}, ...
##                                            (any apply_command fields; "tile" is added)
##   <prefix>/cmd              app/operator -> game   any apply_command message,
##                                            e.g. {"register": "Erik", "color": "#ff8800", "age": 9}
##   <prefix>/registered       game -> app    {"tile": 3, "player": "Erik", "color": "#ff8800"}
##   <prefix>/activated        game -> app    {"tile": 3, "player": "Erik"}
##   <prefix>/status           game -> all    "online" / "offline" (retained)
##   <prefix>/node/<id>        game -> all    retained announcement {id, role, host, port, screens, version}
##   <prefix>/metrics/<id>     game -> all    every 2 s: performance (NodeMetrics + the display links, the game);
##                                            also for each display node (they send theirs to the master)
## A display node (Replica) only reads its own tiles: tile/<n>/cmd and tile/<n>/event
## of the tiles on its screens (they are its controllers) - it publishes nothing.
##   <prefix>/state            game -> all    retained game state (GameManager.status()) for the web interface
##   <prefix>/event            game -> all    {text, color}: the event feed
##   <prefix>/tiles            control -> game  retained {"enabled": {"3": false, ...}}: tiles out of service
##   <prefix>/db               control -> game  {"changed": "players" | "questions" | "ranking"}: fetch again
##   <prefix>/mode             control -> game  retained {"mode": "setup" | "closed" | "open" | "paused"}
##   <prefix>/light/event      game -> all    a game moment for the lights: {"event": "hit", "tile": 3,
##                                            "angle": 27.7, ...} (Arena.cue; docs/SETUP.md §5)
##   <prefix>/light/scene      game -> all    retained: the base look {"scene": "playing", "round": "quiz",
##                                            "color": "#8c40ff", "flashes": true} (LightDirector)
##   <prefix>/voice            game -> all    a line read out (Narrator): {"name": "question_12", "text": ...,
##                                            "kind": "question", "screens": [1, 2, 3, 4, 5], "file": ...}
##   <prefix>/stream           game -> all    a companion video started / stopped: {tile, on, encoder?, error?}
##   <prefix>/robot/cmd        game -> robot  the real robot (firmware/robot/): the robot NPC's events as
##                                            commands {"look": 3}, {"exterminate": [3]}, {"mood": "playing"} ...
##   <prefix>/device/<dev>/hello   tile -> all   retained: a physical tile announces itself {fw, net, ip, link, ...}
##   <prefix>/device/<dev>/config  control -> tile  retained {"tile": n}: its place
##                                            (the master reads both: the SETUP test screens show each place's tile)
##   <prefix>/sounds           game -> all    retained {"events": {"attack": ["laser1.ogg", ...], ...}}:
##                                            the sounds {"sound": "<event>"} on <prefix>/cmd can play
## Leave url empty to run without MQTT.

const HELLO_TIMEOUT := 30.0      # s without a hello: offline (as the control server; tiles say hello every 10 s)

@export var topic_prefix := "cybercircle"
@export var real_tiles := true   # tiles run their own logic: switch the game's simulation off
@export var node_id := ""        # name in the web interface; "" = "godot-<ip>"
@export var role := "master"
@export var display_port := 0       # the display nodes connect here (--serve-displays, MirrorServer)
@export var advertise := ""      # the address announced (--advertise; "" = a LAN address of this machine)

var arena: Arena
var devices := {}                # master: physical tile id -> its hello (device/<dev>/hello)
var device_place := {}           # master: physical tile id -> its place (device/<dev>/config)

var _state_json := ""
var _state_timer := 0.0
var _tile_states := {}           # tile_id -> last published display state (JSON)
var _tile_timer := 0.0
var _announce_timer := 0.0
var _device_seen := {}           # master: physical tile id -> msec its last hello came in
var _display_announced := {}     # master: display node id -> msec its node/<id> went out


func setup(arena_node: Arena) -> void:
	arena = arena_node
	if Replica.client:
		_setup_display()
		return
	if arena.replica:                                   # the display nodes' metrics, published for them
		arena.replica.on_metrics = _publish_display
	if url == "":
		return
	if real_tiles:
		arena.simulate_firmware = false
	message.connect(_on_message)
	if node_id == "":
		node_id = "godot-" + _lan_address().replace(".", "-")
	client_id = "cybercircle-" + node_id                # (unique: the broker drops a client whose id comes again)
	var metrics := NodeMetrics.new()
	metrics.name = "Metrics"
	metrics.mqtt = self
	metrics.node_id = node_id
	metrics.role = role
	metrics.topic = "%s/metrics/%s" % [topic_prefix, node_id]
	metrics.extra = _metrics
	add_child(metrics)
	connected.connect(func():
		print("mqtt: connected to ", url)
		publish(topic_prefix + "/status", "online", true)
		_announce()
		_publish_settings()
		_publish_sounds()
		_publish_light_scene()
		_state_json = ""
		_tile_states.clear())                         # (the tiles' displays again)
	arena.tile_message.connect(func(id, msg):
		publish_json("%s/tile/%d/cmd" % [topic_prefix, id], msg))
	for t in arena.tiles:                               # one-off effects for the real tiles
		t.fx.connect(func(id, name, color):
			if online:
				publish_json("%s/tile/%d/cmd" % [topic_prefix, id], {"fx": name, "color": "#" + color.to_html(false)}))
	arena.registered.connect(func(id, who, color):
		publish_json(topic_prefix + "/registered",
			{"tile": id, "player": who, "color": "#" + color.to_html(false)}))
	arena.activated.connect(func(id, who):
		publish_json(topic_prefix + "/activated", {"tile": id, "player": who}))
	arena.npc.hardware.connect(func(cmd):               # the real robot follows the NPC's events
		if online and role == "master":
			publish_json(topic_prefix + "/robot/cmd", cmd))
	arena.game.game_event.connect(func(text, color):
		publish_json(topic_prefix + "/event", {"text": text, "color": "#" + color.to_html(false)}))
	subscribe(topic_prefix + "/cmd")
	subscribe(topic_prefix + "/tile/+/event")
	subscribe(topic_prefix + "/tiles")
	subscribe(topic_prefix + "/mode")
	subscribe(topic_prefix + "/settings")
	subscribe(topic_prefix + "/texts")
	subscribe(topic_prefix + "/db")
	subscribe(topic_prefix + "/device/+/hello")
	subscribe(topic_prefix + "/device/+/config")
	arena.game.settings_changed.connect(_publish_settings)
	arena.sound.sounds_changed.connect(_publish_sounds)
	arena.light_cue.connect(func(event, data):
		if online and role == "master":
			var msg: Dictionary = data.duplicate()
			msg["event"] = String(event)
			publish_json(topic_prefix + "/light/event", msg))
	arena.lights.scene_changed.connect(func(_s): _publish_light_scene())
	arena.stream_changed.connect(func(t, on, info):              # the companion video's state
		if online:
			var msg: Dictionary = info.duplicate()
			msg.merge({"tile": t, "on": on})
			publish_json(topic_prefix + "/stream", msg))
	arena.narrator.line_said.connect(func(line):
		if online and role == "master":
			publish_json(topic_prefix + "/voice", line))
	start()


## Every setting with range, default and value (retained): the web interface
## builds its settings page from it.
func _publish_settings() -> void:
	if role == "master":
		publish_json(topic_prefix + "/settings/schema", arena.game.settings.schema(), true)
		publish_json(topic_prefix + "/texts/defaults", Texts.defaults(arena.game), true)   # (rules follow the settings)


## The base look for the real lights (retained: a lighting system that starts later gets it).
func _publish_light_scene() -> void:
	if role == "master" and online:
		publish_json(topic_prefix + "/light/scene", arena.lights.scene, true)


## The sounds an external system can play (the web interface lists them).
func _publish_sounds() -> void:
	if role == "master" and online:
		publish_json(topic_prefix + "/sounds", {"events": arena.sound.catalog(), "node": node_id}, true)


func _on_message(topic: String, payload: PackedByteArray) -> void:
	if topic.begins_with(topic_prefix + "/device/"):
		_on_device(topic.trim_prefix(topic_prefix + "/device/").split("/"), payload)
		return
	var data = JSON.parse_string(payload.get_string_from_utf8())
	if not data is Dictionary:
		push_warning("mqtt: ignored non-JSON message on " + topic)
		return
	if topic == topic_prefix + "/mode":                  # the operator's operating mode
		arena.apply_command({"game": "mode", "mode": data.get("mode", "")})
		return
	if topic == topic_prefix + "/db":                    # the database changed: fetch it again now
		if arena.game.db:
			arena.game.db.refresh()
		return
	if topic == topic_prefix + "/settings":              # the operator's settings
		arena.game.settings.apply(data)
		return
	if topic == topic_prefix + "/texts":                 # the operator's texts (Texts)
		Texts.apply(data)
		arena.screen_wall.refresh_all()                  # (free tiles: their line)
		return
	if topic == topic_prefix + "/tiles":                 # tiles in / out of service
		if data.get("installed") is Array:               # the places of this installation
			arena.players.set_installed(data.installed)
		var enabled: Dictionary = data.get("enabled", {})
		for n in enabled:
			arena.players.set_tile_enabled(int(n), bool(enabled[n]))
		return
	var parts := topic.trim_prefix(topic_prefix + "/").split("/")
	if parts.size() == 3 and parts[0] == "tile" and parts[2] == "event":
		data["tile"] = int(parts[1])
	elif parts != PackedStringArray(["cmd"]):
		return
	arena.apply_command(data)


func _process(delta: float) -> void:
	super(delta)
	if Replica.client:
		return
	_tile_timer -= delta
	if online and role == "master" and _tile_timer <= 0.0:   # the real tiles' displays, on every change
		_tile_timer = 0.1
		for t in arena.tiles:
			var json := JSON.stringify(t.display_state())
			if json != _tile_states.get(t.tile_id, ""):
				_tile_states[t.tile_id] = json
				publish("%s/tile/%d/state" % [topic_prefix, t.tile_id], json, true)
	if not online:
		return
	if Time.get_ticks_msec() / 1000.0 >= _announce_timer:   # heartbeat (wall clock): the web interface shows who is online
		_announce()
	_state_timer -= delta
	if _state_timer <= 0.0:
		_state_timer = 0.5
		var json := JSON.stringify(arena.game.status())
		if json != _state_json:
			_state_json = json
			publish(topic_prefix + "/state", json, true)


# ---------------------------------------------------------------- the physical tiles (SETUP test screens)

## device/<dev>/hello or /config (an empty retained message: gone).
func _on_device(parts: PackedStringArray, payload: PackedByteArray) -> void:
	if parts.size() != 2:
		return
	var dev := parts[0]
	var data = JSON.parse_string(payload.get_string_from_utf8()) if payload.size() > 0 else null
	if parts[1] == "hello":
		if data is Dictionary:
			devices[dev] = data
			_device_seen[dev] = Time.get_ticks_msec()
		else:
			devices.erase(dev)
			_device_seen.erase(dev)
	elif parts[1] == "config":
		if data is Dictionary and int(data.get("tile", 0)) > 0:
			device_place[dev] = int(data.tile)
		else:
			device_place.erase(dev)


## What the SETUP test screens show about the installation: per place its
## physical tile (from its hello), and the broker link. Sent to the display
## nodes too (ScreenWall sends it every second in SETUP; also without a broker).
func diagnosis() -> Dictionary:
	var now := Time.get_ticks_msec()
	var tiles := {}
	for dev in device_place:
		var h: Dictionary = devices.get(dev, {})
		var age := (now - int(_device_seen[dev])) / 1000.0 if _device_seen.has(dev) else -1.0
		tiles[str(device_place[dev])] = {"device": dev, "fw": str(h.get("fw", "")), "net": str(h.get("net", "")),
			"ip": str(h.get("ip", "")), "link": str(h.get("link", "")),
			"age": snappedf(age, 0.1), "online": age >= 0.0 and age < HELLO_TIMEOUT}
	var unplaced := devices.keys().filter(func(d): return not device_place.has(d))
	return {"mqtt": online, "broker": url, "tiles": tiles, "unplaced": unplaced}


# ---------------------------------------------------------------- a display node

## A display node: its metrics go to the master (Replica); MQTT (if given) only
## for its own tiles, read-only - their commands and presses, so its tiles
## work as its controllers even when the link to the master is down.
func _setup_display() -> void:
	client_id = "cybercircle-" + node_id
	var metrics := NodeMetrics.new()
	metrics.name = "Metrics"
	metrics.mqtt = self
	metrics.node_id = node_id
	metrics.role = "display"
	metrics.sink = arena.replica.send_metrics
	metrics.extra = func(_span):
		return {"screens_shown": arena.replica_screens, "view_scale": arena.screen_wall.view_scale,
			"replica": arena.replica.link(), "own_tiles_mqtt": arena.own_tiles_live}
	add_child(metrics)
	if url == "":
		return
	message.connect(_on_display_message)
	connected.connect(func():
		print("mqtt: connected to %s (own tiles only)" % url)
		arena.own_tiles_live = true)
	disconnected.connect(func(): arena.own_tiles_live = false)
	for id in range(1, arena.tiles.size() + 1):
		if arena.is_own_tile(id):
			subscribe("%s/tile/%d/cmd" % [topic_prefix, id])
			subscribe("%s/tile/%d/event" % [topic_prefix, id])
	start()


func _on_display_message(topic: String, payload: PackedByteArray) -> void:
	var data = JSON.parse_string(payload.get_string_from_utf8())
	var parts := topic.trim_prefix(topic_prefix + "/").split("/")
	if not data is Dictionary or parts.size() != 3 or parts[0] != "tile":
		return
	var id := int(parts[1])
	if id < 1 or id > arena.tiles.size() or not arena.is_own_tile(id):
		return
	if Replica.debug:
		print("replica: own tile %d over MQTT: %s %s" % [id, parts[2], data])
	if parts[2] == "cmd":
		arena.replica_tile_msg(id, data)               # (its tile logic: the same program as the real tile)
	elif parts[2] == "event" and data.has("press"):
		if data.get("hold", 0):                    # (shows at once; the master scores it)
			arena.tiles[id - 1].hold_button(StringName(data.press))
		else:
			arena.tiles[id - 1].press_button(StringName(data.press))
	elif parts[2] == "event" and data.has("release"):
		arena.tiles[id - 1].release_button(StringName(data.release))


## Master: a display node's metrics, on MQTT for it (it has none itself).
func _publish_display(peer: Dictionary, m: Dictionary) -> void:
	if not online:
		return
	var id := str(peer.get("node", "display"))
	m["id"] = id
	m["role"] = "display"
	publish_json("%s/metrics/%s" % [topic_prefix, id], m)
	var now := Time.get_ticks_msec()
	if now - int(_display_announced.get(id, -100000)) > 10000:
		_display_announced[id] = now
		var link: Dictionary = m.get("link", {})
		publish_json("%s/node/%s" % [topic_prefix, id], {"id": id, "role": "display", "host": link.get("host", ""),
			"port": 0, "screens": peer.get("screens", []), "fps": m.get("fps", 0), "master": node_id,
			"version": ProjectSettings.get_setting("application/config/version", "")}, true)


func _announce() -> void:
	_announce_timer = Time.get_ticks_msec() / 1000.0 + 10.0
	publish_json(topic_prefix + "/node/" + node_id, {"id": node_id, "role": role, "host": _lan_address(),
		"port": display_port, "screens": range(1, arena.screen_wall.groups().size() + 1).filter(
			func(k): return k not in arena.screen_wall.remote_screens),
		"remote_screens": arena.screen_wall.remote_screens,
		"displays": arena.replica.peers.size() if arena.replica else 0,
		"version": ProjectSettings.get_setting("application/config/version", ""),
		"fps": Engine.get_frames_per_second(),
		"db_pending": arena.game.db.pending() if arena.game.db else 0}, true)


## The master's own part of its metrics: the mirror to the display nodes (per
## display: throughput, backlog), the companion videos, the game.
func _metrics(_span: float) -> Dictionary:
	var out := {"screens_local": range(1, arena.screen_wall.groups().size() + 1).filter(
		func(k): return k not in arena.screen_wall.remote_screens).size(),
		"streams": arena.streams.size(), "players": arena.players.player_ids().size(),
		"game_state": GameManager.State.keys()[arena.game.state],
		"db_pending": arena.game.db.pending() if arena.game.db else 0}
	var r: Replica = arena.replica
	if r:
		out["replica"] = {"port": r.port, "displays": r.peer_list(), "events": r.stats.events,
			"deltas": r.stats.deltas, "snapshots": r.stats.snapshots, "live": r.stats.live}
	return out


## This machine's address on the LAN: --advertise, else a private IPv4
## address (192.168. / 10. first: 172.17-31 are often Docker's bridges).
func _lan_address() -> String:
	if advertise != "":
		return advertise
	return lan_address()


static func lan_address() -> String:
	var addrs := IP.get_local_addresses()
	for prefix in ["192.168.", "10.", "172."]:
		for a in addrs:
			if a.begins_with(prefix):
				return a
	return "127.0.0.1"


func _exit_tree() -> void:
	if not Replica.client:
		publish(topic_prefix + "/status", "offline", true)
