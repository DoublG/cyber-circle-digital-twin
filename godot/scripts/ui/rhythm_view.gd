class_name RhythmView
extends Control
## The rhythm round on a player's own view: 4 lanes (one per tile icon, in
## the tile's order and colours), the symbols falling from the top to the line,
## the yellow band around it, the points and the combo on top.
## Drawn from the round's clock, so it freezes when the game is paused.

const PANEL_WIDTH := 860.0
const TOP := 150.0               # below the name plate
const HEADER := 96.0             # points / combo
const BOTTOM := 40.0
const FLASH := 0.5               # s a judgement stays visible

var round: RhythmRound
var tile_id := 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if round == null or not round.state.has(tile_id):
		return
	var st: Dictionary = round.state[tile_id]
	var w := minf(PANEL_WIDTH, size.x - 80.0)
	var panel := Rect2((size.x - w) / 2, TOP, w, size.y - TOP - BOTTOM)
	draw_rect(panel, Color(Retro.PANEL, 0.9))
	draw_rect(panel, Retro.ORANGE, false, 3.0)

	# header: points and combo
	var pts: int = round.points.get(tile_id, 0)
	_text("%d PUNTEN" % pts, Vector2(panel.position.x + 28, TOP + 62), 48, Retro.AMBER)
	if st.combo >= 2:
		_text("COMBO %d" % st.combo, Vector2(panel.end.x - 28, TOP + 62), 40, Retro.GOOD, HORIZONTAL_ALIGNMENT_RIGHT)
	var field := Rect2(panel.position.x, TOP + HEADER, w, panel.size.y - HEADER)
	draw_line(field.position, Vector2(field.end.x, field.position.y), Color(Retro.ORANGE, 0.5), 2.0)

	# lanes, the yellow band and the line
	var travel := (field.size.y - 24.0) / (1.0 + round.band)
	var line_y := field.position.y + travel
	var lane_w := w / 4.0
	for k in range(1, 4):
		var x := field.position.x + k * lane_w
		draw_line(Vector2(x, field.position.y), Vector2(x, field.end.y), Color(Retro.DIM, 0.25), 2.0)
	var band_h := round.band * travel
	draw_rect(Rect2(field.position.x, line_y - band_h, w, band_h * 2), Color(Retro.AMBER, 0.22))
	for y in [line_y - band_h, line_y + band_h]:
		draw_line(Vector2(field.position.x, y), Vector2(field.end.x, y), Color(Retro.AMBER, 0.8), 3.0)
	var line_h := maxf(round.line * travel, 3.0)
	draw_rect(Rect2(field.position.x, line_y - line_h, w, line_h * 2), Color(Retro.CREAM, 0.18))
	draw_line(Vector2(field.position.x, line_y), Vector2(field.end.x, line_y), Retro.CREAM, 4.0)

	# the targets on the line, lit up by the last judgement in that lane
	var r := minf(lane_w * 0.3, 70.0)
	for k in 4:
		var b: StringName = CyberTile.BUTTONS[k]
		var c := Vector2(field.position.x + (k + 0.5) * lane_w, line_y)
		var last: Dictionary = st.last[k]
		var age: float = round.clock - last.get("at", -99.0)
		var col: Color = CyberTile.BUTTON_COLORS[b]
		Retro.draw_icon(self, b, c, r, Color(col, 0.35), false)
		if age < FLASH and last.points > 0:
			var f := age / FLASH
			draw_arc(c, r * (1.0 + f), 0, TAU, 40, Color(col, 1.0 - f), 6.0, true)
		if age < FLASH:
			var tc: Color = Retro.GOOD if last.points >= round.points_line else (
				Retro.AMBER if last.points > 0 else (Retro.BAD if last.points < 0 else Retro.DIM))
			_text(last.text, c - Vector2(0, band_h + 26 + 30 * age / FLASH), 46, Color(tc, 1.0 - age / FLASH),
				HORIZONTAL_ALIGNMENT_CENTER)

	# the falling symbols
	for i in range(maxi(round._first - 8, 0), round.notes.size()):
		var n: Dictionary = round.notes[i]
		var pos: float = (round.clock - n.t) / n.fall      # -1 at the top, 0 on the line
		if pos < -1.0:
			break
		var judged: int = st.judged.get(i, -99)
		if judged > 0:
			continue                                         # hit: gone
		var y: float = line_y + pos * travel
		if y - r > field.end.y:
			continue
		var b: StringName = CyberTile.BUTTONS[n.lane]
		var col: Color = CyberTile.BUTTON_COLORS[b]
		if judged == 0:                                      # missed: grey, falling out
			col = Color(Retro.DIM, clampf(1.0 - (pos - round.band) * 4.0, 0.0, 0.6))
		Retro.draw_icon(self, b, Vector2(field.position.x + (n.lane + 0.5) * lane_w, y), r, col)


func _text(s: String, pos: Vector2, font_size: int, col: Color,
		align := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	var font := Retro.FONT
	var width := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var x := pos.x
	if align == HORIZONTAL_ALIGNMENT_RIGHT:
		x -= width
	elif align == HORIZONTAL_ALIGNMENT_CENTER:
		x -= width / 2
	draw_string_outline(font, Vector2(x, pos.y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 6, Color(Retro.BG, col.a * 0.9))
	draw_string(font, Vector2(x, pos.y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
