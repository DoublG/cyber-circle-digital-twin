class_name ModeSwitch
extends RefCounted
## The operating mode (GameManager.Mode; GameManager.modes) and the robot's
## shows that go with it: it comes to life when the game opens (CLOSED / SETUP
## -> OPEN) and is shut down - the players won - when it closes (-> CLOSED).
## Closing during a round waits for its end (its scoreboard): close_pending.

var game: GameManager
var power_show := ""              # "boot" / "shutdown" while one plays
var close_pending := false        # a close was asked during a round: after its scoreboard
var _closing_now := false         # (the round is over: close for real)
var _mode_set := false            # (the first mode from the control server: no show, just on / off)


func _init(game_node: GameManager) -> void:
	game = game_node


func name() -> String:
	return GameManager.Mode.keys()[game.mode].to_lower()


## Players can register and join only while the game is open.
func accepting_players() -> bool:
	return game.mode == GameManager.Mode.OPEN and not close_pending


## Operator: change the operating mode (see GameManager.Mode).
func change(m: GameManager.Mode) -> void:
	var arena := game.arena
	var first := not _mode_set
	_mode_set = true
	if m == GameManager.Mode.OPEN and close_pending:   # (closing after the round: called off)
		close_pending = false
		game.log_event("SLUITEN GEANNULEERD", Retro.AMBER)
	if m == game.mode:
		if first and m == GameManager.Mode.CLOSED:
			arena.npc.power(false)
		return
	var was := game.mode
	if m == GameManager.Mode.CLOSED and was == GameManager.Mode.OPEN and not first and not _closing_now \
			and game.state in [GameManager.State.PLAYING, GameManager.State.SCOREBOARD]:
		_close_after_round()
		return
	close_pending = false
	game.mode = m
	match m:
		GameManager.Mode.SETUP, GameManager.Mode.CLOSED:
			if game.state != GameManager.State.LOBBY or not arena.players.player_ids().is_empty():
				game.stop_game()             # everyone out, results saved
			_cancel_invites()
		GameManager.Mode.PAUSED:
			_pause_tiles(true)
		GameManager.Mode.OPEN:
			if was == GameManager.Mode.PAUSED:
				_pause_tiles(false)
	for t in arena.tiles:                # setup: every tile's hearts show its number (binary)
		t.show_number = m == GameManager.Mode.SETUP
	game.log_event({GameManager.Mode.SETUP: "SETUP", GameManager.Mode.CLOSED: "SPEL GESLOTEN",
		GameManager.Mode.OPEN: "SPEL OPEN", GameManager.Mode.PAUSED: "PAUZE"}[m], Retro.AMBER)
	game.screen_wall.refresh_all()
	game.mode_changed.emit(m)
	game.on_players_changed()            # (nobody left: the lobby's countdown stops there)
	if first:                            # (the game starting: the robot as the mode says, no show)
		arena.npc.power(m != GameManager.Mode.CLOSED)
	elif m == GameManager.Mode.OPEN and was in [GameManager.Mode.CLOSED, GameManager.Mode.SETUP]:
		_power("boot")
	elif m == GameManager.Mode.CLOSED and was in [GameManager.Mode.OPEN, GameManager.Mode.PAUSED]:
		_power("shutdown")
	elif m == GameManager.Mode.SETUP and not arena.robot.powered:
		arena.npc.power(true)            # (setting up: the robot on, to test it)


## A close was asked during a round: now it is over.
func close_now() -> void:
	close_pending = false
	_closing_now = true
	change(GameManager.Mode.CLOSED)
	_closing_now = false


## The web interface's test buttons: the show, the mode stays (after a test
## shutdown the robot comes back on by itself when the game is open).
func play_show(kind: String) -> void:
	if power_show != "" or game.state != GameManager.State.LOBBY:
		return                           # (not during a round or another show)
	_power(kind)
	if kind == "shutdown" and game.mode != GameManager.Mode.CLOSED:
		await game.arena.robot.power_moment
		while power_show != "":
			await game.get_tree().process_frame
		await game.wait(3.0)
		if game.mode != GameManager.Mode.CLOSED and not game.arena.robot.powered and power_show == "":
			_power("boot")


## The robot's moments in a show (CyberRobot.power_moment): the sounds and the
## light cues follow them, and the screens go back to the players at its end.
func on_power_moment(moment: StringName) -> void:
	var arena := game.arena
	if Replica.client:
		return
	match moment:
		&"awake":
			arena.cue(&"boot_done")
		&"electrocuted":
			for i in 5:                  # zaps all over the room while it shakes
				game.get_tree().create_timer(i * 1.3 + randf() * 0.4).timeout.connect(_zap)
		&"dying":
			arena.cue(&"power_down")
		&"booted", &"off":
			if moment == &"off":
				arena.cue(&"off")
				await game.wait(7.0)     # (GEWONNEN on the screens a while)
				if power_show != "shutdown":
					return
			power_show = ""
			if game.views.is_kind("power"):
				game.views.show({"kind": "players"})
			game.screen_wall.refresh_all()


## Closing during a round: the round first - closed (and the robot shut down) after it.
func _close_after_round() -> void:
	if close_pending:
		return                           # (the same again: the retained mode, a reconnect)
	close_pending = true
	_cancel_invites()                    # (no new players meanwhile)
	game.log_event("SPEL SLUIT NA DEZE RONDE", Retro.AMBER)
	game.mode_changed.emit(game.mode)


func _cancel_invites() -> void:
	for id in game.arena.players.pending_ids():
		game.arena.players.leave(id)


## The robot's show (also from the web interface: {"game": "boot" | "shutdown"},
## without changing the mode). The screens show it (PowerView).
func _power(kind: String) -> void:
	var arena := game.arena
	power_show = kind
	game.views.show({"kind": "power", "show": kind, "at": arena.clock})
	if kind == "boot":
		arena.npc.boot()
		arena.cue(&"boot")
	else:
		arena.npc.shutdown()
		arena.cue(&"shutdown")


func _zap() -> void:
	if power_show == "shutdown":
		game.arena.cue(&"zap", randi_range(1, game.arena.tiles.size()))


func _pause_tiles(on: bool) -> void:
	var current := game.current
	if current and current.on_tile:
		for id in current.players:
			game.arena.send_to_tile(id, {"pause": on})
