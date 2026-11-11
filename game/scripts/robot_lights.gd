class_name RobotLights
extends RefCounted
## The robot's lights (CyberRobot.lights): the 5 half spheres on each of its 13
## sides (an RGB light behind each: Bulb_{side * 5 + row}, row 0 at the
## bottom), the side plates' glow, and the dome with its party lamp.

const PARTY_DOME_SHADER := preload("res://shaders/party_dome.gdshader")
const SIDES := 13
const ROWS := 5

## Built-in light show on the half spheres: none / rainbow / chase / pulse.
var effect := "rainbow"
var effect_speed := 1.0
var party_lamp := true            # rotating colours inside the dome
var dome: OmniLight3D             # the dome's light (a show sets it directly)

var _bulbs: Array[MeshInstance3D] = []
var _sides: Array[MeshInstance3D] = []
var _dome_mat: ShaderMaterial


func _init(model: Node3D, head: Node3D) -> void:
	for i in SIDES * ROWS:
		_bulbs.append(_make_led(model.find_child("Bulb_%02d" % i, true, false)))
	for k in SIDES:
		var side := model.find_child("Side_%02d" % k, true, false) as MeshInstance3D
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.62, 0.52, 0.30)
		mat.metallic = 0.6
		mat.roughness = 0.45
		mat.emission_enabled = true
		mat.emission = Color.BLACK
		side.material_override = mat
		_sides.append(side)
	var dome_mesh := model.find_child("Dome", true, false) as MeshInstance3D
	_dome_mat = ShaderMaterial.new()
	_dome_mat.shader = PARTY_DOME_SHADER
	dome_mesh.material_override = _dome_mat
	dome = OmniLight3D.new()
	dome.position = dome_mesh.position + Vector3(0, 0.1, 0)
	dome.omni_range = 1.5
	dome.light_energy = 0.0
	head.add_child(dome)


## Every frame: the light show at the game's clock (the master's on every
## display node, so all of them show the same colours); dome_cycles: the party
## lamp spills a slowly changing colour around the head.
func update(clock: float, dome_cycles: bool) -> void:
	_dome_mat.set_shader_parameter("clock", fmod(clock, 3600.0))
	if dome_cycles and party_lamp:
		dome.light_color = Color.from_hsv(fmod(clock * 0.1, 1.0), 0.7, 1.0)
	if effect != "none":
		_run_effect(clock * effect_speed)


## Pick a light show for the half spheres; "none" leaves them to the
## set_side_bulb(s) / set_all_bulbs calls (a running show overwrites those).
func set_effect(name: String, speed := 1.0) -> void:
	effect = name
	effect_speed = speed
	if name == "none":
		set_all_bulbs(Color.BLACK)


func set_side_bulb(side: int, row: int, color: Color) -> void:
	_paint(_bulbs[posmod(side * ROWS + row, SIDES * ROWS)], color)


## Light all 5 half spheres of one side (e.g. the side facing an active tile).
func set_side_bulbs(side: int, color: Color) -> void:
	for row in ROWS:
		set_side_bulb(side, row, color)


func set_all_bulbs(color: Color) -> void:
	for b in _bulbs:
		_paint(b, color)


## Tint / glow a whole side plate (Color.BLACK = normal gold).
func set_side_glow(side: int, color: Color, energy := 1.0) -> void:
	var mat := _sides[posmod(side, SIDES)].material_override as StandardMaterial3D
	mat.emission = color
	mat.emission_energy_multiplier = energy


## Party lamp inside the dome: coloured spots rotating on the inside of the dome.
func set_party_lamp(on: bool) -> void:
	party_lamp = on
	_dome_mat.set_shader_parameter("enabled", on)
	dome.light_energy = 0.8 if on else 0.0


func set_party_spin_speed(rad_per_s: float) -> void:
	_dome_mat.set_shader_parameter("spin_speed", rad_per_s)


## Plain dome colour instead of the party lamp (Color.BLACK = off).
func set_dome_color(color: Color, energy := 2.0) -> void:
	set_party_lamp(false)
	dome.light_color = color
	dome.light_energy = energy if color.v > 0.01 else 0.0


## A flash of the dome (with the party lamp on, update() takes the colour back over).
func flash_dome(color: Color) -> void:
	var energy := dome.light_energy
	dome.light_color = color
	dome.light_energy = 5.0
	dome.create_tween().tween_property(dome, "light_energy", energy, 0.5)


## Everything off (the robot without power).
func dark() -> void:
	set_effect("none")
	set_party_lamp(false)
	dome.light_energy = 0.0
	for k in SIDES:
		set_side_glow(k, Color.BLACK)


func _run_effect(t: float) -> void:
	for side in SIDES:
		for row in ROWS:
			var c := Color.BLACK
			match effect:
				"rainbow":  # colours wander around the robot and up the sides
					c = Color.from_hsv(fmod(float(side) / SIDES + row * 0.04 + t * 0.15, 1.0), 0.9, 1.0)
				"chase":  # one lit column runs around, colour changes per lap
					var pos := fmod(t * 4.0, SIDES)
					var dist := absf(wrapf(side - pos, -SIDES / 2.0, SIDES / 2.0))
					c = Color.from_hsv(fmod(floor(t * 4.0 / SIDES) * 0.17, 1.0), 0.9, clampf(1.0 - dist / 2.0, 0.0, 1.0))
				"pulse":  # whole robot breathes through the colours
					c = Color.from_hsv(fmod(t * 0.1, 1.0), 0.8, 0.5 + 0.5 * sin(t * 3.0))
			set_side_bulb(side, row, c)


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
