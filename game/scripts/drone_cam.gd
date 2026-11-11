class_name DroneCam
extends Node
## A drone player's camera, third person: behind and well above the drone,
## looking down past it at the robot - the drone low in the view, the robot
## above it (the drone flies higher than the robot: from just behind it would
## cover the robot). down = 1: over the drone, looking down at its top (LEDs,
## icons; the robot side up), for the rounds on the tile.

var wall: ScreenWall
var drone: DroneTile
var cam: Camera3D
var down := 0.0


func _process(_delta: float) -> void:
	follow()


func follow() -> void:
	if not is_instance_valid(drone) or not cam.is_inside_tree():
		return
	var p := drone.global_position
	var out := Vector3(p.x, 0, p.z).normalized()
	if out.is_zero_approx():
		return
	var r := minf(Vector2(p.x, p.z).length() + wall.drone_cam_back, 6.0)   # (inside the room)
	var eye := Vector3(out.x * r, p.y + wall.drone_cam_up, out.z * r)
	var chase := Transform3D(Basis(), eye).looking_at(wall.look_at.lerp(p, wall.drone_cam_aim), Vector3.UP)
	var over := Transform3D(Basis(), p + Vector3(0, 0.95, 0) + out * 0.3).looking_at(
		p + Vector3(0, 0.05, 0) - out * 0.05, -out)
	cam.global_transform = chase.interpolate_with(over, down)
	cam.fov = lerpf(wall.player_fov, wall.tile_fov, down)
