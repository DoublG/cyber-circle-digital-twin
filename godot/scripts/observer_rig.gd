class_name ObserverRig
extends Node3D
## Floating "observer" camera for visitors (the overview page and the empty
## screens). It just floats: a slow drift around the robot, slowly changing
## height and distance - no fast moves.
## Cameras in the screen views copy this node's transform (ScreenWall).

@export var center := Vector3(0, 1.1, 0)        # the robot
@export var radius := Vector2(3.8, 5.6)         # distance drifts between these (room: 6.6 m)
@export var height := Vector2(1.7, 3.4)         # stays under the sloping ceiling
@export var orbit_speed := 0.05                 # rad/s: a full circle in ~2 minutes
@export var glide := 0.5                        # smoothing (lower = softer)

var arena: Node3D
var _t := 0.0
var _angle := 0.0
var _look := Vector3.ZERO


func setup(arena_node: Node3D) -> void:
	arena = arena_node
	_angle = randf() * TAU
	position = _orbit_pos()
	_look = center


func _process(delta: float) -> void:
	_t += delta
	_angle += orbit_speed * delta
	var look := center + Vector3(sin(_t * 0.07) * 0.5, 0.2 * sin(_t * 0.05), cos(_t * 0.06) * 0.5)
	var k := 1.0 - exp(-delta * glide)
	position = position.lerp(_orbit_pos(), k)
	_look = _look.lerp(look, k)
	look_at(_look, Vector3.UP)


func _orbit_pos() -> Vector3:
	var r := lerpf(radius.x, radius.y, 0.5 + 0.5 * sin(_t * 0.06))
	var h := lerpf(height.x, height.y, 0.5 + 0.5 * sin(_t * 0.04 + 1.0))
	return Vector3(cos(_angle) * r, h, sin(_angle) * r)
