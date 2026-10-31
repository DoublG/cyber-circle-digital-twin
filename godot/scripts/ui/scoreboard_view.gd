class_name ScoreboardView
extends Control
## Ranking shown on all screens after every round: the players in the game by
## rounds survived, with this round's points, lives, their record (most rounds
## survived ever) and overall place.
## rows: [{name, tile, survived, lives, delta, out, record, rank}] sorted best first;
## with this round's lives change also {lives_before, change, was_out}: the
## rows first show the lives as they were, reveal_lives() shows the change
## (+1 green, -1 red, 0 lives: GEËXTERMINEERD).

const MAX_ROWS := 13

var _rows := []                  # [{data, panel, name, lives}]


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)


func show_scores(title: String, subtitle: String, rows: Array, revealed := true) -> void:
	_rows.clear()
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
		var out: bool = r.out if revealed else r.get("was_out", r.out)
		var col := Retro.BG if i == 0 else (Retro.DIM if out else Retro.CREAM)
		var style: StyleBoxFlat
		if i == 0:
			style = Retro.panel(Retro.AMBER, Retro.CREAM, 3, 14, 20)
		elif out:
			style = Retro.panel(Color(0.06, 0.06, 0.06), Color(0.2, 0.2, 0.2), 2, 14, 20)
		else:
			style = Retro.panel(Retro.PANEL, Retro.ORANGE.darkened(0.35), 2, 14, 20)
		var lives: int = r.get("lives", 0) if revealed else r.get("lives_before", r.get("lives", 0))
		if r.get("new", false):
			style = Retro.panel(Color(0.02, 0.16, 0.15), Retro.TEAL, 3, 14, 20)
		var cells := ["%02d" % (i + 1) if not r.get("new", false) else "+",
			r.name.to_upper() + ("  [UIT]" if out else ("  NIEUW!" if r.get("new", false) else "")),
			"T%02d" % r.tile, "%+d" % r.delta if not r.get("new", false) else "", "♥".repeat(lives), str(r.get("survived", 0)),
			str(r.get("record", 0)), "#%d" % r.rank if r.get("rank", 0) > 0 else "-"]
		var row := _row(px, col, cells, style)
		if i != 0 and not r.out:  # colour the round points, lives, rounds and place
			var h := row.get_child(0)
			h.get_child(3).add_theme_color_override("font_color", Retro.GOOD if r.delta > 0 else (Retro.BAD if r.delta < 0 else Retro.DIM))
			h.get_child(4).add_theme_color_override("font_color", Color(1.0, 0.2, 0.3))
			h.get_child(5).add_theme_color_override("font_color", Retro.AMBER)
			h.get_child(7).add_theme_color_override("font_color", Retro.TEAL)
		list.add_child(row)
		_rows.append({"data": r, "panel": row, "name": row.get_child(0).get_child(1),
			"lives": row.get_child(0).get_child(4)})
		if revealed and r.get("out") and not r.get("was_out", true):
			_mark_exterminated(_rows.back())
		if r.get("new", false):                    # welcome: slides in, teal glow
			row.get_child(0).get_child(1).add_theme_color_override("font_color", Retro.TEAL)
			row.modulate.a = 0.0
			var tw := row.create_tween()
			tw.tween_property(row, "modulate:a", 1.0, 0.6)
			tw.tween_property(row, "modulate", Color(1.4, 1.4, 1.4), 0.3)
			tw.tween_property(row, "modulate", Color.WHITE, 0.4)
	if revealed:
		_banner_if_exterminated()


## (rebuilt after the change, e.g. a player joined: the banner again)
func _banner_if_exterminated() -> void:
	var names := _rows.filter(func(e): return e.data.out and not e.data.get("was_out", true)) \
		.map(func(e): return e.data.name.to_upper())
	if not names.is_empty():
		_exterminate_banner(names)


## The lives change: hearts +1 (green) / -1 (red), 0 lives: GEËXTERMINEERD
## (the row turns red and blinks, a big banner over the board, a red flash).
func reveal_lives() -> void:
	var doomed := []
	for e in _rows:
		if e.data.get("change", 0) < 0 and e.data.lives == 0 and not e.data.get("was_out", false):
			doomed.append(e.data.name.to_upper())
	if not doomed.is_empty():
		_exterminate_banner(doomed)
	for e in _rows:
		var r: Dictionary = e.data
		var d: int = r.get("change", 0)
		if d == 0 or r.get("was_out", false):
			continue
		var lives: Label = e.lives
		lives.text = "♥".repeat(r.lives) + ("+" if d > 0 else "")
		lives.add_theme_color_override("font_color", Retro.GOOD if d > 0 else Retro.BAD)
		var tw := lives.create_tween()
		lives.pivot_offset = lives.size / 2.0
		tw.tween_property(lives, "scale", Vector2(1.5, 1.5), 0.15)
		tw.tween_property(lives, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK)
		if r.lives == 0:
			_mark_exterminated(e)


func _exterminate_banner(names: Array) -> void:
	var flash := ColorRect.new()                   # the whole board flashes red
	flash.color = Color(1.0, 0.05, 0.0, 0.55)
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(flash)
	var ft := flash.create_tween()
	ft.tween_property(flash, "color:a", 0.0, 0.6)
	ft.tween_callback(flash.queue_free)
	var banner := PanelContainer.new()
	banner.add_theme_stylebox_override("panel", Retro.panel(Color(0.35, 0.0, 0.0), Retro.BAD, 8, 18, 30))
	banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)   # over the title: the rows stay readable
	banner.anchor_left = 0.04
	banner.anchor_right = 0.96
	banner.offset_left = 0
	banner.offset_right = 0
	banner.offset_top = 24
	var v := VBoxContainer.new()
	banner.add_child(v)
	v.add_child(Retro.label(84, Retro.CREAM, "☠  GEËXTERMINEERD  ☠"))
	v.add_child(Retro.label(56, Retro.AMBER, "  ·  ".join(names)))
	add_child(banner)
	banner.pivot_offset = Vector2(900, 120)
	banner.scale = Vector2(1.6, 1.6)
	banner.modulate.a = 0.0
	var tw := banner.create_tween()
	tw.tween_property(banner, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(banner, "modulate:a", 1.0, 0.2)
	var pulse := banner.create_tween().set_loops()
	pulse.tween_property(banner, "self_modulate", Color(1.5, 0.6, 0.6), 0.3)
	pulse.tween_property(banner, "self_modulate", Color.WHITE, 0.3)


func _mark_exterminated(e: Dictionary) -> void:
	e.name.text = e.data.name.to_upper() + "  GEËXTERMINEERD"
	e.name.add_theme_color_override("font_color", Retro.BG)
	e.lives.text = "-"
	e.panel.add_theme_stylebox_override("panel", Retro.panel(Retro.BAD, Retro.CREAM, 3, 14, 20))
	var tw: Tween = e.panel.create_tween().set_loops(4)
	tw.tween_property(e.panel, "modulate:a", 0.35, 0.18)
	tw.tween_property(e.panel, "modulate:a", 1.0, 0.18)


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
