class_name Retro
extends RefCounted
## Shared look of all screens: a 70s spaceship console, matching the room
## (orange stripes, teal pillars, green CRT consoles). Chamfered panels, a
## bold mono font, scanlines and a vignette on top of every screen.

const FLOOR_TILES := 13             # tiles on the floor; mobile players (drones) come after
const BG := Color(0.035, 0.03, 0.028)
const PANEL := Color(0.09, 0.075, 0.06)
const ORANGE := Color(1.0, 0.45, 0.08)
const AMBER := Color(1.0, 0.74, 0.22)
const TEAL := Color(0.2, 0.8, 0.75)
const CREAM := Color(1.0, 0.93, 0.8)
const DIM := Color(0.55, 0.48, 0.4)
const GOOD := Color(0.3, 1.0, 0.45)
const BAD := Color(1.0, 0.25, 0.2)
const SHIELD := Color(0.3, 0.75, 1.0)    # protected players (= CyberTile.SHIELD_COLOR)
const FONT := preload("res://fonts/DejaVuSansMono-Bold.ttf")
const CRT_SHADER := preload("res://shaders/crt_overlay.gdshader")
const BG_SHADER := preload("res://shaders/retro_background.gdshader")

## Calls to action, rotating on the overview page and the empty screens.
const CALLS_TO_ACTION := [
	"VERSLA DE ROBOT!",
	"RED DE GALAXY!",
	"DE ROBOT WIL DE GALAXY VEROVEREN - HOU HEM TEGEN!",
	"DURF JIJ DE CYBER CIRCLE CHALLENGE AAN?",
	"WIE HOUDT HET LANGST STAND?",
	"SAMEN STERK TEGEN DE ROBOT!",
	"DE GALAXY REKENT OP JOU!",
]

## Dutch names of the tile buttons
const BUTTON_NAMES := {&"Square": "VIERKANT", &"Triangle": "DRIEHOEK", &"Cross": "KRUIS", &"Circle": "CIRKEL"}

static var _theme: Theme
## The game's clock (s, Arena.clock): follows --fixed-fps (the movies) and is
## the master's on every display node - UI animations that must run in step
## everywhere and at the game's pace use it, not the wall clock.
static var game_clock := 0.0


## A player's place on the screens: floor tile "T03", mobile player (drone,
## ids after the 13 floor tiles) "M1".
static func tile_label(tile_id: int) -> String:
	return "T%02d" % tile_id if tile_id <= FLOOR_TILES else "M%d" % (tile_id - FLOOR_TILES)


## "1 RONDE" / "3 RONDES": rounds survived.
static func rounds(n: int) -> String:
	return "%d RONDE" % n if n == 1 else "%d RONDES" % n


## Theme for a screen root: every Label inside uses the retro font.
static func theme() -> Theme:
	if _theme == null:
		_theme = Theme.new()
		_theme.default_font = FONT
		_theme.default_font_size = 40
	return _theme


static func label(font_size: int, color: Color, text := "",
		align := HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Panel with cut-off (chamfered) corners, like the console plates in the room.
static func panel(bg: Color, border: Color, width := 4, cut := 18, margin := 18) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(width)
	s.set_corner_radius_all(cut)
	s.corner_detail = 1          # 1 segment per corner = a straight chamfer
	s.content_margin_left = margin
	s.content_margin_right = margin
	s.content_margin_top = margin * 0.5
	s.content_margin_bottom = margin * 0.5
	s.anti_aliasing = true
	return s


static func panel_container(bg: Color, border: Color, width := 4, cut := 18, margin := 18) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", panel(bg, border, width, cut, margin))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


## Full-screen background: dark plate with a faint grid and the orange/teal
## stripe of the room walls along the top and bottom.
static func background() -> ColorRect:
	var r := ColorRect.new()
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	m.shader = BG_SHADER
	r.material = m
	return r


## Scanlines + vignette + slight flicker, drawn over a whole screen.
static func crt_overlay() -> ColorRect:
	var r := ColorRect.new()
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	m.shader = CRT_SHADER
	r.material = m
	return r


## Title bar: "▌▌ TITLE" with stripes on both sides.
static func title_bar(text: String, font_size := 64, color := AMBER) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 22)
	row.add_child(stripes(true))
	row.add_child(label(font_size, color, text))
	row.add_child(stripes(false))
	return row


