class_name DroneTile
extends CyberTile
## A mobile player's "tile" (players who can't stand on a floor tile - a
## wheelchair, blind players with a small 3D-printed tile in their hands, a
## tablet): the same game, the same LEDs, hearts, icons and shield as a floor
## tile, so every round works unchanged - but in the room it is a drone
## (models/drone.glb) flying in a ring above the floor tiles, so everyone sees
## who plays without a tile.
##   parked     no player: hovering high up near the wall, idle animation
##   flying in  registered / playing: it swoops down into the ring, where all
##              drones slowly orbit the robot, bobbing, nose to the robot
##   attack     it dips its nose; a bolt flies from it to the robot (no cable)
##   hit        the robot's bolt flies up to it: it rocks, drops and recovers
##   doomed     it stops in the air (the robot aims) and blinks red
##   death      electric arcs, then it spirals down trailing smoke and
##              explodes on the floor; it comes back parked once the player left
## Ids after the 13 floor tiles (14..18); `slot` is its place in the ring.

const DRONE_SCENE := preload("res://models/drone.glb")
const SLOTS := 5                 # drones in the ring (18 players at most)
const ORBIT_R := 3.3             # m from the robot: just behind the floor tiles ...
const ORBIT_Y := 2.45            # ... above the players' heads and their cameras
const ORBIT_SPEED := 0.09        # rad/s, the whole ring together
const PARK_R := 5.6              # parked: near the wall, high up
const PARK_Y := 3.4
const FLIGHT_TIME := 2.4         # s from the park into the ring (and back)
const BOLT_SPEED := 4.5          # m/s
const SCALE := 1.25              # the model a bit bigger than life: seen from across the room

var slot := 0
var arena: Arena                # for its clock (follows --fixed-fps) and the robot
var player_color := Color(0.2, 0.75, 1.0):   # the thruster glow
	set(c):
		player_color = c
		_glow()
var _rotors: Array[Node3D] = []
var _thruster: MeshInstance3D
var _band: MeshInstance3D        # light band around the rim
var _light: OmniLight3D          # the player's colour on the floor and walls nearby
var _flight := 0.0               # 0 parked .. 1 in the ring
var _wobble := Vector3.ZERO      # extra tilt (hits, attacks), radians
var _drop := 0.0                 # extra drop (hits), m
var _falling := false            # death: the fall drives the position
var _gone := false               # crashed: hidden until the player left


func _init() -> void:
	var model: Node3D = DRONE_SCENE.instantiate()
	model.name = "Model"                         # CyberTile._ready uses it
	model.scale = Vector3.ONE * SCALE
	add_child(model)


func _ready() -> void:
	super()
	for k in 4:
		_rotors.append(_model.find_child("Rotor_%d" % k, true, false) as Node3D)
	_thruster = _led("Thruster")
	_band = _led("Drone_Band")
	_light = OmniLight3D.new()
	_light.position = Vector3(0, -0.15, 0)
	_light.omni_range = 1.6
	add_child(_light)
	var dome := _shield.mesh as SphereMesh        # a bubble around the drone, not a dome over a tile
	dome.is_hemisphere = false
	dome.radius = 0.5
	dome.height = 0.62
	_shield.position.y = 0.0
	_place(0.0)
	_glow()


func _process(delta: float) -> void:
	super(delta)
	var active := (not idle or pending) and not _gone
	for r in _rotors:
		r.rotate_object_local(Vector3.UP, delta * (38.0 if active and not _falling else 9.0))
	if _gone and idle:                            # the player left after the crash: back in the park
		_gone = false
		_falling = false
		_flight = 0.0
		visible = installed
		_glow()
	if _falling or _doomed:
		return                                    # (the robot aims at where it is)
	_flight = move_toward(_flight, 1.0 if active else 0.0, delta / FLIGHT_TIME)
	_place(delta)


## In the air in the ring (or on its way): a player, not crashed (the hum: SoundBoard).
func is_flying() -> bool:
	return installed and visible and (not idle or pending) and not _gone


## Position on the way between the park and the ring, facing the robot.
func _place(_delta: float) -> void:
	var t: float = arena.clock if arena else 0.0
	var a0 := TAU * (slot + 0.5) / SLOTS
	var a := a0 + t * ORBIT_SPEED
	var f := smoothstep(0.0, 1.0, _flight)
	var park := Vector3(sin(a0) * PARK_R, PARK_Y + 0.04 * sin(t * 1.3 + slot), cos(a0) * PARK_R)
	var ring := Vector3(sin(a) * ORBIT_R, ORBIT_Y + 0.07 * sin(t * 1.7 + slot * 1.3), cos(a) * ORBIT_R)
	position = park.lerp(ring, f) + Vector3(0, sin(f * PI) * 0.5 - _drop, 0)   # (a swoop on the way)
	var to_robot := Vector3(-position.x, 0, -position.z).normalized()
	if to_robot.is_zero_approx():
		return
	basis = Basis.looking_at(to_robot, Vector3.UP) \
		* Basis.from_euler(Vector3(-0.16 + _wobble.x, 0, 0.1 * f + _wobble.z))   # nose down, banking into the orbit


func _glow() -> void:
	if _thruster == null:
		return
	var on := (not idle or pending) and not is_dead
	_paint(_thruster, player_color if on else player_color * 0.15)
	_paint(_band, player_color if on else Color(0.2, 0.25, 0.3))
	_light.light_color = player_color
	_light.light_energy = 1.4 if on else 0.0


func set_idle(on: bool) -> void:
	super(on)
	_glow()


func start_activation(color := Color.WHITE) -> void:
	super(color)
	player_color = color


func revive(lives := -1) -> void:
	super(lives)
	_glow()


## A bolt between the drone and the robot (the drone has no cable): from the
## drone (to_robot) or from the robot; on_arrive when it lands.
func send_bolt(color: Color, to_robot: bool, on_arrive := Callable()) -> void:
	var robot_point: Vector3 = arena.robot.global_position + Vector3(0, 1.0, 0) \
		+ Vector3(global_position.x, 0, global_position.z).normalized() * 0.45
	var from := global_position if to_robot else robot_point
	var bolt := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.05
	ball.height = 0.1
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 5.0
	ball.material = mat
	bolt.mesh = ball
	var light := OmniLight3D.new()
	light.light_color = color
	light.omni_range = 0.9
	light.light_energy = 2.5
	bolt.add_child(light)
	var trail := CPUParticles3D.new()             # a short glowing tail
	trail.amount = 24
	trail.lifetime = 0.25
	trail.local_coords = false
	trail.gravity = Vector3.ZERO
	trail.initial_velocity_min = 0.0
	trail.initial_velocity_max = 0.1
	var dot := SphereMesh.new()
	dot.radius = 0.025
	dot.height = 0.05
	dot.material = mat
	trail.mesh = dot
	var fade := Curve.new()
	fade.add_point(Vector2(0, 1))
	fade.add_point(Vector2(1, 0))
	trail.scale_amount_curve = fade
	bolt.add_child(trail)
	bolt.top_level = true
	add_child(bolt)
	bolt.global_position = from
	var travel := bolt.create_tween()
	var seconds := from.distance_to(robot_point if to_robot else global_position) / BOLT_SPEED
	travel.tween_method(func(k: float):            # (the drone moves: aim at where it is now)
		var to := robot_point if to_robot else global_position
		bolt.global_position = from.lerp(to, k), 0.0, 1.0, seconds)
	travel.tween_callback(func():
		bolt.queue_free()
		if on_arrive.is_valid():
			on_arrive.call())


## Attack: the ring sweep of a tile, and the drone dips its nose at the robot.
func play_attack(color := Color(0.2, 1.0, 0.3)) -> void:
	var tw := create_tween()
	tw.tween_property(self, "_wobble:x", -0.35, 0.12)
	tw.tween_property(self, "_wobble:x", 0.0, 0.5).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	await super(color)


## Hit: it rocks and drops, sparks fly off, then it recovers.
func play_hit(color := Color(1.0, 0.1, 0.05)) -> void:
	var side := 1.0 if randf() < 0.5 else -1.0
	var tw := create_tween().set_parallel()
	tw.tween_property(self, "_wobble:z", 0.55 * side, 0.08)
	tw.tween_property(self, "_drop", 0.35, 0.15)
	tw.chain().tween_property(self, "_wobble:z", 0.0, 0.9).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "_drop", 0.0, 0.8).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_sparks(color, 40)
	_puff()
	await super(color)


## Death: arcs, then a spiral down to the floor trailing smoke, and the
## explosion where it lands. Hidden until the player has left.
func play_death() -> void:
	_doomed = false
	is_dead = true
	shielded = false
	_falling = true
	_glow()
	await _electrocute(0.7)
	var start := position
	var a0 := atan2(start.x, start.z)
	var smoke := _smoke_trail()
	_glow_ball(Color(1.0, 0.4, 0.1), 0.2, 1.4, 0.5, 0.0)      # struck: a burst where it hangs
	_flash(Color(1.0, 0.5, 0.2), 8.0, 3.0, 0.05, 0.6, 0.0)
	var breaking := true                                      # pieces break off on the way down
	var shed := func():
		while breaking and is_inside_tree():
			_debris(3, 0.04, 0.4, 0.3, 0.0)
			await get_tree().create_timer(0.25).timeout
	shed.call()
	var fall := create_tween()
	fall.tween_method(func(k: float):
		var a := a0 + k * 2.6
		var r := lerpf(Vector2(start.x, start.z).length(), ORBIT_R + 0.6, k)
		position = Vector3(sin(a) * r, lerpf(start.y, 0.25, k * k), cos(a) * r)
		basis = Basis.from_euler(Vector3(0.6 * k, a * 3.0, 0.9 * k)), 0.0, 1.0, 1.7)
	fall.parallel().tween_method(func(v: float): fill_ring(Color(v, 0, 0)), 1.0, 0.0, 1.7)
	await fall.finished
	breaking = false
	smoke.emitting = false
	_fx_root = Node3D.new()                                   # the explosion stays when the drone hides
	get_parent().add_child(_fx_root)
	_fx_root.global_position = global_position
	var anchor := _fx_root
	get_tree().create_timer(3.0).timeout.connect(anchor.queue_free)
	_explode()
	_fx_root = null
	set_status(Color.RED)
	await get_tree().create_timer(0.15).timeout
	_gone = true
	visible = false
	await get_tree().create_timer(1.2).timeout


## Where a shot from the robot hits the bubble: its side towards the robot.
func _shield_impact() -> Vector3:
	var to_robot := to_local(Vector3(0, 1.6, 0)) - _shield.position
	return _shield.position + to_robot.normalized() * 0.3


## A small puff of smoke where it was hit.
func _puff() -> void:
	var smoke := CPUParticles3D.new()
	smoke.one_shot = true
	smoke.amount = 8
	smoke.lifetime = 1.2
	smoke.explosiveness = 0.9
	smoke.local_coords = false
	smoke.spread = 180.0
	smoke.initial_velocity_min = 0.2
	smoke.initial_velocity_max = 0.6
	smoke.gravity = Vector3(0, 0.3, 0)
	var puff := QuadMesh.new()
	puff.size = Vector2(0.3, 0.3)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _soft_texture([0.0, 1.0], [0.8, 0.0])
	puff.material = mat
	smoke.mesh = puff
	var grey := Gradient.new()
	grey.set_color(0, Color(0.4, 0.38, 0.36, 0.7))
	grey.set_color(1, Color(0.25, 0.25, 0.25, 0.0))
	smoke.color_ramp = grey
	add_child(smoke)
	smoke.emitting = true
	get_tree().create_timer(1.5).timeout.connect(smoke.queue_free)


func _sparks(color: Color, n: int) -> void:
	var sparks := CPUParticles3D.new()
	sparks.one_shot = true
	sparks.amount = n
	sparks.lifetime = 0.6
	sparks.explosiveness = 1.0
	sparks.spread = 180.0
	sparks.initial_velocity_min = 1.0
	sparks.initial_velocity_max = 2.5
	sparks.gravity = Vector3(0, -6.0, 0)
	var m := SphereMesh.new()
	m.radius = 0.012
	m.height = 0.024
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color.lerp(Color(1, 0.9, 0.5), 0.5)
	m.material = mat
	sparks.mesh = m
	add_child(sparks)
	sparks.emitting = true
	get_tree().create_timer(1.0).timeout.connect(sparks.queue_free)


func _smoke_trail() -> CPUParticles3D:
	var smoke := CPUParticles3D.new()
	smoke.amount = 40
	smoke.lifetime = 1.4
	smoke.local_coords = false
	smoke.gravity = Vector3(0, 0.3, 0)
	smoke.initial_velocity_min = 0.05
	smoke.initial_velocity_max = 0.2
	var puff := QuadMesh.new()
	puff.size = Vector2(0.22, 0.22)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	var soft := GradientTexture2D.new()            # round, soft-edged puffs
	soft.fill = GradientTexture2D.FILL_RADIAL
	soft.fill_from = Vector2(0.5, 0.5)
	soft.fill_to = Vector2(0.5, 0.0)
	var edge := Gradient.new()
	edge.set_color(0, Color(1, 1, 1, 1))
	edge.set_color(1, Color(1, 1, 1, 0))
	soft.gradient = edge
	mat.albedo_texture = soft
	puff.material = mat
	smoke.mesh = puff
	var grey := Gradient.new()
	grey.set_color(0, Color(0.3, 0.3, 0.3, 0.7))
	grey.set_color(1, Color(0.15, 0.15, 0.15, 0.0))
	smoke.color_ramp = grey
	var grow := Curve.new()
	grow.add_point(Vector2(0, 0.5))
	grow.add_point(Vector2(1, 2.0))
	smoke.scale_amount_curve = grow
	smoke.top_level = false
	add_child(smoke)
	smoke.emitting = true
	get_tree().create_timer(4.0).timeout.connect(smoke.queue_free)
	return smoke
