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
## For a screen root: every Label inside uses the retro font (the scenes of
## scenes/ui have it on their root).
const THEME := preload("res://scenes/ui/retro_theme.tres")

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
