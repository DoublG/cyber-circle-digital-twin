extends SceneTree
## The sound triggers: the music and drone loops (SoundBoard.play_loop), the
## quiz's right / wrong / countdown / TIJD OM, the UITSLAG, and the Ritme
## chart on the music's beat grid.
##   godot-4 --headless --path godot --script res://tests/check_sound_triggers.gd
var fails := 0


func check(ok: bool, what: String) -> void:
	print("    [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		fails += 1


func played(sound: SoundBoard, event: StringName, since: int) -> bool:
	return int(sound._last.get(event, -1)) >= since


func _init() -> void:
	# the chart on the beat grid (120 bpm: every symbol on a half beat, 0.25 s)
	var rr := RhythmRound.new()
	rr.music_bpm = 120.0
	var notes := rr.make_chart()
	var on_grid := notes.all(func(n): return absf(fmod(n.t, 0.25)) < 0.001 or absf(fmod(n.t, 0.25) - 0.25) < 0.001)
	check(notes.size() > 20 and on_grid, "Ritme at 120 bpm: all %d symbols on a half beat" % notes.size())
	var times := {}
	for n in notes:
		times[n.t] = times.get(n.t, 0) + 1
	check(times.values().all(func(c): return c <= 2), "never more than two symbols on one half beat")
	rr.music_bpm = 0.0
	check(rr.make_chart().any(func(n): return absf(fmod(n.t, 0.25)) > 0.01), "music_bpm 0: free timing")

	var arena: Arena = load("res://scenes/arena.tscn").instantiate()
	root.add_child(arena)
	await process_frame
	var game: GameManager = arena.game
	var sound: SoundBoard = arena.sound
	game.use_database("")
	game.modes.change(GameManager.Mode.OPEN)
	game.intro_time = 0.5
	for i in 5:
		await process_frame
	check(sound.playing_loop("music") == &"music_lobby", "the lobby: music_lobby loops")
	check(sound._loop_players.has("music") and sound._loop_players["music"].playing, "... and plays here (no displays)")
	check(sound.playing_loop("drones") == &"", "no drone in the air: no hum")

	# a mobile player: their drone flies in -> the hum
	arena.players.join(14, "Mo", 30)
	for i in 10:
		await process_frame
	check(sound.playing_loop("drones") == &"drone_hum", "a drone flies: drone_hum loops")

	# the quiz
	for i in 2:
		arena.players.join(i + 1, "Speler %d" % (i + 1), 30)
	game.picker.set_planned(0, "quiz")
	game.start_game()
	for n in 600:
		if game.state == GameManager.State.PLAYING and game.current is QuizRound:
			break
		await process_frame
	var q := game.current as QuizRound
	check(q != null, "a quiz round is playing")
	if q == null:
		quit(1)
		return
	check(sound.playing_loop("music") == &"", "no lobby music during a round")
	var t0 := Time.get_ticks_msec()
	q._phase = "question"
	q._phase_left = 4.5
	q._update(0.1)
	check(played(sound, &"countdown", t0), "the quiz's last seconds: countdown")
	q._phase_left = 0.05
	q._update(0.1)
	check(q._phase == "timeup" and played(sound, &"time_up", t0), "TIJD OM: time_up")
	var correct := int(q._questions[q._index].correct)
	q._answers = {1: {"answer": correct}, 2: {"answer": (correct + 1) % 4}}
	q._reveal()
	check(played(sound, &"quiz_right", t0), "someone right: quiz_right")
	await create_timer(2.0).timeout                 # the robot's counter-attack 1.6 s later
	check(played(sound, &"quiz_wrong", t0), "someone wrong: quiz_wrong (with the robot's counter-attack)")
	game._show_round_ranking({})
	check(played(sound, &"ranking", t0), "the UITSLAG: ranking")
	game.stop_game()
	await process_frame

	# Ritme: its music, from the round's start (everyone left with the stop)
	for i in 2:
		arena.players.join(i + 1, "Speler %d" % (i + 1), 30)
	game.picker.set_planned(0, "rhythm")
	game.start_game()
	for n in 600:
		if game.state == GameManager.State.PLAYING and game.current is RhythmRound:
			break
		await process_frame
	await process_frame
	check(game.current is RhythmRound and sound.playing_loop("music") == &"music_ritme", "Ritme: music_ritme")
	game.modes.change(GameManager.Mode.PAUSED)
	await process_frame
	check(sound.playing_loop("music") == &"", "paused: the music stops")
	game.modes.change(GameManager.Mode.OPEN)
	await process_frame
	var p: AudioStreamPlayer = sound._loop_players["music"]
	check(game.current is RhythmRound and sound.playing_loop("music") == &"music_ritme"
		and absf(p.get_playback_position() - (game.current as RhythmRound).clock) < 0.3,
		"resumed: from the round's clock (%.2f s / %.2f s)" % [p.get_playback_position(),
			(game.current as RhythmRound).clock])
	game.stop_game()
	arena.players.leave(14)                                 # (if still there)
	for i in 10:
		await process_frame
	check(sound.playing_loop("drones") == &"", "the drone's player left: the hum stops")

	print("DONE: %d failure(s)" % fails)
	quit(1 if fails else 0)
