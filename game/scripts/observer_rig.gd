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

var arena: Arena
var _t := 0.0
var _angle := 0.0
var _look := Vector3.ZERO
var _focus := Vector3.ZERO      # a tile to watch (an extermination) ...
var _focus_left := 0.0          # ... for this many seconds more
var _close_left := 0.0          # the overview's robot scene: close around the robot


func setup(arena_node: Arena) -> void:
	arena = arena_node
	_angle = randf() * TAU
	position = _orbit_pos()
	_look = center


## Drift over to watch a tile (behind it, the robot in view) for `seconds`,
## then float on - still gliding, no fast moves. Vector3.ZERO: a wide view
## on the robot from above (several tiles at once).
func focus(tile_pos: Vector3, seconds: float) -> void:
	_focus = tile_pos
	_focus_left = seconds


## The robot up close: a lower, nearer orbit (just outside the tiles) for
## `seconds` - the overview page's robot scene. A focus (extermination) wins.
func close_up(seconds: float) -> void:
	_close_left = seconds


func _process(delta: float) -> void:
	_t += delta
	_close_left = maxf(_close_left - delta, 0.0)
	var look := center + Vector3(sin(_t * 0.07) * 0.5, 0.2 * sin(_t * 0.05), cos(_t * 0.06) * 0.5)
	var target := _orbit_pos()
	var g := glide
	if _focus_left > 0.0:
		_focus_left -= delta
		if _focus == Vector3.ZERO:
			target = Vector3(position.x, 0.0, position.z).normalized() * radius.x + Vector3(0.0, height.y, 0.0)
			look = Vector3(0.0, 0.3, 0.0)
		else:
			var dir := Vector3(_focus.x, 0.0, _focus.z).normalized()
			target = _focus + dir * 2.6 + Vector3(0.0, 2.0, 0.0)
			look = _focus.lerp(center, 0.35)
		g = glide * 1.6
		_angle = atan2(position.z, position.x)     # afterwards: float on from here
	elif _close_left > 0.0:
		_angle += orbit_speed * 2.5 * delta
		target = Vector3(cos(_angle) * 3.4, 1.55 + 0.25 * sin(_t * 0.3), sin(_angle) * 3.4)
		look = center + Vector3(0.0, 0.25, 0.0)
	else:
		_angle += orbit_speed * delta
	var k := 1.0 - exp(-delta * g)
	position = position.lerp(target, k)
	_look = _look.lerp(look, k)
	look_at(_look, Vector3.UP)


func _orbit_pos() -> Vector3:
	var r := lerpf(radius.x, radius.y, 0.5 + 0.5 * sin(_t * 0.06))
	var h := lerpf(height.x, height.y, 0.5 + 0.5 * sin(_t * 0.04 + 1.0))
	return Vector3(cos(_angle) * r, h, sin(_angle) * r)
