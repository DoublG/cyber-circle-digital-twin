class_name CableLights
extends RefCounted
## The light strips in the ducts between the floor tiles and the robot
## (Arena.cables): an idle flow per cable in the player's colour, and bright
## packets that run along it - a button press on its way to the robot, the
## robot's shot on its way to the tile. A drone has no cable: its packets are
## bolts through the air (DroneTile.send_bolt).

const SHADER := preload("res://shaders/cable_flow.gdshader")
const MAX_PACKETS := 4                       # per cable at once (the shader's slots)

var arena: Arena
var _mats: Array[ShaderMaterial] = []        # index = tile_id - 1
var _packets: Array[Dictionary] = []         # {tile, pos, color, on_arrive, to_robot}


func _init(arena_node: Arena) -> void:
	arena = arena_node


## Once the tiles are known: every floor tile's strip (Spoke_Light_NN in the
## floor model) gets its flow material; idle tiles: a faint flow.
func setup(floor_model: Node) -> void:
	for tile in arena.tiles:
		if tile is DroneTile:                    # (no cable: bolts through the air)
			continue
		var strip := floor_model.find_child("Spoke_Light_%02d" % tile.tile_id, true, false) as MeshInstance3D
		var mat := ShaderMaterial.new()
		mat.shader = SHADER
		mat.set_shader_parameter("flow_color", arena.cable_color)
		strip.material_override = mat
		_mats.append(mat)
		set_flow(tile.tile_id, arena.cable_color, 0.15)


## Send a light packet along a tile's cable; on_arrive is called at the end.
## to_robot = false: from the robot to the tile. A drone has no cable: a bolt
## flies through the air.
func send_packet(tile_id: int, color: Color, on_arrive := Callable(), to_robot := true) -> void:
	Replica.relay("cables", &"replica_packet", [tile_id, color, to_robot])
	packet(tile_id, color, on_arrive, to_robot)


## The same, here only (RobotNpc: its choreography runs on every node).
func packet(tile_id: int, color: Color, on_arrive := Callable(), to_robot := true) -> void:
	var tile := arena.tiles[tile_id - 1]
	if tile is DroneTile:
		(tile as DroneTile).send_bolt(color, to_robot, on_arrive)
		return
	_packets.append({"tile": tile_id, "pos": 0.0, "color": color, "on_arrive": on_arrive,
		"to_robot": to_robot})


## A display node: a packet the master sent (send_packet).
func replica_packet(tile_id: int, color: Color, to_robot: bool) -> void:
	packet(tile_id, color, Callable(), to_robot)


## Idle flow on one cable (e.g. dark red for a dead player).
func set_flow(tile_id: int, color: Color, strength := 0.5) -> void:
	if tile_id > _mats.size():                   # (a drone: no cable)
		return
	Replica.relay("cables", &"set_flow", [tile_id, color, strength])
	var mat := _mats[tile_id - 1]
	mat.set_shader_parameter("flow_color", color)
	mat.set_shader_parameter("idle_strength", strength)


## Every frame (Arena._process): the packets move on, the ones that arrived call back.
func update(delta: float) -> void:
	for p in _packets:
		p.pos += delta * arena.packet_speed
	for p in _packets.filter(func(p): return p.pos >= 1.0):
		_packets.erase(p)
		if p.on_arrive.is_valid():
			p.on_arrive.call()
	for i in _mats.size():
		_show_packets(i)


## The packets on cable i, for its shader (at most MAX_PACKETS).
func _show_packets(i: int) -> void:
	var slots := Vector4(-1, -1, -1, -1)
	var dirs := Vector4(1, 1, 1, 1)
	var n := 0
	var color := Color.WHITE
	for p in _packets:
		if p.tile == i + 1 and n < MAX_PACKETS:
			slots[n] = p.pos if p.to_robot else 1.0 - p.pos
			dirs[n] = 1.0 if p.to_robot else -1.0
			color = p.color
			n += 1
	_mats[i].set_shader_parameter("packets", slots)
	_mats[i].set_shader_parameter("packet_dirs", dirs)
	_mats[i].set_shader_parameter("packet_color", color)
