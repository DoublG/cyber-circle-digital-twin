class_name CountdownRing
extends Control
## Round countdown: segmented ring (like an old dial) with the seconds left.


const SEGMENTS := 24
var seconds := -1
var symbol := "✔"                # shown instead of the seconds when seconds < 0
var fraction := 1.0
var color := Color.WHITE


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var c := size / 2
	var r := minf(size.x, size.y) * 0.42
	draw_circle(c, r + 12, Retro.PANEL)
	draw_arc(c, r + 12, 0, TAU, 32, Retro.DIM, 3, true)
	var lit := ceili(fraction * SEGMENTS)
	for k in SEGMENTS:
		var a0 := -PI / 2 + TAU * k / SEGMENTS
		var a1 := a0 + TAU / SEGMENTS * 0.7
		draw_arc(c, r - 4, a0, a1, 4, color if k < lit else Color(1, 1, 1, 0.08), 14, true)
	var text := str(seconds) if seconds >= 0 else symbol
	var fs := int(r * 0.95)
	var w := Retro.FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(Retro.FONT, c + Vector2(-w / 2, fs * 0.36), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Retro.CREAM)
