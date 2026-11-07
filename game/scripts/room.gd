class_name SpaceshipRoom
extends Node3D
## Retro spaceship control room around the play area. Blinks the console
## lamps, lights the room from the ceiling ring and slides the door.
## baked = true: models/environment_baked.glb (assets/blender/bake_models.py) - the
## room, floor, ducts and cables with their lighting baked into textures,
## drawn unshaded: no real-time light or shadow on the environment. The ring
## light then only lights the robot and the tiles, without shadows.
## baked = false: models/room.glb + arena_floor.glb with real-time lighting.

const ROOM_SCENE := preload("res://models/room.glb")
const BAKED_SCENE := preload("res://models/environment_baked.glb")
const DOOR_TRAVEL := 0.75

@export var lamp_colors: Array[Color] = [
	Color(1.0, 0.15, 0.1), Color(1.0, 0.6, 0.1), Color(0.2, 1.0, 0.3),
	Color(0.2, 0.8, 1.0), Color(1.0, 1.0, 0.9),
]
@export var blink_rate := 1.0          # higher = busier consoles
@export var ring_color := Color(0.7, 0.85, 1.0): set = set_ring_color
@export var ring_energy := 1.6
@export var baked := true

var _model: Node3D
var _lamps: Array[MeshInstance3D] = []
var _lamp_timers: Array[float] = []
var _ring: MeshInstance3D
var _ring_light: OmniLight3D
var _door_parts: Array[Node3D] = []    # Door_L, Door_R and their stripes
var _door_rest := {}                   # part -> closed position
var _door_dir := {}                    # part -> sliding direction
var _door_light: MeshInstance3D
var door_open := false


func _ready() -> void:
	_model = get_node_or_null("Model")
	if _model == null:
		_model = (BAKED_SCENE if baked else ROOM_SCENE).instantiate()
		_model.name = "Model"
		add_child(_model)
	if baked:
		for mi in _model.find_children("*", "MeshInstance3D", true, false):
			_unshaded(mi)

	for node in _model.find_children("Console_Lamp_*", "MeshInstance3D", true, false):
		_lamps.append(_make_lamp(node))
		_lamp_timers.append(randf() * 1.5)

	_ring = _model.find_child("Ceiling_Ring", true, false)
	_make_lamp(_ring)
	_ring_light = OmniLight3D.new()
	_ring_light.position = Vector3(0, 4.2, 0)  # under the dome, above the robot
	_ring_light.omni_range = 12.0
	_ring_light.light_energy = ring_energy
	_ring_light.shadow_enabled = not baked      # baked: the shadows are in the textures
	_ring.get_parent().add_child(_ring_light)
	set_ring_color(ring_color)

	var frame := _model.find_child("Door_Frame", true, false) as Node3D
	for part_name in ["Door_L", "Door_R", "Door_L_Stripe", "Door_R_Stripe"]:
		var part := _model.find_child(part_name, true, false) as Node3D
		_door_parts.append(part)
		_door_rest[part] = part.position
		var offset := part.position - frame.position
		offset.y = 0
		_door_dir[part] = offset.normalized()
	_door_light = _make_lamp(_model.find_child("Door_Light", true, false))
	_paint(_door_light, Color(1.0, 0.2, 0.1))


func _process(delta: float) -> void:
	for i in _lamps.size():
		_lamp_timers[i] -= delta * blink_rate
		if _lamp_timers[i] <= 0.0:
			_lamp_timers[i] = randf_range(0.15, 1.6)
			var on := randf() < 0.6
			_paint(_lamps[i], lamp_colors.pick_random() if on else Color.BLACK)


func set_ring_color(color: Color) -> void:
	ring_color = color
	if _ring_light == null:  # not built yet; _ready() applies it
		return
	_ring_light.light_color = color
	_paint(_ring, color)


func open_door() -> void:
	_move_door(true)


func close_door() -> void:
	_move_door(false)


func toggle_door() -> void:
	_move_door(not door_open)


func _move_door(open: bool) -> void:
	door_open = open
	_paint(_door_light, Color(0.2, 1.0, 0.3) if open else Color(1.0, 0.2, 0.1))
	var tw := create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	for part in _door_parts:
		var target: Vector3 = _door_rest[part] + (_door_dir[part] * DOOR_TRAVEL if open else Vector3.ZERO)
		tw.tween_property(part, "position", target, 0.8)


## Baked surfaces: the texture already holds the light - draw it as it is.
func _unshaded(mi: MeshInstance3D) -> void:
	for i in mi.mesh.get_surface_count():
		var mat := mi.mesh.surface_get_material(i) as StandardMaterial3D
		if mat and mat.resource_name.begins_with("Baked_"):
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED   # (only ever drawn baked)


func _make_lamp(mi: MeshInstance3D) -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.3, 0.3)
	mat.emission_enabled = true
	mat.emission = Color.BLACK
	mat.emission_energy_multiplier = 3.0
	mi.material_override = mat
	return mi


func _paint(mi: MeshInstance3D, color: Color) -> void:
	var mat := mi.material_override as StandardMaterial3D
	mat.emission = color
	mat.albedo_color = color if color.v > 0.01 else Color(0.3, 0.3, 0.3)
