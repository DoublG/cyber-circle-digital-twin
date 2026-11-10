extends SceneTree
## A round's per-player state (RoundState): every player their own, and to a
## display node and back as plain data (GameRound.replica_sync).
##   godot-4 --headless --path game --script res://tests/check_round_state.gd
var fails := 0


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		fails += 1


func _init() -> void:
	# every player their own state (the fields' lists and dictionaries are not shared)
	var a := RhythmRound.PlayerState.new()
	var b := RhythmRound.PlayerState.new()
	a.judged[3] = 2
	a.last[1] = {"at": 1.5, "text": "RAAK", "points": 2}
	check(b.judged.is_empty() and b.last[1].is_empty(), "a new state starts empty, whatever the others hold")
	check(a.to_dict().keys() == ["judged", "holds", "combo", "best_combo", "lines", "last"],
		"its fields as plain data: %s" % [a.to_dict().keys()])

	# master -> display node: plain data on the way, the same objects there
	var master := CodeRound.new()
	master.state[4] = CodeRound.PlayerState.new()
	master.state[4].level = 2
	master.state[4].guess = [0, 3]
	master.state[4].tries = [{"guess": [1, 1, 2], "marks": [2, 0, 1], "green": 1, "yellow": 1}]
	master.state[4].last = {"at": 7.0, "text": "1 GROEN  1 GEEL", "points": 0}
	var sync := master.replica_sync()
	check(sync.state[4] is Dictionary and sync.state[4].level == 2, "sent as plain data: %s" % [sync.state[4].keys()])
	check(Replica._clean(sync).state[4].tries.size() == 1, "nothing in it the network drops")
	var display := CodeRound.new()
	display.apply_replica_sync(sync.duplicate(true))
	var st: CodeRound.PlayerState = display.state.get(4)
	check(st != null and st.level == 2 and st.guess == [0, 3] and st.tries[0].green == 1
		and st.last.text == "1 GROEN  1 GEEL",
		"the display node has the same state, typed again")
	master.state[4].level = 3
	check(st.level == 2 and master.replica_sync().state[4].level == 3, "a change on the master: in the next update")

	# every round type that keeps one
	for type in RoundPicker.ROUND_TYPES:
		var r: GameRound = type.new()
		for field in r.state_fields():
			var s: RoundState = r.state_fields()[field].new()
			r.get(field)[1] = s
			var copy: GameRound = type.new()
			copy.apply_replica_sync(r.replica_sync())
			check(copy.get(field).has(1) and copy.get(field)[1].to_dict() == s.to_dict(),
				"%s.%s: there and back" % [RoundPicker.type_name(type), field])

	print("DONE: %d failure(s)" % fails)
	quit(1 if fails else 0)
