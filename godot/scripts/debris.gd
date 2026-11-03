class_name Debris
extends MultiMeshInstance3D
## Pieces flying off an explosion or a hit: small chunks of the tile (white
## plate, aluminium, black base, a few orange-hot ones that cool down) fly
## out, tumble, bounce on the floor and lie still, then shrink away.
## One MultiMesh: the whole burst is a single draw call.
## Debris.spawn(parent, at, count, size, speed): `at` in the parent's space,
## the floor is the parent's y = 0.

const GRAVITY := 9.8
const BOUNCE := 0.35          # vertical speed kept at a bounce
const FRICTION := 0.55        # horizontal speed kept at a bounce
const LIFE := 2.5             # s, then shrink away in 0.5 s
const COLORS := [Color(0.86, 0.86, 0.84), Color(0.86, 0.86, 0.84), Color(0.75, 0.76, 0.78),
	Color(0.05, 0.05, 0.05)]
const HOT := Color(1.0, 0.45, 0.08)
const BURNT := Color(0.08, 0.06, 0.05)

static var _mesh: BoxMesh

var _pos: PackedVector3Array
var _vel: PackedVector3Array
var _rot: PackedVector3Array
var _spin: PackedVector3Array
var _size: PackedVector3Array
var _hot: PackedByteArray
var _base: PackedColorArray
var _age := 0.0


static func spawn(parent: Node, at: Vector3, count: int, size := 0.05, speed := 1.0, hot := 0.3) -> Debris:
	if _mesh == null:
		_mesh = BoxMesh.new()
		_mesh.size = Vector3.ONE
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.6
		_mesh.material = mat
	var d := Debris.new()
	d.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	d.multimesh = MultiMesh.new()
	d.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	d.multimesh.use_colors = true
	d.multimesh.mesh = _mesh
	d.multimesh.instance_count = count
	for i in count:
		var s := size * randf_range(0.35, 1.0)
		var a := randf() * TAU
		var out := randf_range(0.8, 3.0) * speed
		d._pos.append(at + Vector3(randf_range(-0.1, 0.1), 0.0, randf_range(-0.1, 0.1)))
		d._vel.append(Vector3(cos(a) * out, randf_range(2.0, 4.5) * speed, sin(a) * out))
		d._rot.append(Vector3(randf() * TAU, randf() * TAU, randf() * TAU))
		d._spin.append(Vector3(randf_range(-15, 15), randf_range(-15, 15), randf_range(-15, 15)))
		d._size.append(Vector3(s, s * randf_range(0.25, 0.6), s * randf_range(0.5, 1.0)))
		var is_hot := randf() < hot
		d._hot.append(1 if is_hot else 0)
		d._base.append(HOT if is_hot else COLORS.pick_random())
	parent.add_child(d)
	d._update(0.0)
	return d


func _process(delta: float) -> void:
	_age += delta
	_update(delta)
	if _age > LIFE + 0.5:
		queue_free()


func _update(delta: float) -> void:
	var shrink := clampf(1.0 - (_age - LIFE) / 0.5, 0.001, 1.0)
	var cool := clampf(_age / 1.5, 0.0, 1.0)
	for i in _pos.size():
		var half := _size[i].y * 0.5
		if _vel[i] != Vector3.ZERO:
			_vel[i].y -= GRAVITY * delta
			_pos[i] += _vel[i] * delta
			_rot[i] += _spin[i] * delta
			if _pos[i].y < half:                    # the floor
				_pos[i].y = half
				if absf(_vel[i].y) < 0.6:           # lies still, flat
					_vel[i] = Vector3.ZERO
					_rot[i] = Vector3(0, _rot[i].y, 0)
				else:
					_vel[i] = Vector3(_vel[i].x * FRICTION, -_vel[i].y * BOUNCE, _vel[i].z * FRICTION)
					_spin[i] *= 0.5
		var b := Basis.from_euler(_rot[i]) * Basis.from_scale(_size[i] * shrink)
		multimesh.set_instance_transform(i, Transform3D(b, _pos[i]))
		multimesh.set_instance_color(i, _base[i].lerp(BURNT, cool) if _hot[i] else _base[i])
