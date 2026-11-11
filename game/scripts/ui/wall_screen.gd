class_name WallScreen
extends Control
## One physical screen of the wall (wall_screen.tscn). It renders at a fixed
## 1920x1080 (the real monitors) and is scaled as a whole to fit, so the
## layout is identical in the preview and on any monitor. What the screen
## shows goes in `content`; the CRT effect stays on top of it.

var content: Control:
	get:
		return %Content
var crt: CanvasItem:
	get:
		return %Crt
## A display node: the notice about the connection to the master, over everything.
var link: Label:
	get:
		return %Link


func _ready() -> void:
	resized.connect(_fit)
	_fit()


func _fit() -> void:
	var res := Vector2((%Viewport as SubViewport).size)
	var k := minf(size.x / res.x, size.y / res.y)
	%Scaled.scale = Vector2(k, k)
	%Scaled.position = (size - res * k) / 2
