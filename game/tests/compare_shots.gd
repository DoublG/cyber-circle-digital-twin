extends SceneTree
## Compares the master's and the display's screens (tests/run_mirror_test.sh):
## <moment>_master<k>.png against <moment>_screen<k>.png. Taken a few frames
## apart (animations, shader time): the mean difference must be small, not 0.
## Run: godot --headless --path . -s tests/compare_shots.gd -- DIR

func _init() -> void:
	var dir: String = OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() > 0 else "res://tests/shots/mirror"
	var fails := 0
	var pairs := 0
	var files := DirAccess.get_files_at(dir)
	for f in files:
		if not "_master" in f or not f.ends_with(".png"):
			continue
		var other := f.replace("_master", "_screen")
		if other not in files:
			print("MISSING ", other)
			fails += 1
			continue
		var a := Image.load_from_file(dir.path_join(f))
		var b := Image.load_from_file(dir.path_join(other))
		if a.get_size() != b.get_size():
			print("FAIL %s: size %s vs %s" % [f, a.get_size(), b.get_size()])
			fails += 1
			continue
		a.convert(Image.FORMAT_RGB8)
		b.convert(Image.FORMAT_RGB8)
		var da := a.get_data()
		var db := b.get_data()
		var total := 0
		var big := 0
		var step := 3 * 7                    # every 7th pixel: quick, plenty
		var n := 0
		for i in range(0, da.size() - 2, step):
			var d: int = maxi(maxi(absi(da[i] - db[i]), absi(da[i + 1] - db[i + 1])), absi(da[i + 2] - db[i + 2]))
			total += absi(da[i] - db[i]) + absi(da[i + 1] - db[i + 1]) + absi(da[i + 2] - db[i + 2])
			big += 1 if d > 64 else 0
			n += 1
		var mean := total / (3.0 * n)
		var share := 100.0 * big / n
		var ok := mean < 6.0 and share < 4.0           # (spinning rotors, typing texts: a frame apart)
		pairs += 1
		fails += 0 if ok else 1
		print("%s %s: mean diff %.2f/255, %.2f%% pixels differ a lot" % ["OK  " if ok else "FAIL", f.get_basename(), mean, share])
	print("%d pairs, %d failures" % [pairs, fails])
	quit(1 if fails > 0 or pairs == 0 else 0)
