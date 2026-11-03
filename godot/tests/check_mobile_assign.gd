extends SceneTree
## Fast assign to the mobile places (the gamemaster app's "ook mobiele plaatsen"):
## only when asked, a free floor tile first, then M1, M2 ...
##   godot-4 --headless --path godot --script res://tests/check_mobile_assign.gd
var fails := 0


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		fails += 1


func _init() -> void:
	var arena: Node3D = load("res://scenes/arena.tscn").instantiate()
	root.add_child(arena)
	await process_frame
	arena.game.use_database("")
	arena.game.set_mode(GameManager.Mode.OPEN)
	arena.set_installed([1, 14, 15, 16, 17, 18])       # one floor tile, the mobile places
	await process_frame
	check(arena.register(0, "Anna") == 1, "a free floor tile first (T01)")
	check(arena.register(0, "Bram") == 0, "no floor tile free, mobile off: nobody placed")
	check(arena.register(0, "Bram", Color.RED, 0, 0, true) == 14, "mobile on: M1")
	check(arena.register(0, "Cleo", Color.RED, 0, 0, true) == 15, "mobile on: then M2")
	arena.leave(1)
	check(arena.register(0, "Daan", Color.RED, 0, 0, true) == 1, "mobile on, a floor tile free again: the floor tile")
	arena.set_installed([14, 15, 16, 17, 18])          # no floor tiles at all
	await process_frame
	check(arena.register(0, "Eva") == 0, "only mobile places, mobile off: nobody placed (the gamemaster's choice)")
	check(arena.register(0, "Eva", Color.RED, 0, 0, true) == 16, "only mobile places, mobile on: the next free one (M3)")
	print("DONE: %d failure(s)" % fails)
	quit(1 if fails else 0)
