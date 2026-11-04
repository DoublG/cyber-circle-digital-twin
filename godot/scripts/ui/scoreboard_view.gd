class_name ScoreboardView
extends Control
## The game's standing on all screens after every round (after this round's
## places: RankingView): the players in the game by rounds survived, with
## lives, their record (most rounds survived ever) and overall place.
## rows: [{name, tile, survived, lives, out, record, rank}] sorted best first;
## with this round's lives change also {lives_before, change, was_out}: the
## rows first show the lives as they were, reveal_lives() shows the change
## (+1 green, -1 red, 0 lives: GEËXTERMINEERD).

const HEADER_HEIGHT := 168       # title + subtitle; the GEËXTERMINEERD banner replaces them
const TWO_COLUMNS := 17          # from this many rows (mobile tiles): two columns side by side

var _rows := []                  # [{data, panel, name, lives}]
var _gap := 30                   # between the cells of a row (tighter in two columns)
var _header: Control


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
	_header = Control.new()                        # fixed height: the banner takes exactly this place
	_header.custom_minimum_size.y = HEADER_HEIGHT
	_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_header)
	var titles := VBoxContainer.new()
	titles.set_anchors_preset(Control.PRESET_FULL_RECT)
	titles.alignment = BoxContainer.ALIGNMENT_CENTER
	titles.add_theme_constant_override("separation", 8)
	_header.add_child(titles)
	titles.add_child(Retro.title_bar(title.to_upper(), 76))
	if subtitle != "":
		titles.add_child(Retro.label(38, Retro.TEAL, subtitle.to_upper()))

	var n := rows.size()                          # (any number: mobile tiles too)
	var px := 44 if n <= 8 else 30
	_gap = 30 if n < TWO_COLUMNS else 16
	var cols := table(box, n)
	for c in cols:
		c.add_child(_row(px, Retro.DIM, ["#", NAME_PAD + "SPELER", "TEGEL", "LEVENS", "RONDES", "RECORD", "PLAATS"], null))
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
			NAME_PAD + r.name.to_upper() + ("  [UIT]" if out else ("  NIEUW!" if r.get("new", false) else "")),
			Retro.tile_label(r.tile), "♥".repeat(lives), str(r.get("survived", 0)),
			str(r.get("record", 0)), "#%d" % r.rank if r.get("rank", 0) > 0 else "-"]
		var row := _row(px, col, cells, style)
		if i != 0 and not r.out:  # colour the lives, rounds and place
			var h := row.get_child(0)
			h.get_child(3).add_theme_color_override("default_color", LIVES)
			h.get_child(4).add_theme_color_override("font_color", Retro.AMBER)
			h.get_child(6).add_theme_color_override("font_color", Retro.TEAL)
		cols[column(i, n, cols.size())].add_child(row)
		_rows.append({"data": r, "panel": row, "name": row.get_child(0).get_child(1),
			"lives": row.get_child(0).get_child(3)})
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


## The table under the title: one column of rows, or two side by side from
## TWO_COLUMNS rows on (the first half left); in a room that scales it down
## (as a whole) when it is too tall, centred. Returns the columns (VBoxes).
## (Also used by RankingView.)
static func table(box: Container, n: int) -> Array[VBoxContainer]:
	var room := Control.new()
	room.size_flags_vertical = Control.SIZE_EXPAND_FILL
	room.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(room)
	var t := HBoxContainer.new()
	t.add_theme_constant_override("separation", 40)
	room.add_child(t)
	var cols: Array[VBoxContainer] = []
	for k in (2 if n >= TWO_COLUMNS else 1):
		var c := VBoxContainer.new()
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c.add_theme_constant_override("separation", 10 if n <= 8 else 5)
		t.add_child(c)
		cols.append(c)
	var fit := func():
		var need := t.get_combined_minimum_size().y
		var k := minf(1.0, room.size.y / need) if need > 0.0 else 1.0
		t.scale = Vector2(k, k)
		t.size = Vector2(room.size.x / k, need)
		t.position = Vector2(0, floorf(maxf(room.size.y - need * k, 0.0) / 2.0))
	room.resized.connect(fit)
	t.minimum_size_changed.connect(fit)
	return cols


