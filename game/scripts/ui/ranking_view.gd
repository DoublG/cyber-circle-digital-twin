class_name RankingView
extends Control
## UITSLAG: shown on all screens at the end of a round with places, before the
## scoreboard. This round's places (1, 2, 3 ..., shared when equal), what
## decided them (points, level, ...) and the life each player will gain or
## lose there: +♥ green, -♥ red, ☠ the last life (exterminated on the
## scoreboard). The rows come in from the last place up to the 1st (gold),
## then the lives badges stamp in.
## rows: [{name, tile, place, score, change (-1 / 0 / +1), doomed}] best first.

const ROWS_TIME := 2.4           # s: all rows in, last place first
const BADGE_DELAY := 0.4         # s after the rows: the lives badges

var _badges: Array[Label] = []
var _gap := 30                   # between the cells of a row (tighter in two columns)


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)


var _row_panels := []              # [{tile, panel}]


## The players at this screen's tiles: their row marked (ScoreboardView.mark_own).
func highlight_tiles(tiles: Array) -> void:
	for e in _row_panels:
		if e.tile in tiles:
			ScoreboardView.mark_own(e.panel)


func show_ranking(title: String, label: String, rows: Array) -> void:
	_row_panels.clear()
	_badges.clear()
	for c in get_children():
		c.queue_free()
	add_child(Retro.background())
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 70
	box.offset_right = -70
	box.offset_top = 40
	box.offset_bottom = -40
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	var titles := VBoxContainer.new()
	titles.custom_minimum_size.y = ScoreboardView.HEADER_HEIGHT
	titles.alignment = BoxContainer.ALIGNMENT_CENTER
	titles.add_theme_constant_override("separation", 8)
	box.add_child(titles)
	titles.add_child(Retro.title_bar("UITSLAG", 76))
	titles.add_child(Retro.label(38, Retro.TEAL, title.to_upper()))

	var n := rows.size()                          # (any number: mobile tiles too)
	var px := 44 if n <= 8 else 30
	_gap = 30 if n < ScoreboardView.TWO_COLUMNS else 16
	var cols := ScoreboardView.table(box, n)       # (two columns from 17 rows)
	for c in cols:
		c.add_child(_row(px, Retro.DIM, ["#", ScoreboardView.NAME_PAD + "SPELER", "TEGEL", label, "LEVEN"], null))
	var ranked := rows.any(func(r): return r.place > 1)   # (all equal: nobody in gold)
	var step := ROWS_TIME / maxf(n, 1)
	for i in n:
		var r: Dictionary = rows[i]
		var first: bool = ranked and r.place == 1
		var style := Retro.panel(Retro.AMBER, Retro.CREAM, 3, 14, 20) if first \
			else Retro.panel(Retro.PANEL, Retro.ORANGE.darkened(0.35), 2, 14, 20)
		var row := _row(px, Retro.BG if first else Retro.CREAM, [str(r.place), ScoreboardView.NAME_PAD + r.name.to_upper(),
			Retro.tile_label(r.tile), str(r.score), _badge_text(r)], style)
		var h := row.get_child(0)
		if not first:
			h.get_child(3).add_theme_color_override("font_color", Retro.AMBER)
		var badge: Label = h.get_child(4)
		badge.add_theme_color_override("font_color", Retro.GOOD if r.change > 0 else (Retro.BAD if r.change < 0 else Retro.DIM))
		if first and r.change > 0:
			badge.add_theme_color_override("font_color", Retro.BG)
		badge.modulate.a = 0.0
		_badges.append(badge)
		cols[ScoreboardView.column(i, n, cols.size())].add_child(row)
		_row_panels.append({"tile": r.tile, "panel": row})
		row.modulate.a = 0.0                       # in from the last place up to the 1st
		var tw := row.create_tween()
		tw.tween_interval(step * (n - 1 - i))
		tw.tween_property(row, "modulate:a", 1.0, 0.25)
		if first:
			tw.tween_property(row, "modulate", Color(1.4, 1.4, 1.4), 0.15)
			tw.tween_property(row, "modulate", Color.WHITE, 0.3)
	for i in _badges.size():                       # then the lives: stamped in
		var b := _badges[i]
		var tw := b.create_tween()
		tw.tween_interval(ROWS_TIME + BADGE_DELAY + 0.08 * i)
		tw.tween_callback(func():
			b.pivot_offset = b.size / 2.0
			b.scale = Vector2(2.2, 2.2))
		tw.tween_property(b, "modulate:a", 1.0, 0.12)
		tw.parallel().tween_property(b, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		if rows[i].doomed:                         # the last life: blinks
			var blink := b.create_tween().set_loops()
			blink.tween_interval(ROWS_TIME + BADGE_DELAY + 0.5)
			blink.tween_property(b, "modulate:a", 0.3, 0.25)
			blink.tween_property(b, "modulate:a", 1.0, 0.25)


func _badge_text(r: Dictionary) -> String:
	if r.change > 0:
		return "+♥"
	if r.change < 0:
		return "-♥ ☠" if r.doomed else "-♥"
	return ""


## One table row; widths are fixed so the columns line up without a grid.
func _row(px: int, col: Color, cells: Array, style: StyleBoxFlat) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style if style else StyleBoxEmpty.new())
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", _gap)
	panel.add_child(h)
	var widths := [3, 0, 4, 7, 7]   # in characters; 0 = take the rest
	for k in cells.size():
		var l := Retro.label(px, col, cells[k],
			HORIZONTAL_ALIGNMENT_LEFT if k == 1 else HORIZONTAL_ALIGNMENT_RIGHT)
		if widths[k] == 0:
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			l.clip_text = true
			l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		else:
			l.custom_minimum_size.x = widths[k] * px * 0.62
		h.add_child(l)
	return panel
