class_name CodeView
extends Control
## Code kraken on a player's own view: the board - every try of this code,
## each icon big in its own box, the box coloured by its hint (green = right
## place, yellow = in the code, another place, grey = not in it), the row
## being typed below them (empty boxes to go), which code it is (how long,
## repeats or not), the points, and the legend. Cracked: the code in green, the points, then the
## next code. Drawn from the round's state (also on a display node).

const PANEL_WIDTH := 860.0
const TOP := 150.0               # below the name plate
const HEADER := 112.0            # code number / points
const FOOTER := 64.0             # the legend
const BOTTOM := 40.0
const ROW_H := 128.0             # a row of big boxes
const MAX_BOX := 120.0
const CRACKED_SHOW := 2.2        # s "GEKRAAKT!" stays

var round: CodeRound
var tile_id := 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if round == null or not round.state.has(tile_id) or round.codes.is_empty():
		return
	var st: Dictionary = round.state[tile_id]
	var w := minf(PANEL_WIDTH, size.x - 80.0)
	var panel := Rect2((size.x - w) / 2, TOP, w, size.y - TOP - BOTTOM)
	draw_rect(panel, Color(Retro.PANEL, 0.92))
	draw_rect(panel, Retro.ORANGE, false, 3.0)
	var x0 := panel.position.x + 28.0
	var age: float = round.clock - st.last.get("at", -99.0)
	var cracked_shown: bool = st.last.get("text", "") == "GEKRAAKT!" and age < CRACKED_SHOW
	var level: int = mini(st.level - (1 if cracked_shown else 0), round.codes.size() - 1)   # (cracked: still that code)
	var c: Dictionary = round.codes[level]

	# header: which code, how hard, the points
	var pts: int = round.points.get(tile_id, 0)
	_text("CODE %d" % (level + 1), Vector2(x0, TOP + 54), 48, Retro.AMBER)
	_text("%d PUNTEN" % pts, Vector2(panel.end.x - 28, TOP + 54), 40, Retro.AMBER, HORIZONTAL_ALIGNMENT_RIGHT)
	var kind := "%d ICONEN · %s" % [c.length, "EEN ICOON KAN VAKER" if c.repeats else "ALLEMAAL VERSCHILLEND"]
	_text(kind, Vector2(x0, TOP + 92), 26, Retro.TEAL)
	draw_line(Vector2(panel.position.x, TOP + HEADER), Vector2(panel.end.x, TOP + HEADER), Color(Retro.ORANGE, 0.5), 2.0)

	var board := Rect2(panel.position.x, TOP + HEADER + 10, w, panel.size.y - HEADER - FOOTER - 20)
	if cracked_shown:
		_draw_cracked(st, board, age)
	else:
		_draw_board(st, c, board, x0)

	# the legend: the three box colours
	var ly := panel.end.y - FOOTER / 2 + 10
	var items := [[CodeRound.HINT_GREEN, "JUISTE PLEK"], [CodeRound.HINT_YELLOW, "ANDERE PLEK"], [CodeRound.HINT_OFF.lightened(0.25), "ZIT ER NIET IN"]]
	var fs := 24
	var need := 0.0
	for it in items:
		need += 38 + Retro.FONT.get_string_size(it[1], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 34
	if need - 34 > w - 60:                     # (a narrow view: smaller, so all three fit)
		fs = int(fs * (w - 60) / (need - 34))
	var sq := fs * 1.15
	var lx := panel.position.x + 30.0
	for it in items:
		_box(Rect2(lx, ly - sq * 0.8, sq, sq), it[0], 0)
		_text(it[1], Vector2(lx + sq + 10, ly), fs, Retro.CREAM)
		lx += sq + 10 + Retro.FONT.get_string_size(it[1], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + fs * 1.4


## The tries so far (the last ones that fit), then the row being typed: big
## icons, each in a box in its hint's colour.
func _draw_board(st: Dictionary, c: Dictionary, board: Rect2, x0: float) -> void:
	var tries: Array = st.tries
	var rows := maxi(int(board.size.y / ROW_H), 1)
	var first: int = maxi(tries.size() + 1 - rows, 0)
	var slot: float = minf((board.size.x - 110.0) / c.length, MAX_BOX + 14.0)
	var box := minf(slot - 14.0, ROW_H - 18.0)
	var r := box * 0.3
	var y := board.position.y + ROW_H / 2
	for i in range(first, tries.size() + 1):
		var typing := i == tries.size()
		var guess: Array = st.guess if typing else tries[i].guess
		_text("%d" % (i + 1), Vector2(x0, y + 14), 40, Retro.CREAM if typing else Retro.DIM)
		for k in c.length:
			var center := Vector2(x0 + 70 + (k + 0.5) * slot, y)
			var rect := Rect2(center - Vector2(box, box) / 2, Vector2(box, box))
			if typing:                               # being typed: cream boxes, the next one blinks
				var next: bool = k == guess.size()
				var a := 0.45 + 0.5 * absf(sin(round.clock * 4.0)) if next else (0.8 if k < guess.size() else 0.3)
				draw_rect(rect, Color(Retro.CREAM, a), false, 4.0)
			else:
				var m: int = tries[i].marks[k]
				_box(rect, [CodeRound.HINT_OFF.lightened(0.25), CodeRound.HINT_YELLOW, CodeRound.HINT_GREEN][m], m)
			if k < guess.size():
				var b: StringName = CyberTile.BUTTONS[guess[k]]
				var col: Color = CyberTile.BUTTON_COLORS[b]
				if not typing and tries[i].marks[k] == 0:
					col = Color(col, 0.45)               # not in the code: the icon dims too
				Retro.draw_icon(self, b, center, r, col, typing)
		y += ROW_H
	if tries.is_empty() and st.guess.is_empty():
		_text("DRUK %d ICONEN OP JE TEGEL" % c.length, Vector2(board.position.x + board.size.x / 2, y + 10), 32,
			Color(Retro.AMBER, 0.6 + 0.4 * absf(sin(round.clock * 3.0))), HORIZONTAL_ALIGNMENT_CENTER)


## A hint box: filled in its colour (dark), a border in it (green: thick).
func _box(rect: Rect2, col: Color, mark: int) -> void:
	draw_rect(rect, Color(col, 0.22 if mark > 0 else 0.35))
	draw_rect(rect, col, false, 6.0 if mark == 2 else 4.0)


## Cracked: the code in green, in how many tries, the points.
func _draw_cracked(st: Dictionary, board: Rect2, age: float) -> void:
	var cx := board.position.x + board.size.x / 2
	var cy := board.position.y + board.size.y * 0.4
	var pop := clampf(age / 0.25, 0.0, 1.0)
	_text("GEKRAAKT!", Vector2(cx, cy - 70), int(72 + 24 * (1.0 - pop)), Retro.GOOD, HORIZONTAL_ALIGNMENT_CENTER)
	var code: Array = st.last.get("code", [])
	var slot := 100.0
	for k in code.size():
		var center := Vector2(cx + (k - (code.size() - 1) / 2.0) * slot, cy + 30)
		draw_rect(Rect2(center - Vector2(40, 40), Vector2(80, 80)), Color(CodeRound.HINT_GREEN, 0.18))
		draw_rect(Rect2(center - Vector2(40, 40), Vector2(80, 80)), CodeRound.HINT_GREEN, false, 4.0)
		var b: StringName = CyberTile.BUTTONS[code[k]]
		Retro.draw_icon(self, b, center, 28, CyberTile.BUTTON_COLORS[b])
	var tries: int = st.last.get("tries", 0)
	_text("IN %d POGING%s  ·  +%d PUNTEN" % [tries, "" if tries == 1 else "EN", st.last.get("points", 0)],
		Vector2(cx, cy + 130), 34, Retro.CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	_text("VOLGENDE CODE: MOEILIJKER", Vector2(cx, cy + 180), 28, Retro.AMBER, HORIZONTAL_ALIGNMENT_CENTER)


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
