class_name TileRing
extends RefCounted
## A tile's ring of 48 LEDs (CyberTile.ring): LED 0 faces the robot, counting
## clockwise from above. The LEDs of tile.glb (LED_00..47) are replaced by one
## MultiMesh: one draw call (instance colour = LED). A model with an inner ring
## (LED_IN_00..47: the floor tile and the drone) gets it in the same
## MultiMesh, showing what the outer ring shows - as the real tile's firmware does.

const COUNT := 48
const LED_SHADER := preload("res://shaders/led.gdshader")
const GLOW_SHADER := preload("res://shaders/tile_glow.gdshader")
const COUNTDOWN_COLOR := Color(0.1, 1.0, 0.25)   # the round's countdown LED (the firmware's GREEN)
const COUNTDOWN_SCALE := 2.2     # ... drawn bigger and brighter than the real LED: readable on the screens
const COUNTDOWN_BOOST := 1.8

var colors: Array[Color] = []     # what the LEDs show now (e.g. to mirror them on a screen)

var _leds := MultiMesh.new()


var _inner := false              # the model has the inner ring: instances COUNT..2*COUNT-1
var _countdown := -1             # the round's green countdown LED on the outer ring (-1: none)
var _outer_xf: Array[Transform3D] = []   # the outer LEDs' own transforms (the countdown LED is scaled up)
var _glow: ShaderMaterial        # the plates the rings light up (Ring_Glow)
var _glow_leds := PackedVector3Array()
var _glow_dirty := false         # sent once a frame, after all of that frame's set_led


func _init(tile: Node3D, model: Node3D, off_color: Color) -> void:
	var meshes: Array[MeshInstance3D] = []
	for i in COUNT:
		var mi := model.find_child("LED_%02d" % i, true, false) as MeshInstance3D
		assert(mi != null, "tile.glb is missing node LED_%02d" % i)
		meshes.append(mi)
	_inner = model.find_child("LED_IN_00", true, false) != null
	if _inner:
		for i in COUNT:
			var mi := model.find_child("LED_IN_%02d" % i, true, false) as MeshInstance3D
			assert(mi != null, "tile.glb is missing node LED_IN_%02d" % i)
			meshes.append(mi)
	_leds.transform_format = MultiMesh.TRANSFORM_3D
	_leds.use_colors = true
	_leds.mesh = meshes[0].mesh      # (the inner LEDs are smaller: their transforms scale it down)
	_leds.instance_count = meshes.size()
	var to_tile := tile.global_transform.affine_inverse()
	var base := meshes[0].mesh.get_aabb().size
	for i in meshes.size():
		var t := to_tile * meshes[i].global_transform
		var own := meshes[i].mesh.get_aabb().size
		if own != base and base.x > 0.0 and base.y > 0.0 and base.z > 0.0:
			t = t * Transform3D(Basis.from_scale(own / base), Vector3.ZERO)
		_leds.set_instance_transform(i, t)
		if i < COUNT:
			_outer_xf.append(t)
		meshes[i].queue_free()
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Ring_LEDs"
	mmi.multimesh = _leds
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = LED_SHADER
	mat.set_shader_parameter("off_color", off_color)
	mmi.material_override = mat
	tile.add_child(mmi)
	var plate := model.find_child("Ring_Glow", true, false) as MeshInstance3D
	if plate != null:
		_glow = ShaderMaterial.new()
		_glow.shader = GLOW_SHADER
		plate.material_override = _glow
		plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# where the rings are on the plate (tile or drone: their own size), for the brighter band
		var to_plate := plate.global_transform.affine_inverse()
		var at := func(mi: MeshInstance3D) -> float:
			var p := to_plate * mi.global_transform.origin
			return Vector2(p.x, p.z).length()
		_glow.set_shader_parameter("r_outer", at.call(meshes[0]))
		if _inner:
			_glow.set_shader_parameter("r_inner", at.call(meshes[COUNT]))
		_glow_leds.resize(COUNT)
	colors.resize(COUNT)
	clear()


func set_led(index: int, color: Color) -> void:
	index = posmod(index, COUNT)
	colors[index] = color
	var on := color.v > 0.01
	var c := Color(color.r, color.g, color.b, 1.0) if on else Color(0, 0, 0, 0)
	_leds.set_instance_color(index, COUNTDOWN_COLOR * COUNTDOWN_BOOST if index == _countdown else c)   # (shown())
	if _inner:
		_leds.set_instance_color(COUNT + index, c)
	if _glow != null:
		_glow_leds[index] = Vector3(c.r, c.g, c.b) if on else Vector3.ZERO
		if not _glow_dirty:
			_glow_dirty = true
			_send_glow.call_deferred()


## What an LED shows: the outer ring (the countdown LED on top of the ring's
## colour) or the inner one (`inner`: only the ring's colour).
func shown(index: int, inner := false) -> Color:
	index = posmod(index, COUNT)
	return COUNTDOWN_COLOR if index == _countdown and not inner else colors[index]


## The round's countdown LED (GameManager): green on the outer ring only, on
## top of what the ring shows (colors keep the ring's own colours); -1: none.
func set_countdown(index: int) -> void:
	if index == _countdown:
		return
	var old := _countdown
	_countdown = index
	if old >= 0:
		_leds.set_instance_transform(old, _outer_xf[old])
		set_led(old, colors[old])
	if index >= 0:
		_leds.set_instance_transform(index, _outer_xf[index] * Transform3D(Basis.from_scale(Vector3.ONE * COUNTDOWN_SCALE)))
		set_led(index, colors[index])


func _send_glow() -> void:
	_glow_dirty = false
	_glow.set_shader_parameter("leds", _glow_leds)


## given: up to COUNT colours, starting at LED 0.
func set_all(given: Array) -> void:
	for i in mini(given.size(), COUNT):
		set_led(i, given[i])


func fill(color: Color) -> void:
	for i in COUNT:
		set_led(i, color)


func clear() -> void:
	fill(Color.BLACK)
