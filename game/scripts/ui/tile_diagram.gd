class_name TileDiagram
extends Control
## The tile seen from above while the player activates it: the ring in their
## colour, its 4 quarters with their icons (the robot side at the top, as the
## player stands on it); a quarter still to press glows in its icon's colour,
## a pressed one is greyed out. Below: how many (2/4).

const ANGLES := {&"Triangle": 45.0, &"Square": 135.0, &"Cross": 225.0, &"Circle": 315.0}
var tile: CyberTile
var color := Color.WHITE
var t := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var pressed: Array = tile.activation_pressed() if is_instance_valid(tile) else []
	var r := minf(size.x, size.y - 60.0) * 0.45
	var c := Vector2(size.x / 2.0, r + 6.0)
	var pulse := 0.6 + 0.4 * sin(t * 4.0)
	draw_circle(c, r, Color(0.08, 0.09, 0.11))                          # the tile
	draw_arc(c, r - 4.0, 0, TAU, 96, Color(color, pulse), 8.0, true)     # the ring in their colour
	draw_line(c + Vector2(0, -r - 4), c + Vector2(0, -r + 14), Color(Retro.CREAM, 0.5), 3.0)   # the robot side
	for b in ANGLES:
		# its quarter of the tile: a ring segment, a small gap to the next one
		var mid := deg_to_rad(ANGLES[b])
		var done: bool = b in pressed
		var col: Color = CyberTile.BUTTON_COLORS[b]
		var fill := Color(0.30, 0.30, 0.32) if done else col.darkened(0.45 - 0.25 * pulse)   # solid: no washed-out look
		var seg := PackedVector2Array()
		var gap := deg_to_rad(4.0)
		var r_in := r * 0.26
		var r_out := r - 14.0
		for k in 25:                                                        # outer arc
			var a := mid - PI / 4 + gap + (PI / 2 - 2 * gap) * k / 24.0
			seg.append(c + Vector2(cos(a), -sin(a)) * r_out)
		for k in 25:                                                        # inner arc, back
			var a := mid + PI / 4 - gap - (PI / 2 - 2 * gap) * k / 24.0
			seg.append(c + Vector2(cos(a), -sin(a)) * r_in)
		draw_colored_polygon(seg, fill)
		seg.append(seg[0])                                                  # (an antialiased edge)
		draw_polyline(seg, Color(0.42, 0.42, 0.44) if done else col.lightened(0.15 * pulse), 2.5, true)
		var p := c + Vector2(cos(mid), -sin(mid)) * r * 0.6
		_icon(b, p, r * 0.16, Color(0.55, 0.55, 0.57) if done else col.lightened(0.2), 6.0)
	draw_circle(c, r * 0.2, Color(0.15, 0.16, 0.19))                    # the logo in the middle
	draw_arc(c, r * 0.2, 0, TAU, 48, Color(Retro.CREAM, 0.25), 2.0, true)
	var count := "%d/4" % pressed.size()
	var font := get_theme_default_font()
	var w := font.get_string_size(count, HORIZONTAL_ALIGNMENT_CENTER, -1, 40).x
	draw_string(font, Vector2(c.x - w / 2.0, c.y + r + 50.0), count, HORIZONTAL_ALIGNMENT_LEFT, -1, 40, Retro.AMBER)


func _icon(b: StringName, p: Vector2, s: float, col: Color, width: float) -> void:
	match b:
		&"Square":
			draw_rect(Rect2(p - Vector2(s, s) * 0.85, Vector2(s, s) * 1.7), col, false, width)
		&"Triangle":
			var pts := PackedVector2Array()
			for j in 4:
				var a := deg_to_rad(-90.0 + 120.0 * j)
				pts.append(p + Vector2(cos(a), sin(a)) * s * 1.1 + Vector2(0, s * 0.15))
			draw_polyline(pts, col, width, true)
		&"Cross":
			draw_line(p + Vector2(-s, -s) * 0.85, p + Vector2(s, s) * 0.85, col, width, true)
			draw_line(p + Vector2(-s, s) * 0.85, p + Vector2(s, -s) * 0.85, col, width, true)
		_:
			draw_arc(p, s * 0.9, 0, TAU, 40, col, width, true)
