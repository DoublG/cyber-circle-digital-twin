class_name MqttBridge
extends MqttClient
## Connects the game to the installation over MQTT (WebSocket). Topics
## (prefix = topic_prefix, payloads are JSON):
##   <prefix>/tile/<n>/cmd     game -> tile   programs, start, stop ({"program": ...}),
##                                            one-off effects {"fx": "hit", "color": "#ff1a0d"}
##   <prefix>/tile/<n>/state   game -> tile   retained: what it shows (CyberTile.display_state:
##                                            mode, lives, shield, icon colours, number)
##   <prefix>/tile/<n>/event   tile -> game   {"result": {...}}, {"press": "Cross"},
##                                            {"pressure": {"Cross": 0.8}}, ...
##                                            (any apply_command fields; "tile" is added)
##   <prefix>/cmd              app/operator -> game   any apply_command message,
##                                            e.g. {"register": "Erik", "color": "#ff8800", "age": 9}
##   <prefix>/registered       game -> app    {"tile": 3, "player": "Erik", "color": "#ff8800"}
##   <prefix>/activated        game -> app    {"tile": 3, "player": "Erik"}
##   <prefix>/status           game -> all    "online" / "offline" (retained)
##   <prefix>/node/<id>        game -> all    retained announcement {id, role, host, port, screens, version}
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
##   <prefix>/sounds           game -> all    retained {"events": {"attack": ["laser1.ogg", ...], ...}}:
##                                            the sounds {"sound": "<event>"} on <prefix>/cmd can play
## Leave url empty to run without MQTT.

@export var topic_prefix := "cybercircle"
@export var real_tiles := true   # tiles run their own logic: switch the twin's simulation off
@export var node_id := ""        # name in the web interface; "" = "godot-<ip>"
@export var role := "master"
@export var enet_port := 0       # (display connections: next step)

var _state_json := ""
var _state_timer := 0.0
var _tile_states := {}           # tile_id -> last published display state (JSON)
var _tile_timer := 0.0
var _announce_timer := 0.0

var arena: Node3D


func setup(arena_node: Node3D) -> void:
	arena = arena_node
	if url == "":
		return
	if real_tiles:
		arena.simulate_firmware = false
	message.connect(_on_message)
	if node_id == "":
		node_id = "godot-" + _lan_address().replace(".", "-")
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
	arena.game.game_event.connect(func(text, color):
		publish_json(topic_prefix + "/event", {"text": text, "color": "#" + color.to_html(false)}))
	subscribe(topic_prefix + "/cmd")
	subscribe(topic_prefix + "/tile/+/event")
	subscribe(topic_prefix + "/tiles")
	subscribe(topic_prefix + "/mode")
	subscribe(topic_prefix + "/settings")
	subscribe(topic_prefix + "/texts")
	subscribe(topic_prefix + "/db")
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
		publish_json(topic_prefix + "/settings/schema", arena.game.settings_schema(), true)
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
	var data = JSON.parse_string(payload.get_string_from_utf8())
	if not data is Dictionary:
		push_warning("mqtt: ignored non-JSON message on " + topic)
		return
	if topic == topic_prefix + "/mode":                  # the operator's operating mode
		arena.apply_command({"game": "mode", "mode": data.get("mode", "")})
		return
	if topic == topic_prefix + "/db":                    # the database changed: fetch it again now
		if arena.game.db and arena.game.db.has_method("refresh"):
			arena.game.db.refresh()
		return
	if topic == topic_prefix + "/settings":              # the operator's settings
		arena.game.apply_settings(data)
		return
	if topic == topic_prefix + "/texts":                 # the operator's texts (Texts)
		Texts.apply(data)
		arena.screen_wall.refresh()                      # (free tiles: their line)
		return
	if topic == topic_prefix + "/tiles":                 # tiles in / out of service
		if data.get("installed") is Array:               # the places of this installation
			arena.set_installed(data.installed)
		var enabled: Dictionary = data.get("enabled", {})
		for n in enabled:
			arena.set_tile_enabled(int(n), bool(enabled[n]))
		return
	var parts := topic.trim_prefix(topic_prefix + "/").split("/")
	if parts.size() == 3 and parts[0] == "tile" and parts[2] == "event":
		data["tile"] = int(parts[1])
	elif parts != PackedStringArray(["cmd"]):
		return
	arena.apply_command(data)


func _process(delta: float) -> void:
	super(delta)
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
	_announce_timer -= delta
	if _announce_timer <= 0.0:          # heartbeat: the web interface shows who is online
		_announce()
	_state_timer -= delta
	if _state_timer <= 0.0:
		_state_timer = 0.5
		var json := JSON.stringify(arena.game.status())
		if json != _state_json:
			_state_json = json
			publish(topic_prefix + "/state", json, true)


func _announce() -> void:
	_announce_timer = 10.0
	publish_json(topic_prefix + "/node/" + node_id, {"id": node_id, "role": role, "host": _lan_address(),
		"port": enet_port, "screens": range(1, arena.screen_wall.groups().size() + 1),
		"version": ProjectSettings.get_setting("application/config/version", ""),
		"fps": Engine.get_frames_per_second(),
		"db_pending": arena.game.db.pending() if arena.game.db and arena.game.db.has_method("pending") else 0}, true)


## This machine's address on the LAN (the first private IPv4 address).
func _lan_address() -> String:
	for a in IP.get_local_addresses():
		if a.begins_with("192.168.") or a.begins_with("10.") or a.begins_with("172."):
			return a
	return "127.0.0.1"


func _exit_tree() -> void:
	publish(topic_prefix + "/status", "offline", true)
