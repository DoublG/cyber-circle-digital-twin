class_name RobotNpc
extends Node
## The robot is an NPC: nobody steers it over the network. It acts on the
## game's events - a player's press reaching it, an attack, an extermination,
## the phase of the game - on every node by itself: the master and each display
## node (Replica) run the same choreography here, from the same event.
##
## The master's game calls these with callbacks for what the moment means for
## the game (a life lost when the shot lands, the sounds and light cues, the
## next step of the extermination); the event goes to the display nodes
## without them (Replica.relay "npc"), so there the robot only acts.
## The tiles' part of a moment (the attack sweep, the hit, the block, the
## death) belongs to the choreography too: it is played here, not relayed.

var arena: Node3D
var robot: CyberRobot


func _ev(method: StringName, args: Array) -> void:
	Replica.relay("npc", method, args)


func _tile(id: int) -> CyberTile:
	return arena.tiles[id - 1]


func _side(id: int) -> int:
	return arena.robot_side(id)


# ---------------------------------------------------------------- players

## A press on a tile (with a player): its colour runs down the cable and the
## robot looks at the player when it arrives. On a display node a press on its
## own tiles (MQTT) plays at once, before the master knows.
func press(tile_id: int, color: Color) -> void:
	_ev(&"press", [tile_id, color])
	arena.packet(tile_id, color, func(): robot.look_at_side(_side(tile_id)))


## A player activated their tile: it flashes in their colour, the robot greets them.
func greet(tile_id: int, color: Color) -> void:
	_ev(&"greet", [tile_id, color])
	var tile := _tile(tile_id)
	tile.fill_ring(color)
	get_tree().create_timer(0.6).timeout.connect(func():
		if is_instance_valid(tile) and not tile.idle and not tile.is_dead:
			tile.clear_ring())
	arena.packet(tile_id, color, func(): robot.look_at_side(_side(tile_id)))


## A tile's good result (a round): its colour runs to the robot, that side glows.
## to_robot = false, glow = false: a red packet back from the robot (a miss).
func feedback(tile_id: int, color: Color, hold := 0.25, to_robot := true) -> void:
	_ev(&"feedback", [tile_id, color, hold, to_robot])
	if not to_robot:
		arena.packet(tile_id, color, Callable(), false)
		return
	arena.packet(tile_id, color, func():
		robot.set_side_glow(_side(tile_id), color, 2.0)
		await get_tree().create_timer(hold).timeout
		robot.set_side_glow(_side(tile_id), Color.BLACK))


# ---------------------------------------------------------------- attacks

## The players who got it right attack the robot together: the sweeps over
## their tiles, the packets to the robot, one combined hit (everyone: the overload).
func players_attack(tile_ids: Array, everyone := false, color := Color(0.2, 1.0, 0.3)) -> void:
	_ev(&"players_attack", [tile_ids, everyone, color])
	for id in tile_ids:
		_tile(id).play_attack(color)
	await get_tree().create_timer(0.35).timeout  # the sweeps reach the robot side
	var sides := tile_ids.map(func(id): return _side(id))
	var arrived := [0]
	var on_arrive := func():
		arrived[0] += 1
		if arrived[0] < tile_ids.size():
			return
		if everyone:  # last packet in: one combined hit
			robot.play_overload(color, sides)
		else:
			robot.take_hit(sides, color)
	for id in tile_ids:
		arena.packet(id, color, on_arrive)


