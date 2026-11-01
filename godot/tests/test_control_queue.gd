extends Node
## The game's writes to the control server survive a restart: with the server
## unreachable they wait in the queue on disk, and a new ControlApi (the game
## started again) picks them up to send.

var fails := 0


func check(ok: bool, what: String) -> void:
	print(("  [ok] " if ok else "  [FAIL] ") + what)
	if not ok:
		fails += 1


func _ready() -> void:
	var a := ControlApi.new()
	a.base_url = "http://127.0.0.1:9"       # nobody there
	DirAccess.remove_absolute(ProjectSettings.globalize_path(a.queue_file()))
	add_child(a)
	a.open(a.base_url)
	var g := a.start_game()
	a.save_round(g, 1, "quiz", [{"tile": 1, "points": 1, "score": 1, "lives": 3}])
	a.save_result(g, {"player_id": 5, "tile": 1, "name": "Noor", "score": 1, "lives": 3, "rank": 1})
	check(a.pending() == 3, "3 writes waiting while the server is away: %d" % a.pending())
	check(FileAccess.file_exists(a.queue_file()), "kept on disk")
	a.queue_free()                         # the game stops
	await get_tree().process_frame
	var b := ControlApi.new()                # ... and starts again
	add_child(b)
	b.open("http://127.0.0.1:9")
	check(b.pending() == 3, "after the restart still 3 to send: %d" % b.pending())
	check(b.start_game() < g, "new temporary game ids don't clash with the waiting ones")
	var other := ControlApi.new()
	other.base_url = "http://127.0.0.1:10"
	check(other.queue_file() != b.queue_file(), "another server: another queue file")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(b.queue_file()))
	print("DONE: %d failure(s)" % fails)
	get_tree().quit(1 if fails else 0)