static func stripes(left: bool) -> HBoxContainer:
	var s := HBoxContainer.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.add_theme_constant_override("separation", 8)
	s.alignment = BoxContainer.ALIGNMENT_END if left else BoxContainer.ALIGNMENT_BEGIN
	var cols := [TEAL, ORANGE, ORANGE, AMBER]
	if not left:
		cols.reverse()
	var line := ColorRect.new()
	line.color = ORANGE.darkened(0.3)
	line.custom_minimum_size = Vector2(0, 6)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if not left:
		s.add_child(_bars(cols))
		s.add_child(line)
	else:
		s.add_child(line)
		s.add_child(_bars(cols))
	return s


static func _bars(cols: Array) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	for c in cols:
		var b := ColorRect.new()
		b.color = c
		b.custom_minimum_size = Vector2(14, 44)
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(b)
	return h


## The etched icon of a tile button, as a glowing line drawing.
class ButtonIcon:
	extends Control

	var button: StringName = &"Square"
	var color := Color.WHITE:
		set(c):
			color = c
			queue_redraw()
	var glow := true

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		Retro.draw_icon(self, button, size / 2, minf(size.x, size.y) * 0.4, color, glow)


## Draw a tile button icon on any canvas item: centre c, radius r.
static func draw_icon(ci: CanvasItem, button: StringName, c: Vector2, r: float, color: Color, glow := true) -> void:
	for pass_i in (2 if glow else 1):  # wide faint pass = glow, then the sharp line
		var sharp := pass_i == (1 if glow else 0)
		var w := r * (0.2 if sharp else 0.45)
		var col := color if sharp else Color(color, color.a * 0.25)
		match button:
			&"Square":
				var h := r * 0.75
				ci.draw_polyline(PackedVector2Array([c + Vector2(-h, -h), c + Vector2(h, -h),
					c + Vector2(h, h), c + Vector2(-h, h), c + Vector2(-h, -h), c + Vector2(h, -h)]),
					col, w, true)
			&"Triangle":
				var pts := PackedVector2Array()
				for k in 5:
					var a := -PI / 2 + TAU * k / 3
					pts.append(c + Vector2(cos(a), sin(a)) * r + Vector2(0, r * 0.15))
				ci.draw_polyline(pts, col, w, true)
			&"Cross":
				var d := r * 0.78
				ci.draw_line(c + Vector2(-d, -d), c + Vector2(d, d), col, w, true)
				ci.draw_line(c + Vector2(-d, d), c + Vector2(d, -d), col, w, true)
			_:
				ci.draw_arc(c, r * 0.82, 0, TAU, 48, col, w, true)


## Shield badge: protected player (question too hard for their age).
class ShieldIcon:
	extends Control

	var color := Color(0.3, 0.75, 1.0):
		set(c):
			color = c
			queue_redraw()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var pts := PackedVector2Array([
			Vector2(w * 0.5, h * 0.04), Vector2(w * 0.92, h * 0.18), Vector2(w * 0.86, h * 0.58),
			Vector2(w * 0.5, h * 0.96), Vector2(w * 0.14, h * 0.58), Vector2(w * 0.08, h * 0.18)])
		draw_colored_polygon(pts, color)
		var inner := PackedVector2Array()
		for p in pts:
			inner.append(p.lerp(Vector2(w * 0.5, h * 0.45), 0.35))
		inner.append(inner[0])
		draw_polyline(inner, Color(1, 1, 1, 0.85), maxf(2.0, w * 0.07), true)


## Frame around one split-screen view: chamfered corners (filled with the
## screen background) and an orange edge, so views next to each other read
## as a set of matching console monitors.
class ViewFrame:
	extends Control

	var cut := 22.0
	var color := ORANGE

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)
		resized.connect(queue_redraw)

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var c := cut
		for corner in [[Vector2(0, 0), Vector2(c, 0), Vector2(0, c)],
				[Vector2(w, 0), Vector2(w, c), Vector2(w - c, 0)],
				[Vector2(w, h), Vector2(w - c, h), Vector2(w, h - c)],
				[Vector2(0, h), Vector2(0, h - c), Vector2(c, h)]]:
			draw_colored_polygon(PackedVector2Array(corner), BG)
		var edge := PackedVector2Array([Vector2(c, 1.5), Vector2(w - c, 1.5), Vector2(w - 1.5, c),
			Vector2(w - 1.5, h - c), Vector2(w - c, h - 1.5), Vector2(c, h - 1.5),
			Vector2(1.5, h - c), Vector2(1.5, c), Vector2(c, 1.5)])
		draw_polyline(edge, color, 3.0, true)
