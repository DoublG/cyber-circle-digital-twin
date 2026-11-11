extends Node
## SETUP: the hearts of every tile (and drone) show its place number in
## binary - Heart_0 (nearest the logo) = 1 ... Heart_4 = 16; back to normal
## when the setup is locked.
## Run: godot --headless --path . res://tests/test_setup_hearts.tscn

const ARENA := preload("res://scenes/arena.tscn")
var _fails := 0


func _ready() -> void:
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	arena.game.use_database("")
	await get_tree().process_frame
	arena.game.modes.change(GameManager.Mode.SETUP)
	await get_tree().process_frame
	for t in arena.tiles:
		var lit := []
		for i in CyberTile.HEART_COUNT:
			lit.append(_lit(t, i))
		var want := []
		for i in CyberTile.HEART_COUNT:
			want.append(bool(t.tile_id >> i & 1))
		check(lit == want, "%s: hearts %s = %d" % [Retro.tile_label(t.tile_id), _pattern(lit), t.tile_id])
	arena.game.modes.change(GameManager.Mode.CLOSED)
	await get_tree().process_frame
	check(arena.tiles.all(func(t): return range(CyberTile.HEART_COUNT).all(func(i): return not _lit(t, i))),
		"setup locked: the hearts dark again (no players)")
	print("DONE: %d failure(s)" % _fails)
	get_tree().quit()


func _lit(t: CyberTile, i: int) -> bool:
	return (t._hearts[i].material_override as StandardMaterial3D).emission.is_equal_approx(CyberTile.HEART_COLOR)


func _pattern(lit: Array) -> String:
	return "".join(lit.map(func(on): return "♥" if on else "♡"))


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		_fails += 1
