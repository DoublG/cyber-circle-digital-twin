class_name ScoreboardView
extends Control
## Ranking shown on all screens after every round: the players in the game by
## rounds survived, with this round's points, lives, their record (most rounds
## survived ever) and overall place.
## rows: [{name, tile, survived, lives, delta, out, record, rank}] sorted best first.

const MAX_ROWS := 13


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)


func show_scores(title: String, subtitle: String, rows: Array) -> void:
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
	box.add_child(Retro.title_bar(title.to_upper(), 76))
	if subtitle != "":
		box.add_child(Retro.label(38, Retro.TEAL, subtitle.to_upper()))

	var n := mini(rows.size(), MAX_ROWS)
	var px := 44 if n <= 8 else 30
	var list := VBoxContainer.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.alignment = BoxContainer.ALIGNMENT_CENTER
	list.add_theme_constant_override("separation", 10 if n <= 8 else 5)
	box.add_child(list)
	list.add_child(_row(px, Retro.DIM, ["#", "SPELER", "TEGEL", "PUNTEN", "LEVENS", "RONDES", "RECORD", "PLAATS"], null))
	for i in n:
		var r: Dictionary = rows[i]
		var col := Retro.BG if i == 0 else (Retro.DIM if r.out else Retro.CREAM)
		var style: StyleBoxFlat
		if i == 0:
			style = Retro.panel(Retro.AMBER, Retro.CREAM, 3, 14, 20)
		elif r.out:
			style = Retro.panel(Color(0.06, 0.06, 0.06), Color(0.2, 0.2, 0.2), 2, 14, 20)
		else:
			style = Retro.panel(Retro.PANEL, Retro.ORANGE.darkened(0.35), 2, 14, 20)
		var cells := ["%02d" % (i + 1), r.name.to_upper() + ("  [UIT]" if r.out else ""),
			"T%02d" % r.tile, "%+d" % r.delta, "♥".repeat(r.get("lives", 0)), str(r.get("survived", 0)),
			str(r.get("record", 0)), "#%d" % r.rank if r.get("rank", 0) > 0 else "-"]
		var row := _row(px, col, cells, style)
		if i != 0 and not r.out:  # colour the round points, lives, rounds and place
			var h := row.get_child(0)
			h.get_child(3).add_theme_color_override("font_color", Retro.GOOD if r.delta > 0 else (Retro.BAD if r.delta < 0 else Retro.DIM))
			h.get_child(4).add_theme_color_override("font_color", Color(1.0, 0.2, 0.3))
			h.get_child(5).add_theme_color_override("font_color", Retro.AMBER)
			h.get_child(7).add_theme_color_override("font_color", Retro.TEAL)
		list.add_child(row)


## One table row; widths are fixed so the columns line up without a grid.
func _row(px: int, col: Color, cells: Array, style: StyleBoxFlat) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style if style else StyleBoxEmpty.new())
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 30)
	panel.add_child(h)
	var widths := [3, 0, 4, 6, 6, 6, 6, 6]   # in characters; 0 = take the rest
	for k in cells.size():
		var l := Retro.label(px, col, cells[k],
			HORIZONTAL_ALIGNMENT_LEFT if k == 1 else HORIZONTAL_ALIGNMENT_RIGHT)
		if widths[k] == 0:
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			l.clip_text = true
		else:
			l.custom_minimum_size.x = widths[k] * px * 0.62
		h.add_child(l)
	return panel