## The robot attacks: it turns (one target), charges the sides facing all
## targets and fires down their cables; a shield blocks and bounces it back.
## on_charge / on_fire / on_land(id, blocked): the master's game.
func attack(targets: Array, color: Color, shielded: Array, on_charge := Callable(), on_fire := Callable(),
		on_land := Callable()) -> void:
	_ev(&"attack", [targets, color, shielded])
	if targets.size() == 1:                          # (look_at_point: also tilts the eye gun, e.g. up at a drone)
		robot.look_at_point(_tile(targets[0]).global_position)
		var wait := 0.0
		while not robot.is_facing_target() and wait < 4.0:
			await get_tree().process_frame
			wait += get_process_delta_time()
	if on_charge.is_valid():
		on_charge.call()
	await robot.charge_attack(targets.map(func(id): return _side(id)), color)
	if on_fire.is_valid():
		on_fire.call()
	for id in targets:
		var tile := _tile(id)
		var blocked: bool = id in shielded
		arena.packet(id, color, func():
			if blocked:
				tile.play_block(color)
				arena.packet(id, CyberTile.SHIELD_COLOR)   # bounced back to the robot
			else:
				tile.play_hit(color)
			if on_land.is_valid():
				on_land.call(id, blocked), false)


## The players about to be exterminated: the robot already turns to the first.
func aim(tile_id: int) -> void:
	_ev(&"aim", [tile_id])
	robot.lock_on(_side(tile_id))


func release() -> void:
	_ev(&"release", [])
	robot.release_head()


## Exterminated: the tile blinks red, the robot turns and fires (its death
## queue: several, one after the other), the tile's death animation.
## on_hit: the shot landed; on_done: the animation is over (the master's game).
func doom(tile_id: int, on_hit := Callable(), on_done := Callable()) -> void:
	_ev(&"doom", [tile_id])
	var tile := _tile(tile_id)
	tile.blink_doomed()
	robot.queue_death(_side(tile_id), tile.global_position + Vector3(0, 0.05, 0), func():
		if on_hit.is_valid():
			on_hit.call()
		await tile.play_death()
		if on_done.is_valid():
			on_done.call())


# ---------------------------------------------------------------- the game's phases

## lobby: its colours run round, it looks around; intro: the party lamp;
## playing: the chase; idle: nothing (the scoreboard: celebrate).
func mood(name: String) -> void:
	_ev(&"mood", [name])
	match name:
		"lobby":
			robot.set_bulb_effect("rainbow")
			robot.release_head()
		"intro":
			robot.set_party_lamp(true)
			robot.set_bulb_effect("rainbow")
		"playing":
			robot.set_bulb_effect("chase")


## The leader after a round: the robot turns to them, that side lit gold.
func celebrate(tile_id: int) -> void:
	_ev(&"celebrate", [tile_id])
	var side := _side(tile_id)
	robot.set_bulb_effect("none")
	robot.set_all_bulbs(Color.BLACK)
	robot.set_side_bulbs(side, Color(1.0, 0.75, 0.2))
	robot.look_at_side(side)


## The operator's direct robot commands ({"robot": "fire", ...}, Arena.apply_command).
func command(cmd: Dictionary) -> void:
	_ev(&"command", [cmd])
	match str(cmd.get("robot", "")):
		"head":
			robot.turn_head_to(float(cmd.angle))
		"fire":
			if cmd.has("tile"):
				robot.fire_at(_tile(int(cmd.tile)).global_position + Vector3(0, 0.05, 0))
			else:
				robot.fire()
		"release":
			robot.release_head()
		"look_at_tile":
			robot.look_at_side(_side(int(cmd.tile)))
		"bulb_effect":
			robot.set_bulb_effect(str(cmd.effect), float(cmd.get("speed", 1.0)))
		"bulbs":
			robot.set_bulb_effect("none")
			if cmd.has("side"):
				robot.set_side_bulbs(int(cmd.side), Color(cmd.color))
			else:
				robot.set_all_bulbs(Color(cmd.color))
		"dome":
			robot.set_dome_color(Color(cmd.color))
		"party":
			robot.set_party_lamp(bool(cmd.get("on", true)))
			if cmd.has("speed"):
				robot.set_party_spin_speed(float(cmd.speed))
		"spin":
			robot.idle_spin_deg = float(cmd.get("speed", robot.idle_spin_deg))
