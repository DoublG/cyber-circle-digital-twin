extends Node
## Display nodes end to end, the master's side (tests/run_replica_test.sh, with
## a display node showing screens 2, 4 and 6): players join, an invite, a quiz,
## an attack, an extermination, the scoreboard, a rhythm round. At each moment the master marks
## it: the display compares its replicated state with the master's (it prints
## "mark <name> state EQUAL") and saves its screens; the master saves its own -
## both as drawn at the same game clock, AHEAD s on.
## Run: godot --path . res://tests/test_replica.tscn -- --serve-replicas=7361

const ARENA := preload("res://scenes/arena.tscn")
const AHEAD := 0.25                       # s (the mark is at the display well before)

var arena: Arena
var out := ""


func _ready() -> void:
	out = OS.get_environment("REPLICA_SHOTS")
	if out == "":
		out = ProjectSettings.globalize_path("res://tests/shots/replica")
	DirAccess.make_dir_recursive_absolute(out)
	arena = ARENA.instantiate()
	add_child(arena)
	arena.game.use_database("")
	arena.game.intro_time = 2.0
	if arena.replica == null:
		push_error("no --serve-replicas")
		get_tree().quit(1)
		return
	if OS.get_environment("REPLICA_FULL") == "1":     # (tests/run_display_perf.sh: every place taken)
		for id in range(1, 19):
			arena.apply_command({"tile": id, "join": "Speler%d" % id})
		await _perf()
		return
	for p in [[1, "Anna"], [2, "Bram"], [3, "Cleo"], [10, "Dirk"], [14, "Femke"]]:
		arena.apply_command({"tile": p[0], "join": p[1]})
	arena.apply_command({"tile": 4, "register": "Eva", "color": "#ff8800"})
	arena.tiles[3].press_button(&"Square")
	print("TEST waiting for a display")
	var t := 0.0
	while arena.replica.peers.is_empty() and t < 60.0:
		await get_tree().process_frame
		t += get_process_delta_time()
	if arena.replica.peers.is_empty():
		print("TEST FAIL no display connected")
		get_tree().quit(1)
		return
	await _moment("lobby", 3.0)             # (the snapshot; the display builds its screens)
	arena.game.picker.random_rounds = false
	arena.game.picker.round_types = [preload("res://scripts/game/quiz_round.gd"),
		preload("res://scripts/game/rhythm_round.gd")]
	arena.game.start_game()
	await _moment("intro", 1.0)               # (halfway the intro: it takes 2 s)
	await _moment("quiz", 4.0)
	arena.robot_attack([2], Color(1, 0.1, 0.05))
	await _moment("attack", 2.5)
	arena.apply_command({"tile": 10, "health": 0})   # exterminated
	await _moment("death", 6.0)
	arena.game.skip()                         # to the scoreboard
	await _moment("scores", 3.0)
	arena.game.skip()                         # the next round: rhythm (a personal round: overlays, the round's clock)
	while arena.game.state != GameManager.State.PLAYING:
		await _wait(0.2)
	await _moment("rhythm", 4.0)
	var tail := float(OS.get_environment("REPLICA_TAIL"))   # (a bad network: time to reconnect, then check again)
	if tail > 0.0:
		await _wait(tail)
		while arena.replica.peers.is_empty() and tail < 60.0:
			await _wait(0.5)
			tail += 0.5
		await _moment("after", 2.0)
	print("TEST replica stats ", arena.replica.stats, " ", arena.replica.peer_list())
	arena.mirror.mark("quit", arena.clock)
	await _wait(2.0)
	print("TEST done")
	get_tree().quit()


## Performance: what the display reports (NodeMetrics, every 2 s) in the lobby
## and in a round on the tile (the views tilted down).
func _perf() -> void:
	while arena.replica.peers.is_empty():
		await get_tree().process_frame
	await _wait(12.0)
	_report("lobby")
	arena.game.picker.random_rounds = false
	arena.game.picker.round_types = [preload("res://scripts/game/cyclone_round.gd")]
	arena.game.start_game()
	while arena.game.state != GameManager.State.PLAYING:
		await _wait(0.2)
	await _wait(10.0)
	_report("round")
	get_tree().quit()


func _report(what: String) -> void:
	for id in arena.replica.peers:
		var m: Dictionary = arena.replica.peers[id].metrics
		print("TEST perf %s: %s fps, frame %s ms (worst %s), %s draw calls, %sk triangles, cpu %s%%, %s MB, link %s" % [
			what, m.get("fps"), m.get("frame_ms"), m.get("worst_ms"), m.get("draw_calls"),
			int(m.get("primitives", 0)) / 1000, m.get("cpu"), m.get("rss_mb"), arena.replica.peer_link(id)])


## The moment `after` s from now: marked AHEAD before it, drawn at its game clock.
func _moment(name: String, after: float) -> void:
	await _wait(after - AHEAD)
	var at := arena.clock + AHEAD
	arena.mirror.mark(name, at)
	await arena.mirror.drawn(at)
	for k in [2, 4, 6]:
		var img: Image = arena.screen_wall.screen_viewport(k - 1).get_texture().get_image()
		img.save_png("%s/%s_master%d.png" % [out, name, k])
	print("TEST moment ", name)
	await _wait(0.3)


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout
