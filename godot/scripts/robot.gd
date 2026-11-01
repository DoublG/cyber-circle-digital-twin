class_name CyberRobot
extends Node3D
## Digital twin of the central robot. Wraps models/robot.glb.
## 13 sides (Side_00..12), one per tile: side k faces tile k+1. Side 0 faces -Z,
## then clockwise seen from above. Each side has 5 half-sphere lights,
## Bulb_{side * 5 + row} with row 0 at the bottom.
## The "Head" node is the rotating top (neck cage, eye, dome); it yaws around Y
## (0 = eye looking along -Z, i.e. at tile 1). When idle it spins continuously.
## The plunger (rod with black tip on the head) can fire at a tile.

signal fired(target: Vector3)
signal hit(target: Vector3)
signal death_finished(side: int)
signal hit_taken(side: int)

const ROBOT_SCENE := preload("res://models/robot.glb")
const PARTY_DOME_SHADER := preload("res://shaders/party_dome.gdshader")
const SIDE_COUNT := 13
const BULBS_PER_SIDE := 5
const BULB_COUNT := SIDE_COUNT * BULBS_PER_SIDE

@export var head_speed_deg := 120.0   # max turn speed for turn_head_to / look_at_point
@export var idle_spin_deg := 30.0      # idle spin speed of the top (deg/s, 0 = stop)
@export var hold_after_target := 2.0   # seconds to keep facing a target before spinning again
@export var shot_speed := 6.0          # m/s of the plunger shot
@export var death_color := Color.RED   # colour of the 5 half spheres in the death animation
@export var party_lamp := true: set = set_party_lamp   # rotating colours inside the dome
@export var party_spin_speed := 0.6: set = set_party_spin_speed  # rad/s
## Built-in light show on the half spheres (each has an RGB light behind it).
@export_enum("none", "rainbow", "chase", "pulse") var bulb_effect := "rainbow"
@export var bulb_effect_speed := 1.0

var head: Node3D
var _model: Node3D
var _target_yaw := 0.0
var _has_target := false
var _hold := 0.0
var _locked := false             # lock_on: keep facing the target until the next action
var _plunger_parts: Array[Node3D] = []  # Eye_Tip, Eye_Lens, Eye_Fins: kick back when firing
var _hits := 0                          # hit animations running
var _head_locked := false               # an animation drives the head directly
var _effect_before_hit := ""
var _death_queue: Array[Dictionary] = []
var _death_running := false
var _plunger_rest := {}                 # part -> resting position
var _plunger_lens: Node3D
var _muzzle_light: OmniLight3D
var _bulbs: Array[MeshInstance3D] = []
var _sides: Array[MeshInstance3D] = []
var _dome_light: OmniLight3D
var _dome_mat: ShaderMaterial
var _party_time := 0.0
var _effect_time := 0.0
var _anim: AnimationPlayer


func _ready() -> void:
	# the scene has the model as child "Model" (visible in the editor);
	# fall back to instancing it when the script is used on its own
	_model = get_node_or_null("Model")
	if _model == null:
		_model = ROBOT_SCENE.instantiate()
		add_child(_model)
	head = _model.find_child("Head", true, false)
	_anim = _model.find_child("AnimationPlayer", true, false)
	for i in BULB_COUNT:
		_bulbs.append(_make_led(_model.find_child("Bulb_%02d" % i, true, false)))
	for k in SIDE_COUNT:
		var side := _model.find_child("Side_%02d" % k, true, false) as MeshInstance3D
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.62, 0.52, 0.30)
		mat.metallic = 0.6
		mat.roughness = 0.45
		mat.emission_enabled = true
		mat.emission = Color.BLACK
		side.material_override = mat
		_sides.append(side)
	var dome := _model.find_child("Dome", true, false) as MeshInstance3D
	_dome_mat = ShaderMaterial.new()
	_dome_mat.shader = PARTY_DOME_SHADER
	dome.material_override = _dome_mat
	_dome_light = OmniLight3D.new()
	_dome_light.position = dome.position + Vector3(0, 0.1, 0)
	_dome_light.omni_range = 1.5
	_dome_light.light_energy = 0.0
	head.add_child(_dome_light)
	set_party_lamp(party_lamp)
	set_party_spin_speed(party_spin_speed)
	for part in ["Eye_Tip", "Eye_Lens", "Eye_Fins"]:
		var node := _model.find_child(part, true, false) as Node3D
		_plunger_parts.append(node)
		_plunger_rest[node] = node.position
	_plunger_lens = _model.find_child("Eye_Lens", true, false)
	_muzzle_light = OmniLight3D.new()
	_muzzle_light.light_color = Color(1.0, 0.3, 0.1)
	_muzzle_light.omni_range = 1.2
	_muzzle_light.light_energy = 0.0
	_plunger_lens.add_child(_muzzle_light)


func _process(delta: float) -> void:
	if _head_locked:
		if bulb_effect != "none":
			_effect_time += delta * bulb_effect_speed
			_run_bulb_effect()
		return
	if party_lamp:
		# the lamp spills a slowly changing colour around the head
		_party_time += delta
		_dome_light.light_color = Color.from_hsv(fmod(_party_time * 0.1, 1.0), 0.7, 1.0)
	if _has_target:
		var diff := wrapf(_target_yaw - head.rotation.y, -PI, PI)
		var step := deg_to_rad(head_speed_deg) * delta
		head.rotation.y += clampf(diff, -step, step)
		if absf(diff) < 0.01:
			_hold += delta
			if hold_after_target >= 0.0 and _hold > hold_after_target and not _locked:
				_has_target = false
	elif not (_anim and _anim.is_playing()):
		head.rotation.y = wrapf(head.rotation.y - deg_to_rad(idle_spin_deg) * delta, -PI, PI)
	if bulb_effect != "none":
		_effect_time += delta * bulb_effect_speed
		_run_bulb_effect()


## Pick a light show for the half spheres; "none" leaves them to set_bulb() calls.
func set_bulb_effect(effect: String, speed := 1.0) -> void:
	bulb_effect = effect
	bulb_effect_speed = speed
	if effect == "none":
		set_all_bulbs(Color.BLACK)


func _run_bulb_effect() -> void:
	var t := _effect_time
	for side in SIDE_COUNT:
		for row in BULBS_PER_SIDE:
			var c := Color.BLACK
			match bulb_effect:
				"rainbow":  # colours wander around the robot and up the sides
					c = Color.from_hsv(fmod(float(side) / SIDE_COUNT + row * 0.04 + t * 0.15, 1.0), 0.9, 1.0)
				"chase":  # one lit column runs around, colour changes per lap
					var pos := fmod(t * 4.0, SIDE_COUNT)
					var dist := absf(wrapf(side - pos, -SIDE_COUNT / 2.0, SIDE_COUNT / 2.0))
					c = Color.from_hsv(fmod(floor(t * 4.0 / SIDE_COUNT) * 0.17, 1.0), 0.9, clampf(1.0 - dist / 2.0, 0.0, 1.0))
				"pulse":  # whole robot breathes through the colours
					c = Color.from_hsv(fmod(t * 0.1, 1.0), 0.8, 0.5 + 0.5 * sin(t * 3.0))
			set_side_bulb(side, row, c)


# ---------------------------------------------------------------- head

## Turn smoothly to a yaw angle in degrees (0 = front, positive = turn left).
func turn_head_to(deg: float) -> void:
	_target_yaw = deg_to_rad(deg)
	_has_target = true
	_hold = 0.0


## Jump instantly (use when mirroring a real encoder value).
func set_head_angle(deg: float) -> void:
	head.rotation.y = deg_to_rad(deg)
	_target_yaw = head.rotation.y
	_has_target = true


## Direction (robot-local, horizontal) that side k / tile k+1 is in.
static func side_direction(side: int) -> Vector3:
	var a := PI / 2 - TAU * side / SIDE_COUNT
	return Vector3(cos(a), 0, -sin(a))


## Head yaw (radians) that points the eye at the centre of side k's flat plate.
static func side_yaw(side: int) -> float:
	var d := side_direction(side)
	return atan2(-d.x, -d.z)


## Side whose plate centre is closest to a head yaw (radians).
static func nearest_side(yaw: float) -> int:
	return posmod(roundi(-yaw / TAU * SIDE_COUNT), SIDE_COUNT)


func look_at_side(side: int) -> void:
	_target_yaw = side_yaw(side)
	_has_target = true
	_hold = 0.0


func look_at_point(global_point: Vector3) -> void:
	var p := to_local(global_point)
	_target_yaw = atan2(-p.x, -p.z)
	_has_target = true
	_hold = 0.0


## Turn to a side and stay on it (e.g. the first one to be exterminated,
## while the scores come up) until release_head() or the death queue.
func lock_on(side: int) -> void:
	look_at_side(side)
	_locked = true


func release_head() -> void:
	_has_target = false
	_locked = false


## Plays the baked "HeadSpin" or "HeadScan" animation from the glb.
func play_head_animation(anim_name: StringName) -> void:
	_has_target = false
	if _anim:
		_anim.play(anim_name)


func is_facing_target() -> bool:
	return _has_target and absf(wrapf(_target_yaw - head.rotation.y, -PI, PI)) < 0.02


# ---------------------------------------------------------------- plunger

## Turn to a world position, then fire the plunger at it.
func fire_at(global_target: Vector3) -> void:
	look_at_point(global_target)
	while not is_facing_target():
		await get_tree().process_frame
	fire(global_target)


func fire_at_side(side: int) -> void:
	look_at_side(side)
	while not is_facing_target():
		await get_tree().process_frame
	fire(global_position + side_direction(side) * 2.0)


## Fire straight ahead of the eye (or at `global_target` if given).
func fire(global_target = null, on_hit := Callable()) -> void:
	var from := _plunger_lens.global_position
	var forward := -head.global_basis.z
	var to: Vector3 = global_target if global_target != null else from + forward * 3.0
	_hold = 0.0
	fired.emit(to)

	# recoil: the tip kicks back along the rod and springs out again
	var recoil := head.global_basis.z * 0.06
	for part in _plunger_parts:
		var rest: Vector3 = _plunger_rest[part]
		var kick: Vector3 = part.get_parent().global_basis.inverse() * recoil
		var tw := create_tween()
		tw.tween_property(part, "position", rest + kick, 0.04)
		tw.tween_property(part, "position", rest, 0.25).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)

	# muzzle flash
	var flash := create_tween()
	_muzzle_light.light_energy = 6.0
	flash.tween_property(_muzzle_light, "light_energy", 0.0, 0.25)

	# glowing shot flying to the target
	var shot := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.03
	ball.height = 0.06
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.4, 0.1)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.4, 0.1)
	mat.emission_energy_multiplier = 4.0
	ball.material = mat
	shot.mesh = ball
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.4, 0.1)
	glow.omni_range = 0.6
	glow.light_energy = 2.0
	shot.add_child(glow)
	shot.top_level = true
	add_child(shot)
	shot.global_position = from
	var travel := create_tween()
	travel.tween_property(shot, "global_position", to, from.distance_to(to) / shot_speed)
	travel.tween_callback(func():
		shot.queue_free()
		if on_hit.is_valid():
			on_hit.call()
		hit.emit(to))


# ---------------------------------------------------------------- hits

## Combined attack of the players (1-13 sides at once) reached the robot: the
## attacking sides flash, the head shakes harder the more attackers there are,
## and the dome lights up.
func take_hit(sides: Array, color := Color(0.2, 1.0, 0.3)) -> void:
	for side in sides:
		hit_taken.emit(side)
	if _death_running:  # don't disturb a death animation, only flash the dome
		_flash_dome(color)
		return
	_begin_fx()
	_flash_dome(color)
	var amount := 0.05 + 0.012 * sides.size()
	var shake := create_tween()
	shake.tween_property(head, "rotation:z", amount, 0.05)
	shake.tween_property(head, "rotation:z", -amount * 0.8, 0.08)
	shake.tween_property(head, "rotation:z", amount * 0.4, 0.08)
	shake.tween_property(head, "rotation:z", 0.0, 0.08)
	for n in 3:
		for side in sides:
			set_side_bulbs(side, color)
		await get_tree().create_timer(0.12).timeout
		for side in sides:
			set_side_bulbs(side, Color.BLACK)
		await get_tree().create_timer(0.08).timeout
	_end_fx()


## Everyone answered correctly: the robot overloads. Green waves race around
## all 13 sides, the top spins wildly while the dome strobes, then the robot
## powers down for a moment and reboots.
func play_overload(color := Color(0.2, 1.0, 0.3), sides: Array = []) -> void:
	for side in sides:
		hit_taken.emit(side)
	if _death_running:
		return
	_begin_fx()
	_head_locked = true
	var spin := create_tween()
	spin.tween_property(head, "rotation:y", head.rotation.y + TAU * 3.0, 2.4) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	for wave in 3:  # three green waves around the robot
		for side in SIDE_COUNT:
			set_side_bulbs(side, color)
			set_side_bulbs(posmod(side - 3, SIDE_COUNT), Color.BLACK)
			if side % 2 == 0:
				_flash_dome(Color.from_hsv(randf(), 0.6, 1.0))
			await get_tree().create_timer(0.05).timeout
	for n in 4:  # everything strobes
		set_all_bulbs(color)
		_flash_dome(Color.WHITE)
		await get_tree().create_timer(0.08).timeout
		set_all_bulbs(Color.BLACK)
		await get_tree().create_timer(0.08).timeout
	# power down ... and reboot side by side
	var party := party_lamp
	set_party_lamp(false)
	await get_tree().create_timer(1.0).timeout
	for side in SIDE_COUNT:
		set_side_bulbs(side, Color(0.3, 0.3, 0.3))
		await get_tree().create_timer(0.04).timeout
	set_party_lamp(party)
	head.rotation.y = wrapf(head.rotation.y, -PI, PI)
	_head_locked = false
	release_head()
	_end_fx()


## Before a combined counter-attack: the sides facing the targets charge up in
## `color` from bottom to top while the dome flashes. Returns when it can fire.
func charge_attack(sides: Array, color := Color(1.0, 0.1, 0.05)) -> void:
	if _death_running:
		return
	_begin_fx()
	_flash_dome(color)
	for row in BULBS_PER_SIDE:
		for side in sides:
			set_side_bulb(side, row, color)
		await get_tree().create_timer(0.07).timeout
	await get_tree().create_timer(0.15).timeout
	for side in sides:
		set_side_bulbs(side, Color.BLACK)
	_end_fx()


## Light effects pause while hit/attack animations use the half spheres.
func _begin_fx() -> void:
	if _hits == 0:
		_effect_before_hit = bulb_effect
		set_bulb_effect("none")
	_hits += 1


func _end_fx() -> void:
	_hits -= 1
	if _hits == 0 and not _death_running:
		set_bulb_effect(_effect_before_hit)


func _flash_dome(color: Color) -> void:
	# (with the party lamp on, _process takes the colour back over)
	var energy := _dome_light.light_energy
	_dome_light.light_color = color
	_dome_light.light_energy = 5.0
	create_tween().tween_property(_dome_light, "light_energy", energy, 0.5)


# ---------------------------------------------------------------- death

## Death animation. Several players can die at the same moment: every victim
## is queued, the 5 half spheres on each victim's side light up together, and
## the head visits the victims one by one (shortest turn first). For each one it
## turns to one of the 13 fixed positions (the centre of that side's flat plate),
## blinks that side and fires the plunger at `global_target` (default: in front
## of the side). `on_hit` is called at impact, e.g. to start the tile's effect.
## When the queue is empty the robot goes back to normal.
func queue_death(side: int, global_target = null, on_hit := Callable()) -> void:
	side = posmod(side, SIDE_COUNT)
	var to: Vector3 = global_target if global_target != null else global_position + side_direction(side) * 2.2
	for v in _death_queue:
		if v.target.distance_to(to) < 0.05:
			return  # already queued (a drone can share a side with a floor tile)
	_death_queue.append({"side": side, "target": to, "on_hit": on_hit})
	if not _death_running:
		_run_deaths()
	else:
		_light_victim(side)  # a late victim lights up straight away


## Kill several sides at once, e.g. play_deaths([0, 4, 7]).
func play_deaths(sides: Array) -> void:
	for side in sides:
		queue_death(int(side))


## Single victim (kept for convenience).
func play_death(side: int, global_target = null) -> void:
	queue_death(side, global_target)


func _run_deaths() -> void:
	_death_running = true
	_locked = false
	var prev_effect := bulb_effect
	var prev_hold := hold_after_target
	hold_after_target = -1.0  # stay locked on each victim
	set_bulb_effect("none")
	set_all_bulbs(Color.BLACK)
	# short window so players dying "at the same moment" light up together
	await get_tree().create_timer(0.05).timeout
	for v in _death_queue:
		_light_victim(v.side)
	await get_tree().create_timer(0.12 * BULBS_PER_SIDE + 0.2).timeout

	while true:
		while not _death_queue.is_empty():
			var v: Dictionary = _death_queue[0]  # nearest victim to the current head angle
			for c in _death_queue:
				if _turn_distance(c.side) < _turn_distance(v.side):
					v = c
			_death_queue.erase(v)
			look_at_side(v.side)
			while not is_facing_target():
				await get_tree().process_frame
			head.rotation.y = side_yaw(v.side)  # land exactly on the plate centre
			for n in 2:
				set_side_bulbs(v.side, Color.BLACK)
				await get_tree().create_timer(0.15).timeout
				set_side_bulbs(v.side, death_color)
				await get_tree().create_timer(0.15).timeout
			var landed := [false]
			fire(v.target, func(): landed[0] = true)
			while not landed[0]:
				await get_tree().process_frame
			if v.on_hit.is_valid():
				v.on_hit.call()
			death_finished.emit(v.side)
			await get_tree().create_timer(0.4).timeout
		# victims that die during the pause are still handled
		await get_tree().create_timer(2.5).timeout
		if _death_queue.is_empty():
			break
	_death_running = false
	hold_after_target = prev_hold
	set_bulb_effect(prev_effect)
	release_head()


## Light the 5 half spheres of a victim's side bottom to top.
func _light_victim(side: int) -> void:
	for row in BULBS_PER_SIDE:
		set_side_bulb(side, row, death_color)
		await get_tree().create_timer(0.12).timeout


func _turn_distance(side: int) -> float:
	return absf(wrapf(side_yaw(side) - head.rotation.y, -PI, PI))


func get_head_angle() -> float:
	return rad_to_deg(head.rotation.y)


# ---------------------------------------------------------------- lights

func set_bulb(index: int, color: Color) -> void:
	_paint(_bulbs[posmod(index, BULB_COUNT)], color)


func set_side_bulb(side: int, row: int, color: Color) -> void:
	set_bulb(side * BULBS_PER_SIDE + row, color)


## Light all 5 half spheres of one side (e.g. the side facing an active tile).
func set_side_bulbs(side: int, color: Color) -> void:
	for row in BULBS_PER_SIDE:
		set_side_bulb(side, row, color)


## Tint / glow a whole side plate (Color.BLACK = normal gold).
func set_side_glow(side: int, color: Color, energy := 1.0) -> void:
	var mat := _sides[posmod(side, SIDE_COUNT)].material_override as StandardMaterial3D
	mat.emission = color
	mat.emission_energy_multiplier = energy


## Note: set_bulb/set_side_bulbs are overwritten while a bulb_effect is running;
## call set_bulb_effect("none") first when mirroring the real robot.
func set_all_bulbs(color: Color) -> void:
	for b in _bulbs:
		_paint(b, color)


## Party lamp inside the dome: coloured spots rotating on the inside of the dome.
func set_party_lamp(on: bool) -> void:
	party_lamp = on
	if _dome_mat == null:  # not built yet; _ready() applies it
		return
	_dome_mat.set_shader_parameter("enabled", on)
	_dome_light.light_energy = 0.8 if on else 0.0


func set_party_spin_speed(rad_per_s: float) -> void:
	party_spin_speed = rad_per_s
	if _dome_mat != null:
		_dome_mat.set_shader_parameter("spin_speed", rad_per_s)


## Plain dome colour instead of the party lamp (Color.BLACK = off).
func set_dome_color(color: Color, energy := 2.0) -> void:
	set_party_lamp(false)
	_dome_light.light_color = color
	_dome_light.light_energy = energy if color.v > 0.01 else 0.0


# ---------------------------------------------------------------- internals

## Frosted half sphere with an RGB light behind it.
func _make_led(mi: MeshInstance3D) -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.9, 0.93)
	mat.roughness = 0.45
	mat.rim_enabled = true  # brighter frosted edge
	mat.rim = 0.4
	mat.emission_enabled = true
	mat.emission = Color.BLACK
	mat.emission_energy_multiplier = 2.5
	mi.material_override = mat
	return mi


func _paint(mi: MeshInstance3D, color: Color) -> void:
	var mat := mi.material_override as StandardMaterial3D
	mat.emission = color
	mat.albedo_color = Color(0.9, 0.9, 0.93).lerp(color, 0.5 * color.v)