## The column of row i (of n) in a table with `count` columns.
static func column(i: int, n: int, count: int) -> int:
	return i / ceili(float(n) / count)


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
		var lives: RichTextLabel = e.lives
		if d > 0:                                  # the hearts they had stay, only the new one (and the +) green
			var had: int = r.get("lives_before", r.lives - d)
			_set_lives(lives, "♥".repeat(had) + "[color=#%s]%s[/color]" % [Retro.GOOD.to_html(false), "♥".repeat(r.lives - had)], "+")
		else:                                      # the hearts left stay, the lost one greyed out, then "-"
			var had: int = r.get("lives_before", r.lives - d)
			_set_lives(lives, "♥".repeat(r.lives) + "[color=#%s]%s[/color]" % [Retro.DIM.to_html(false),
				"♥".repeat(maxi(had - r.lives, 0))], "-")
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
	var banner := PanelContainer.new()            # in place of the title: never over the rows
	banner.add_theme_stylebox_override("panel", Retro.panel(Color(0.35, 0.0, 0.0), Retro.BAD, 8, 18, 10))
	banner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	banner.anchor_left = 0.04
	banner.anchor_right = 0.96
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 0)
	banner.add_child(v)
	v.add_child(Retro.label(64, Retro.CREAM, "☠  GEËXTERMINEERD  ☠"))
	var who := Retro.label(42, Retro.AMBER, "  ·  ".join(names))
	who.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	who.clip_text = true
	v.add_child(who)
	for c in _header.get_children():               # the title steps aside
		if c != banner and not c.has_meta(&"banner"):
			c.visible = false
	banner.set_meta(&"banner", true)
	_header.add_child(banner)
	banner.pivot_offset = _header.size / 2.0 - Vector2(_header.size.x * 0.04, 0)
	banner.scale = Vector2(1.12, 1.12)
	banner.modulate.a = 0.0
	var tw := banner.create_tween()
	tw.tween_property(banner, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(banner, "modulate:a", 1.0, 0.2)
	var pulse := banner.create_tween().set_loops()
	pulse.tween_property(banner, "self_modulate", Color(1.5, 0.6, 0.6), 0.3)
	pulse.tween_property(banner, "self_modulate", Color.WHITE, 0.3)


func _mark_exterminated(e: Dictionary) -> void:
	e.name.text = e.name.text.left(NAME_PAD.length()) + "☠ %s ☠" % e.data.name.to_upper()   # (keeps ▶; the banner says GEËXTERMINEERD)
	e.name.add_theme_color_override("font_color", Retro.BG)
	_set_lives(e.lives, "-")
	e.panel.add_theme_stylebox_override("panel", Retro.panel(Retro.BAD, Retro.CREAM, 3, 14, 20))
	var tw: Tween = e.panel.create_tween().set_loops(4)
	tw.tween_property(e.panel, "modulate:a", 0.35, 0.18)
	tw.tween_property(e.panel, "modulate:a", 1.0, 0.18)


## The players at the tiles in front of this screen (ScreenWall: the tiles
## this screen shows) find their row at once: a thick teal frame with a bar
## on the left, ▶ before their name, their tile number in teal. The order
## stays the ranking.
func highlight_tiles(tiles: Array) -> void:
	for e in _rows:
		if e.data.tile in tiles:
			mark_own(e.panel)


## (Also used by RankingView.) Row cells: 0 #, 1 name, 2 tile, ...
static func mark_own(panel: PanelContainer) -> void:
	var style := panel.get_theme_stylebox("panel") as StyleBoxFlat
	style = style.duplicate() if style else Retro.panel(Retro.PANEL, Retro.TEAL, 2, 14, 20)
	style.border_color = Retro.TEAL
	style.set_border_width_all(5)
	style.border_width_left = 18
	panel.add_theme_stylebox_override("panel", style)
	var h := panel.get_child(0)
	var name_label := h.get_child(1) as Label
	if not name_label.text.begins_with("▶"):        # (into the room every name keeps for it: the names line up)
		name_label.text = "▶ " + name_label.text.trim_prefix(NAME_PAD)
	if style.bg_color.v < 0.5:                     # (not on the 1st place's amber: unreadable)
		(h.get_child(2) as Label).add_theme_color_override("font_color", Retro.TEAL)


const LIVES_CELL := 3
const NAME_PAD := "  "                 # every name starts with this room: "▶ " on this screen's players (mark_own)
const LIVES := Color(1.0, 0.2, 0.3)


## sign: "+" (green) after a gained heart, "-" (red) after a lost one; without
## it the same room stays empty, so the hearts of every row line up.
static func _set_lives(cell: RichTextLabel, bbcode: String, sign := "") -> void:
	var col: String = {"+": Retro.GOOD.to_html(false), "-": Retro.BAD.to_html(false)}.get(sign, "00000000")
	cell.text = "[right]%s[color=#%s]%s[/color][/right]" % [bbcode, col, sign if sign != "" else "+"]


## One table row; widths are fixed so the columns line up without a grid.
func _row(px: int, col: Color, cells: Array, style: StyleBoxFlat) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style if style else StyleBoxEmpty.new())
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", _gap)
	panel.add_child(h)
	var widths := [3, 0, 4, 6, 6, 6, 6]   # in characters; 0 = take the rest
	for k in cells.size():
		if k == LIVES_CELL:                   # the hearts: more than one colour (the new one green)
			var rt := RichTextLabel.new()
			rt.bbcode_enabled = true
			rt.fit_content = true
			rt.scroll_active = false
			rt.autowrap_mode = TextServer.AUTOWRAP_OFF
			rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
			rt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			rt.add_theme_font_size_override("normal_font_size", px)
			rt.add_theme_color_override("default_color", col)
			rt.custom_minimum_size.x = widths[k] * px * 0.62
			_set_lives(rt, cells[k])
			h.add_child(rt)
			continue
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
