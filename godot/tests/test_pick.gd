extends Node
## "Any free floor tile" fills the emptiest part of the circle: registrations
## without a tile spread out evenly over the 13 floor tiles, never a drone.
## Run: godot --headless --path . res://tests/test_pick.tscn

const ARENA := preload("res://scenes/arena.tscn")
var _fails := 0


func _ready() -> void:
	var arena: Node3D = ARENA.instantiate()
	add_child(arena)
	arena.game.use_database("")
	await get_tree().process_frame
	for round in 3:
		for id in arena.player_ids() + range(1, 19).filter(func(t): return arena.is_pending(t)):
			arena.leave(id)
		var got := []
		for n in 4:
			got.append(arena.register(0, "Speler %d" % n))
		got.sort()
		var gaps := []
		for i in got.size():
			var a: int = got[i]
			var b: int = got[(i + 1) % got.size()] + (13 if i == got.size() - 1 else 0)
			gaps.append(b - a)
		check(got.all(func(t): return t >= 1 and t <= 13), "only floor tiles: %s" % [got])
		check(gaps.min() >= 3, "4 players spread over the circle: %s (gaps %s)" % [got, gaps])
	for id in range(1, 19).filter(func(t): return arena.is_pending(t)):
		arena.leave(id)
	var all := []
	for n in 13:
		all.append(arena.register(0, "Vol %d" % n))
	all.sort()
	check(all == range(1, 14), "13 registrations: every floor tile once")
	check(arena.register(0, "Te veel") == 0, "the 14th: no floor tile left (drones are only assigned by hand)")
	print("DONE: %d failure(s)" % _fails)
	get_tree().quit()


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		_fails += 1
