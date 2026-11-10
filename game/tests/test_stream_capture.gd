extends Node
## The companion stream's capture (CompanionStream): started by a command,
## frames read back from the player's screen, kept alive, stopped by a
## command and by itself without a keep-alive. Frames go to a file here (the
## FFmpeg command line it builds is printed, for a test with FFmpeg).
##   godot --path . --disable-vsync res://tests/test_stream_capture.tscn -- --out=DIR

const ARENA := preload("res://scenes/arena.tscn")
var fails := 0


func check(ok: bool, what: String) -> void:
	print(("    [ok] " if ok else "    [FAIL] ") + what)
	fails += 0 if ok else 1


func _ready() -> void:
	var out := "/tmp"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	arena.game.use_database("")
	arena.sound.enabled = false
	arena.game.set_mode(GameManager.Mode.OPEN)
	await get_tree().create_timer(1.0).timeout
	check(arena.find_children("Stream_*", "", false, false).is_empty(), "no stream: nothing runs")
	arena.apply_command({"tile": 5, "join": "Lena"})
	await get_tree().create_timer(0.5).timeout
	var raw := out.path_join("frames.rgba")
	arena.apply_command({"stream": {"tile": 5, "on": true, "url": out.path_join("x.mp4"), "fps": 10, "file": raw}})
	await get_tree().create_timer(0.1).timeout
	var cs: CompanionStream = arena.streams.get(5)
	check(cs != null and cs._running, "started on a command")
	check(cs != null and cs._screen == 1, "T05's screen is screen 2 (%d)" % [cs._screen + 1 if cs else -1])
	print("ARGS ", " ".join(cs._args("h264_nvenc")))
	print("ARGS_X264 ", " ".join(cs._args("libx264")))
	print("SRC %dx%d" % [cs._src.x, cs._src.y])
	await get_tree().create_timer(2.0).timeout
	arena.apply_command({"stream": {"tile": 5, "on": true}})          # keep-alive
	check(arena.streams.get(5) == cs, "a keep-alive keeps the same stream")
	var frames := cs._frames
	check(frames >= 15, "frames written (%d in ~2 s at 10 fps)" % frames)
	arena.apply_command({"stream": {"tile": 5, "on": false}})
	await get_tree().create_timer(0.3).timeout
	check(not arena.streams.has(5) and arena.find_children("Stream_*", "", false, false).is_empty(),
		"stopped on a command: gone")
	cs = null
	arena.apply_command({"stream": {"tile": 5, "on": true, "fps": 5, "file": out.path_join("frames2.rgba")}})
	var cs2: CompanionStream = arena.streams.get(5)
	cs2._alive = CompanionStream.TIMEOUT - 0.5                        # (as if no keep-alive came for 30 s)
	await get_tree().create_timer(1.0).timeout
	check(not arena.streams.has(5), "without a keep-alive it stops by itself")
	print("FRAMES %d" % frames)
	print("DONE: %d failure(s)" % fails)
	get_tree().quit()
