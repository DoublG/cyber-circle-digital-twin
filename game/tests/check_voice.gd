extends SceneTree
## Checks a folder of read-aloud files (tools/assets/make_voice.py): the narrator
## finds a playable file for every line of the list.
##   VOICE_DIR=/abs/dir LINES=/abs/voice_lines.csv godot-4 --headless --path godot --script res://tests/check_voice.gd
func _init() -> void:
	var dir := OS.get_environment("VOICE_DIR")
	var n := Narrator.new()
	n.extra_dir = dir
	var ok := 0
	var bad := []
	var f := FileAccess.open(OS.get_environment("LINES"), FileAccess.READ)
	f.get_line()
	while not f.eof_reached():
		var name := f.get_line().get_slice(";", 0)
		if name == "":
			continue
		var s: AudioStream = n._stream(name)
		if s and s.get_length() > 0.3:
			ok += 1
		else:
			bad.append(name)
	print("voice check: %d ok, %d missing %s" % [ok, bad.size(), bad])
	n.free()
	quit(1 if bad.size() else 0)
