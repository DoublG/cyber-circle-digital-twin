class_name LaunchOptions
extends RefCounted
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
##   --sim-tiles          with MQTT: still simulate the tile logic in the game
##   --node=NAME          this process' name in the web interface (default godot-<ip>)
##   --demo[=N]           N (default 6) bot players keep the game going (showing it without visitors)
##   --demo-idle=S        the bots only walk up after S seconds (the game idles until then)
##   --rounds=quiz,simon  only these round types (code, cyclone, quiz, reaction, rhythm, simon, zwarte_piet)
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
static func apply(arena: Arena) -> void:
	var mqtt: MqttBridge = arena.get_node("Mqtt")
	var remote := ""
	var bots: DemoBots = null
	var demo_idle := 0.0
	for a in OS.get_cmdline_user_args():
		var key := a.get_slice("=", 0)
		var value := a.substr(key.length() + 1) if "=" in a else ""
		match key:
			"--windows":
				arena.screen_wall.multi_window = true
			"--preview":
				arena.screen_wall.multi_window = false
			"--no-overview":
				arena.screen_wall.observer_page = false
			"--screens":
				arena.screen_wall.screen_groups = _parse_screens(arena, value, false)
			"--installed":                                 # standalone: only these places, e.g. 1-7,14-18
				var ids := []
				for part in value.split(",", false):
					var ab := part.split("-")
					for id in range(int(ab[0]), int(ab[-1]) + 1):
						ids.append(id)
				arena.players.set_installed.call_deferred(ids)
			"--mobile-screens":
				arena.screen_wall.mobile_groups = _parse_screens(arena, value, true)
			"--monitors":
				arena.screen_wall.monitors = Array(value.split(",", false)).map(func(v): return int(v))
			"--serve-replicas", "--serve-displays":        # the display nodes follow this game (Replica)
				if arena.replica == null:
					arena.replica = Replica.new()
				if value != "":
					arena.replica.port = int(value)
				mqtt.display_port = arena.replica.port
			"--remote-screens":                            # rendered by display nodes, not here: 1,2,5-7 / all
				remote = value
			"--replica", "--display":                      # this is a display node: no game, it follows the master
				if arena.replica == null:
					arena.replica = Replica.new()
				Replica.client = true
				mqtt.role = "display"
			"--show":                                      # a display node: the screens it shows, e.g. 1,2
				arena.replica_screens = _parse_list(value, 99)
			"--master":                                    # a display node: the master (default: its beacon)
				if arena.replica == null:
					arena.replica = Replica.new()
				arena.replica.master_host = value.get_slice(":", 0)
				if ":" in value:
					arena.replica.port = int(value.get_slice(":", 1))
			"--view-scale", "--msaa", "--detail", "--detail-size", "--lod":   # a display node's 3D views
				arena.replica_view[key.trim_prefix("--").replace("-", "_")] = float(value)
			"--windowed":                                  # a display node: windows instead of full screen
				arena.screen_wall.windowed = true
			"--shots":                                     # tests: a display node saves its screens at each mark
				arena.replica_shots = value
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
					var t: Script = RoundPicker.type_named(n.strip_edges())
					if t:
						types.append(t)
					else:
						push_warning("--rounds: unknown round type %s" % n)
				if not types.is_empty():
					arena.game.picker.round_types = types
			"--demo":
				bots = DemoBots.new()
				bots.name = "DemoBots"
				bots.arena = arena
				if value != "":
					bots.players = clampi(int(value), 0, arena.tiles.size())
				arena.add_child.call_deferred(bots)
			"--demo-idle":
				demo_idle = float(value)
			"--db":
				arena.game.db_path = "" if value == "none" else value
			"--control":
				arena.game.control_url = value
			"--ca":
				TlsTrust.load_ca(value)
			"--no-restore":
				arena.game.restore = false
			"--restore-max-age":
				arena.game.restore_max_age = float(value)
			"--texts":                                     # the operator's texts as JSON (Texts)
				var t = JSON.parse_string(FileAccess.get_file_as_string(value))
				if t is Dictionary:
					Texts.apply(t)
				else:
					push_warning("--texts: no JSON object in %s" % value)
			"--no-sound":
				arena.sound.enabled = false
			"--sounds":
				arena.sound.extra_dir = value
			"--voice":                                     # prebaked speech outside the project
				arena.narrator.extra_dir = value
			"--voice-export":                              # the lines to record, as CSV; then quit
				arena.voice_export = value
			"--settings":
				var data = JSON.parse_string(FileAccess.get_file_as_string(value))
				if data is Dictionary:
					arena.game.settings.apply.call_deferred(data)    # (after game.setup: the defaults)
				else:
					push_warning("--settings: cannot read %s" % value)
			_:
				push_warning("unknown option %s" % a)
	if bots:
		bots.idle_time = demo_idle                         # (whatever the order of the two options)
	var count := arena.screen_wall.screen_groups.size() + arena.screen_wall.mobile_groups.size()
	if remote != "":                                       # (after --screens / --mobile-screens)
		arena.screen_wall.remote_screens = _parse_list(remote, count)
	if Replica.client:                                     # a display node: only its own screens, no overview
		if arena.replica_screens.is_empty():
			arena.replica_screens = [1]
		arena.screen_wall.remote_screens = range(1, count + 1).filter(func(k): return k not in arena.replica_screens)
		arena.screen_wall.observer_page = false
		arena.screen_wall.multi_window = true
		arena.screen_wall.monitors = _replica_monitors(arena.replica_screens, arena.screen_wall.monitors, count)
		arena.game.restore = false
		arena.game.db_path = ""


## A display node's --monitors lists the monitor of each screen it shows (in
## order); ScreenWall counts per screen number: spread them out.
static func _replica_monitors(shown: Array, given: Array, count: int) -> Array:
	var out := []
	out.resize(count + 1)
	out.fill(0)
	for i in shown.size():
		var k: int = int(shown[i])
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
static func _parse_screens(arena: Arena, text: String, mobile: bool) -> Array:
	var groups := []
	var seen := {}
	for part in text.split("/", false):
		var ids := []
		for v in part.split(",", false):
			var id := int(v)
			if id < 1 or id > arena.tiles.size():
				push_warning("--screens: there is no tile %s" % v)
				continue
			if seen.has(id):
				push_warning("--screens: tile %d is on two screens" % id)
			seen[id] = true
			ids.append(id)
		groups.append(ids)
	for t in arena.tiles:
		if not seen.has(t.tile_id) and (t is DroneTile) == mobile:
			push_warning("--screens: tile %d is on no screen" % t.tile_id)
	return groups
