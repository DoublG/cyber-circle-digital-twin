extends Node
## End-to-end MQTT test: the game talks to a fake real tile (tile 3) and a fake
## registration app through tests/mqtt_test_broker.py (MQTT over WebSocket).
## Run: python3 tests/mqtt_test_broker.py 9011 &
##      godot --headless --path . res://tests/test_mqtt.tscn

const ARENA := preload("res://scenes/arena.tscn")
const URL := "ws://127.0.0.1:9011/mqtt"

var arena: Node3D
var game: GameManager
var tile: MqttClient          # plays the real tile 3 + the app
var failures := 0
var program := {}
var started := false
var app_heard := []


func _ready() -> void:
	arena = ARENA.instantiate()
	var bridge: MqttBridge = arena.get_node("Mqtt")
	bridge.url = URL
	add_child(arena)
	game = arena.game
	for f in ["res://tests/_mqtt_test.db", "res://tests/_mqtt_test.db-wal", "res://tests/_mqtt_test.db-shm"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	game.use_database("res://tests/_mqtt_test.db")
	game.intro_time = 1.0
	game.auto_start_delay = 0.0
	game.round_types = [ReactionRound]

	tile = MqttClient.new()
	tile.url = URL
	tile.client_id = "fake-tile-3"
	add_child(tile)
	tile.message.connect(_on_tile_message)
	tile.subscribe("cybercircle/tile/3/cmd")
	tile.subscribe("cybercircle/registered")
	tile.subscribe("cybercircle/activated")
	tile.start()
	_run()


func _on_tile_message(topic: String, payload: PackedByteArray) -> void:
	var msg = JSON.parse_string(payload.get_string_from_utf8())
	if topic.ends_with("/registered") or topic.ends_with("/activated"):
		app_heard.append(topic.get_file())
		return
	if msg.has("program"):
		program = msg.program
	if msg.has("start") and msg.start == program.get("id"):
		started = true


func _run() -> void:
	await _until(func(): return tile.online and arena.get_node("Mqtt").online)
	check(true, "game and tile connected to the broker")
	check(not arena.simulate_firmware, "real tiles: twin simulation off")

	print("--- app puts a player in the database, then assigns her to tile 3 (over MQTT)")
	var tess: int = game.db.add_player("Tess", "#00ff88", 10)
	tile.publish_json("cybercircle/cmd", {"assign": tess, "tile": 3})
	await _until(func(): return arena.is_pending(3))
	check(arena.is_pending(3) and arena.pending_info(3).name == "Tess", "tile 3 waits for activation (Tess, from the database)")
	for b in ["Square", "Triangle", "Cross", "Circle"]:  # the real tile reports presses
		tile.publish_json("cybercircle/tile/3/event", {"press": b})
	await _until(func(): return arena.is_playing(3))
	check(arena.is_playing(3), "Tess activated by presses from the tile")
	await _wait(0.5)
	check("registered" in app_heard and "activated" in app_heard, "app was told: registered + activated")

	print("--- reaction round: program uploaded during the intro, then start")
	game.start_game()
	await _until(func(): return not program.is_empty())
	check(game.state == GameManager.State.INTRO, "program arrived during the intro")
	check(program.steps.size() > 5, "program has %d steps" % program.steps.size())
	await _until(func(): return started)
	check(game.state == GameManager.State.PLAYING, "start arrived when the round began")

	print("--- the tile reports its results")
	var round: ReactionRound = game.current
	var expect := 0
	for i in 4:                          # all successes: the window shrinks every step
		var step: Dictionary = program.steps[i]
		var window: int = program.windows[i]
		var outcome := "nogo_ok" if step.nogo else "hit"
		expect += 3 if step.nogo else 3 + roundi(7.0 * (1.0 - 300.0 / window))
		tile.publish_json("cybercircle/tile/3/event", {"result": {"program": program.id,
			"step": i, "outcome": outcome, "button": "" if step.nogo else step.button, "ms": 300,
			"window": window, "streak": i + 1}})
	await _until(func(): return round._results[3].size() == 4)
	print("    round points: ", round.points)
	check(round.points[3] == expect, "scored %d points from 4 results" % expect)
	check(round.stats[3].best_streak == 4, "run of 4 successes counted")
	tile.publish_json("cybercircle/tile/3/event", {"result": {"program": program.id,
		"step": 0, "outcome": "hit", "button": "x", "ms": 1}})
	await _wait(0.5)
	check(round.points[3] == expect, "duplicate result ignored")

	print("\nDONE: %d failure(s)" % failures)
	get_tree().quit(1 if failures else 0)


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		failures += 1


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _until(cond: Callable, timeout := 20.0) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()
	if not cond.call():
		check(false, "timed out waiting")
