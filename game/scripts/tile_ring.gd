class_name TileRing
extends RefCounted
## A tile's ring of 48 LEDs (CyberTile.ring): LED 0 faces the robot, counting
## clockwise from above. The LEDs of tile.glb (LED_00..47) are replaced by one
## MultiMesh: one draw call (instance colour = LED).

const COUNT := 48
const LED_SHADER := preload("res://shaders/led.gdshader")

var colors: Array[Color] = []     # what the LEDs show now (e.g. to mirror them on a screen)

var _leds := MultiMesh.new()


func _init(tile: Node3D, model: Node3D, off_color: Color) -> void:
	var meshes: Array[MeshInstance3D] = []
	for i in COUNT:
		var mi := model.find_child("LED_%02d" % i, true, false) as MeshInstance3D
		assert(mi != null, "tile.glb is missing node LED_%02d" % i)
		meshes.append(mi)
	_leds.transform_format = MultiMesh.TRANSFORM_3D
	_leds.use_colors = true
	_leds.mesh = meshes[0].mesh
	_leds.instance_count = COUNT
	var to_tile := tile.global_transform.affine_inverse()
	for i in COUNT:
		_leds.set_instance_transform(i, to_tile * meshes[i].global_transform)
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
	colors.resize(COUNT)
	clear()


func set_led(index: int, color: Color) -> void:
	index = posmod(index, COUNT)
	colors[index] = color
	var on := color.v > 0.01
	_leds.set_instance_color(index, Color(color.r, color.g, color.b, 1.0) if on else Color(0, 0, 0, 0))


## given: up to COUNT colours, starting at LED 0.
func set_all(given: Array) -> void:
	for i in mini(given.size(), COUNT):
		set_led(i, given[i])


func fill(color: Color) -> void:
	for i in COUNT:
		set_led(i, color)


func clear() -> void:
	fill(Color.BLACK)
