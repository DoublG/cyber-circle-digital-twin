class_name ViewCell
extends Control
## A cell of a screen with its own camera on the shared 3D world
## (view_cell.tscn), in the chamfered frame of the console.

const SCENE := "res://scenes/ui/view_cell.tscn"

var camera: Camera3D:
	get:
		return %Camera
var viewport: SubViewport:
	get:
		return %Viewport


static func create(view: Transform3D, fov: float) -> ViewCell:
	var cell: ViewCell = load(SCENE).instantiate()
	cell.camera.transform = view
	cell.camera.fov = fov
	return cell
