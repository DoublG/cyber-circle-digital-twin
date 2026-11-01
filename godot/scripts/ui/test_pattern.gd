class_name TestPattern
extends Control
## Test screen for the physical setup (game mode SETUP), drawn over a whole
## screen on top of the tile slots (which show their tile number big):
##   which screen      "SCHERM 2 / 5", its tiles, monitor and node
##   edges / overscan  a 1 px border, corner marks and arrows: all four must be
##                     visible, "BOVEN" at the top (not mounted upside down)
##   scaling           the real window size next to the 1920x1080 it renders at;
##                     1 px lines at the left that must look sharp, not grey
##   colours           colour bars and an 11-step grey ramp: 0 % and 10 % must
##                     differ (black level), 90 % and 100 % too (white clipping)
##   live              a running clock and a sweeping bar: stops = frozen screen
## Plain 2D, cheap to draw.

var screen_number := 1
var screen_count := 1
var tiles: Array = []              # tile ids on this screen ([] = the overview)
var output := ""                   # e.g. "MONITOR 2" / "PREVIEW"
var node_name := ""
var _t := 0.0

const BARS := [Color.WHITE, Color.YELLOW, Color.CYAN, Color.GREEN, Color.MAGENTA, Color.RED, Color.BLUE, Color.BLACK]


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	if tiles.is_empty():                   # the overview: a clean test screen, no 3D behind it
		draw_rect(Rect2(0, 0, w, h), Retro.PANEL)
	# edges: 1 px border, corner marks and arrows pointing out
	draw_rect(Rect2(0.5, 0.5, w - 1, h - 1), Color.WHITE, false, 1.0)
	for c in [Vector2(0, 0), Vector2(w, 0), Vector2(0, h), Vector2(w, h)]:
		var dx := 1.0 if c.x == 0 else -1.0
		var dy := 1.0 if c.y == 0 else -1.0
		draw_line(c + Vector2(dx * 2, dy * 2), c + Vector2(dx * 90, dy * 2), Retro.AMBER, 4.0)
		draw_line(c + Vector2(dx * 2, dy * 2), c + Vector2(dx * 2, dy * 90), Retro.AMBER, 4.0)
	_arrow(Vector2(w / 2, 6), Vector2(0, -1))
	_arrow(Vector2(w / 2, h - 6), Vector2(0, 1))
	_arrow(Vector2(6, h / 2), Vector2(-1, 0))
	_arrow(Vector2(w - 6, h / 2), Vector2(1, 0))
	_text("BOVEN", Vector2(w / 2, 70), 26, Retro.AMBER)
	# centre cross
	draw_line(Vector2(w / 2 - 40, h / 2), Vector2(w / 2 + 40, h / 2), Color(Color.WHITE, 0.6), 2.0)
	draw_line(Vector2(w / 2, h / 2 - 40), Vector2(w / 2, h / 2 + 40), Color(Color.WHITE, 0.6), 2.0)
	# which screen
	var head := Rect2(w / 2 - 520, 100, 1040, 150)
	draw_rect(head, Color(Retro.BG, 0.92))
	draw_rect(head, Retro.TEAL, false, 3.0)
	var title := "SCHERM %d / %d" % [screen_number, screen_count] if not tiles.is_empty() else "OVERZICHT"
	_text(title, Vector2(w / 2, 172), 72, Retro.TEAL)
	var info := ("TEGELS " + "  ".join(tiles.map(func(id): return Retro.tile_label(id)))) if not tiles.is_empty() else "BEZOEKERSSCHERM"
	_text(info, Vector2(w / 2, 228), 30, Retro.CREAM)
	# output / node / resolution
	var win := get_window().size if get_window() else Vector2i.ZERO
	var line := "%s   NODE %s   BEELD 1920×1080   VENSTER %d×%d" % [output, node_name, win.x, win.y]
	_text(line, Vector2(w / 2, h - 236), 24, Retro.DIM)
	# 1 px sharpness lines (left, vertical and horizontal)
	for i in 12:
		draw_line(Vector2(30 + i * 2, h / 2 - 90), Vector2(30 + i * 2, h / 2 + 90), Color.WHITE, 1.0)
		draw_line(Vector2(70, h / 2 - 90 + i * 2), Vector2(130, h / 2 - 90 + i * 2), Color.WHITE, 1.0)
	_text("1 PX", Vector2(80, h / 2 + 120), 18, Retro.DIM)
	# colour bars and grey ramp
	var bw := (w - 240) / BARS.size()
	for i in BARS.size():
		draw_rect(Rect2(120 + i * bw, h - 200, bw, 70), BARS[i])
	var gw := (w - 240) / 11.0
	for i in 11:
		var g := i / 10.0
		draw_rect(Rect2(120 + i * gw, h - 126, gw, 54), Color(g, g, g))
		_text("%d%%" % (i * 10), Vector2(120 + (i + 0.5) * gw, h - 92), 18, Color.WHITE if g < 0.5 else Color.BLACK, false)
	# live: clock and a sweeping bar
	var sweep := fmod(_t, 2.0) / 2.0
	draw_rect(Rect2(120 + sweep * (w - 260), h - 60, 20, 30), Retro.GOOD)
	_text("%02d:%02d.%d" % [int(_t) / 60, int(_t) % 60, int(_t * 10) % 10], Vector2(w - 220, 300), 34, Retro.GOOD)


func _arrow(tip: Vector2, dir: Vector2) -> void:
	var side := Vector2(-dir.y, dir.x)
	draw_colored_polygon(PackedVector2Array([tip, tip - dir * 40 + side * 26, tip - dir * 40 - side * 26]), Retro.AMBER)


func _text(s: String, centre: Vector2, font_size: int, col: Color, outline := true) -> void:
	var font := Retro.FONT
	var width := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var pos := centre - Vector2(width / 2, -font_size * 0.35)
	if outline:
		draw_string_outline(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 6, Color(Retro.BG, 0.9))
	draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
