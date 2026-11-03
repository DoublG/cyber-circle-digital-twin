class_name TileSlot
extends Control
## A tile's place on its screen when there is no player on it - the same size
## as a player view, so the layout never changes when players come and go:
##   free tile:    tile number, "VRIJ", a rotating call to action and how to join
##   out of service: "BUITEN GEBRUIK" (taken out of the game by the operator)
##   invited tile: (registered in the app, not activated yet) the player's name
##                 and a bar pulsing in the colour they picked, "DRUK OP DE 4 ICONEN"
##                 with the tile drawn from above: its ring in their colour, the 4
##                 quarters with their icons (the robot side up); a pressed quarter
##                 greys out, and a count (2/4)
## Plain 2D (no 3D view): cheap to draw.


var tile_id := 0
var player := ""                  # "" = free tile
var out_of_service := false
var mode := "open"                # the game's mode: "setup" shows the tile number big, "closed" GESLOTEN
var color := Color.WHITE
var tile: CyberTile                # invited: the tile (which icons are pressed)
var _t := 0.0
var _diagram: TileDiagram


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true


func _ready() -> void:
	var invited := player != ""
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 40)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 28)
	add_child(box)
	var badge := Retro.label(56, Retro.BG, Retro.tile_label(tile_id))
	badge.add_theme_stylebox_override("normal", Retro.panel(Retro.TEAL if invited else Color(Retro.TEAL, 0.45),
		Retro.TEAL, 0, 10, 22))
	badge.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(badge)
	if mode == "setup":                    # physical setup: which slot is which tile?
		badge.add_theme_font_size_override("font_size", 180)
		box.add_child(_wrapped("SETUP" + ("  -  BUITEN GEBRUIK" if out_of_service else ""), 48, Retro.AMBER))
	elif out_of_service:
		box.add_child(_wrapped("BUITEN GEBRUIK", 64, Color(Retro.BAD, 0.8)))
	elif mode == "closed":
		box.add_child(_wrapped("GESLOTEN", 96, Color(Retro.DIM, 0.8)))
	elif invited:
		box.add_child(_wrapped(player.to_upper(), 84, color.lightened(0.25)))
		box.add_child(_wrapped("DRUK OP DE 4 ICONEN", 40, Retro.AMBER))
		_diagram = TileDiagram.new()
		_diagram.tile = tile
		_diagram.color = color
		_diagram.custom_minimum_size = Vector2(0, 460)
		box.add_child(_diagram)
	else:
		box.add_child(_wrapped("VRIJ", 96, Color(Retro.DIM, 0.8)))
		var cta := CallToAction.new(52)
		cta.offset = tile_id
		cta.custom_minimum_size.y = 200
		box.add_child(cta)
		box.add_child(_wrapped(Texts.join_text(), 32, Retro.CREAM))
	add_child(Retro.ViewFrame.new())
	set_process(invited)


func _wrapped(text: String, font_size: int, col: Color) -> Label:
	var l := Retro.label(font_size, col, text)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _process(_delta: float) -> void:
	_t = fmod(Time.get_unix_time_from_system(), 3600.0)   # (the wall clock: in step on every node)
	queue_redraw()
	if _diagram:
		_diagram.t = _t
		_diagram.queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(Retro.PANEL, 0.95))
	if player == "":
		return
	var pulse := 0.55 + 0.45 * sin(_t * 4.0)        # the colour the player looks for
	draw_rect(Rect2(40, 40, size.x - 80, 22), Color(color, pulse))
	draw_rect(Rect2(40, size.y - 62, size.x - 80, 22), Color(color, pulse))


## The tile seen from above while the player activates it: the ring in their
## colour, its 4 quarters with their icons (the robot side at the top, as the
## player stands on it); a quarter still to press glows in its icon's colour,
## a pressed one is greyed out. Below: how many (2/4).
class TileDiagram extends Control:
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
