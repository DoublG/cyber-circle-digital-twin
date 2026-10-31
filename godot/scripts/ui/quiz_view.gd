class_name QuizView
extends Control
## Shared quiz screen, a slide show - one step at a time, with a fade between:
##   read      the question + the 4 buttons (icon and colour), no answers yet
##   question  the answers fade in, the countdown runs; small indicators of
##             who answered (not what)
##   timeup    "TIJD OM!"
##   answers   every player's chosen icon (big player cards)
##   reveal    who was right (green / red; shield = protected) - the right
##             answer itself is never shown (visitors could memorise it)
## The answers are laid out like the icons on the glass plate, as seen by a
## player standing on the tile and facing the robot:
##     Square   Triangle
##     Cross    Circle
## The question gets most of the room, the buttons are compact. Long texts
## shrink to fit their panel. A question video is shown full width before
## answering ("video" phase) or left of the question while answering; a
## picture ("image") left of the question.
## Players for whom the question is too hard (age) get a blue shield badge.

var _header: Label
var _question: Label
var _body: Label                 # longer question text
var _q_panel: PanelContainer
var _media: TextureRect
var _text_area: Control
var _grid: GridContainer
var _fit_keys := {}              # Control -> last fitted text + size
var _countdown: CountdownRing
var _cards: Array[PanelContainer] = []
var _keys: Array[PanelContainer] = []
var _icons: Array[Retro.ButtonIcon] = []
var _answer_labels: Array[Label] = []
var _tags: Array[Label] = []
var _bar: ProgressBar
var _status: Label
var _meta: Label                 # category + age range
var _legend: HBoxContainer       # "shield = protected" explanation
var _content: VBoxContainer      # everything below the background (faded between steps)
var _slide: VBoxContainer        # players slide: timeup / answers / reveal
var _slide_title: Label
var _slide_status: Label
var _player_grid: GridContainer
var _player_cards := {}          # tile_id -> {panel, name, icon, mark, shield}
var _answered: HFlowContainer    # question step: who answered already (not what)
var _answered_chips := {}        # tile_id -> Label
var _last_phase := ""

const Q_SIZE := 62               # question (shrinks to fit)
const BODY_SIZE := 38            # longer text under it
const ANSWER_SIZE := 44


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(Retro.background())
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 44
	box.offset_right = -44
	box.offset_top = 36
	box.offset_bottom = -36
	box.add_theme_constant_override("separation", 16)
	add_child(box)
	_content = box

	# header: QUIZ plate + question number, countdown on the right
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 24)
	box.add_child(top)
	var badge := Retro.panel_container(Retro.ORANGE, Retro.AMBER, 0, 14, 22)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	badge.add_child(Retro.label(52, Retro.BG, "QUIZ"))
	top.add_child(badge)
	_header = Retro.label(52, Retro.AMBER, "", HORIZONTAL_ALIGNMENT_LEFT)
	_header.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(_header)
	_meta = Retro.label(34, Retro.TEAL)
	_meta.add_theme_stylebox_override("normal", Retro.panel(Retro.PANEL, Retro.TEAL, 3, 10, 18))
	_meta.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(_meta)
	top.add_child(Retro.stripes(false))
	_countdown = CountdownRing.new()
	_countdown.custom_minimum_size = Vector2(140, 140)
	top.add_child(_countdown)

	# players slide (time up / answers / who was right)
	_slide = VBoxContainer.new()
	_slide.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_slide.alignment = BoxContainer.ALIGNMENT_CENTER
	_slide.add_theme_constant_override("separation", 36)
	_slide.visible = false
	box.add_child(_slide)
	_slide_title = Retro.label(110, Retro.AMBER)
	_slide.add_child(_slide_title)
	_player_grid = GridContainer.new()
	_player_grid.add_theme_constant_override("h_separation", 24)
	_player_grid.add_theme_constant_override("v_separation", 24)
	_player_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_slide.add_child(_player_grid)
	_slide_status = Retro.label(52, Retro.GOOD)
	_slide.add_child(_slide_status)

	# question on a console plate: [video] question + text
	_q_panel = Retro.panel_container(Retro.PANEL, Retro.TEAL, 4, 28, 30)
	_q_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_q_panel)
	var q_row := HBoxContainer.new()
	q_row.add_theme_constant_override("separation", 30)
	_q_panel.add_child(q_row)
	_media = TextureRect.new()
	_media.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_media.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_media.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_media.visible = false
	q_row.add_child(_media)
	var q_texts := VBoxContainer.new()
	q_texts.alignment = BoxContainer.ALIGNMENT_CENTER
	q_texts.add_theme_constant_override("separation", 16)
	_text_area = _holder(q_texts)
	q_row.add_child(_text_area)
	_question = Retro.label(Q_SIZE, Retro.CREAM)
	_question.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	q_texts.add_child(_question)
	_body = Retro.label(BODY_SIZE, Retro.CREAM.darkened(0.15))
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	q_texts.add_child(_body)

	# answers in the same layout as the icons on the tile
	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid.size_flags_stretch_ratio = 0.62             # compact: the question gets the room
	_grid.add_theme_constant_override("h_separation", 16)
	_grid.add_theme_constant_override("v_separation", 14)
	box.add_child(_grid)
	for b in QuizRound.ANSWER_BUTTONS:
		var col: Color = CyberTile.BUTTON_COLORS[b]
		var card := PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 18)
		card.add_child(row)
		# solid coloured key with the icon, like the lit icon on the glass
		var key := Retro.panel_container(col, col.lightened(0.4), 3, 14, 6)
		key.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var icon := Retro.ButtonIcon.new()
		icon.button = b
		icon.glow = false
		icon.color = Retro.BG
		icon.custom_minimum_size = Vector2(84, 84)
		key.add_child(icon)
		row.add_child(key)
		var texts := VBoxContainer.new()
		texts.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_child(_holder(texts))
		var tag := Retro.label(22, col, Retro.BUTTON_NAMES[b], HORIZONTAL_ALIGNMENT_LEFT)
		texts.add_child(tag)
		var text := Retro.label(ANSWER_SIZE, Retro.CREAM, "", HORIZONTAL_ALIGNMENT_LEFT)
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		texts.add_child(text)
		_grid.add_child(card)
		_cards.append(card)
		_keys.append(key)
		_icons.append(icon)
		_answer_labels.append(text)
		_tags.append(tag)

	_bar = ProgressBar.new()
	_bar.max_value = 1.0
	_bar.show_percentage = false
	_bar.custom_minimum_size.y = 20
	_bar.add_theme_stylebox_override("background", Retro.panel(Retro.PANEL, Retro.DIM, 2, 6, 0))
	box.add_child(_bar)

	# bottom: status text, who answered already; the shield legend (players slide)
	_status = Retro.label(36, Retro.CREAM)
	box.add_child(_status)
	_answered = HFlowContainer.new()
	_answered.alignment = FlowContainer.ALIGNMENT_CENTER
	_answered.add_theme_constant_override("h_separation", 10)
	_answered.add_theme_constant_override("v_separation", 8)
	box.add_child(_answered)
	_legend = HBoxContainer.new()
	_legend.alignment = BoxContainer.ALIGNMENT_CENTER
	_legend.add_theme_constant_override("separation", 14)
	var shield := Retro.ShieldIcon.new()
	shield.custom_minimum_size = Vector2(40, 48)
	_legend.add_child(shield)
	_legend.add_child(Retro.label(36, Retro.SHIELD,
		"BESCHERMD: VRAAG BOVEN JE LEEFTIJD  ▸  FOUT KOST GEEN LEVEN"))
	_slide.add_child(_legend)


## state keys: number, total, phase (video / read / question / timeup /
## answers / reveal), question, answers (4 strings, in ANSWER_BUTTONS order),
## time_left, time_total, players: [{id, name, answer (-1 = none), dead,
## protected, streak, ok (reveal: right or not)}]. No right answer: never shown.
func show_question(state: Dictionary) -> void:
	var phase: String = state.phase
	if phase != _last_phase:                       # a new step: fade it in
		if phase == "question" and _last_phase == "read":
			for l in _answer_labels:                # same slide: only the answers fade in
				l.modulate.a = 0.0
				l.create_tween().tween_property(l, "modulate:a", 1.0, 0.5)
		else:
			_content.modulate.a = 0.0
			create_tween().tween_property(_content, "modulate:a", 1.0, 0.35)
		_last_phase = phase
	var watching := phase == "video"
	var slide := phase in ["timeup", "answers", "reveal"]
	var players: Array = state.players
	_header.text = "VRAAG %d/%d" % [state.number, state.total]
	var meta: Array = [state.category.to_upper(), state.ages].filter(func(t): return t != "")
	_meta.text = "  ▸  ".join(meta)
	_meta.visible = not meta.is_empty()

	_q_panel.visible = not slide
	_grid.visible = phase in ["read", "question"]
	_bar.visible = phase in ["read", "question"]
	_status.visible = phase in ["question", "video"]
	_answered.visible = phase == "question"
	_slide.visible = slide
	_countdown.visible = phase in ["question", "video"]
	if slide:
		_show_players_slide(phase, players)
		return

	# question slides: video / read / question
	_question.text = state.question
	_media.texture = state.get("media", state.video)
	_media.visible = _media.texture != null
	_media.size_flags_stretch_ratio = 3.0 if watching else 0.9
	_body.text = state.text
	_body.add_theme_color_override("font_color", Retro.CREAM.darkened(0.15))
	_body.visible = not watching and _body.text != ""
	var big := _media.visible or _body.visible
	_q_panel.size_flags_stretch_ratio = 1.15 if big else 1.0
	_fit(_text_area, [_question, _body], [Q_SIZE, BODY_SIZE] if not watching else [48, BODY_SIZE])
	var alive := players.filter(func(p): return not p.dead).size()
	var answered := players.filter(func(p): return not p.dead and p.answer >= 0).size()

	if watching:
		_bar.value = state.video_progress
		_countdown.seconds = -1
		_countdown.symbol = "▶"
		_countdown.fraction = 1.0 - state.video_progress
		_countdown.color = Retro.TEAL
		_status.text = "BEKIJK DE VIDEO  ▸  DAARNA KIES JE HET ANTWOORD"
		_status.add_theme_color_override("font_color", Retro.TEAL)
		return
	for i in 4:
		var b: StringName = QuizRound.ANSWER_BUTTONS[i]
		var col: Color = CyberTile.BUTTON_COLORS[b]
		_cards[i].add_theme_stylebox_override("panel", Retro.panel(col.darkened(0.82), col, 4, 18, 10))
		_answer_labels[i].text = state.answers[i] if phase == "question" else ""
		_tags[i].text = Retro.BUTTON_NAMES[b]
		_tags[i].add_theme_color_override("font_color", col)
	if phase == "read":                            # the buttons, no answers yet
		_bar.value = 1.0
		_countdown.visible = false
		_status.visible = true
		_status.text = "LEES DE VRAAG  ▸  ZO DADELIJK DE ANTWOORDEN"
		_status.add_theme_color_override("font_color", Retro.TEAL)
		return
	_countdown.symbol = "✔"
	_fit_answers()
	var frac := clampf(state.time_left / state.time_total, 0.0, 1.0)
	_bar.value = frac
	var fill := Retro.AMBER.lerp(Retro.BAD, clampf(1.6 - frac * 2.0, 0.0, 1.0))
	_bar.add_theme_stylebox_override("fill", Retro.panel(fill, Color.TRANSPARENT, 0, 6, 0))
	_countdown.seconds = ceili(maxf(state.time_left, 0.0))
	_countdown.fraction = frac
	_countdown.color = fill
	_status.text = "DRUK OP HET ICOON OP JE TEGEL  ▸  JE MAG WISSELEN TOT DE TIJD OM IS  ▸  %d/%d GEANTWOORD" % [answered, alive]
	_status.add_theme_color_override("font_color", Retro.CREAM)
	_update_answered(players)


## Small chips: who answered already (amber ✔) - never what they answered.
func _update_answered(players: Array) -> void:
	var shown := players.filter(func(p): return not p.dead)
	for id in _answered_chips.keys():
		if not shown.any(func(p): return p.id == id):
			_answered_chips[id].queue_free()
			_answered_chips.erase(id)
	for p in shown:
		if not _answered_chips.has(p.id):
			var chip := Retro.label(28, Retro.CREAM)
			_answered.add_child(chip)
			_answered_chips[p.id] = chip
		var chip: Label = _answered_chips[p.id]
		var done: bool = p.answer >= 0
		chip.text = "%s %s" % [p.name.to_upper().left(10), "✔" if done else "…"]
		chip.add_theme_color_override("font_color", Retro.BG if done else Retro.DIM)
		chip.add_theme_stylebox_override("normal", Retro.panel(Retro.AMBER if done else Retro.PANEL,
			Retro.CREAM if done else Retro.DIM, 2, 8, 12))


## Players slide: "TIJD OM!", then every player's icon, then who was right.
func _show_players_slide(phase: String, players: Array) -> void:
	_slide_title.text = {"timeup": "TIJD OM!", "answers": "DE ANTWOORDEN",
		"reveal": "WIE HAD HET GOED?"}[phase]
	_slide_title.add_theme_font_size_override("font_size", 150 if phase == "timeup" else 96)
	_player_grid.visible = phase != "timeup"
	_slide_status.visible = phase == "reveal"
	_legend.visible = phase == "reveal" and players.any(func(p): return p.protected and not p.dead and p.ok == false)
	var shown := players.filter(func(p): return not p.dead)
	_player_grid.columns = clampi(shown.size(), 1, 5 if shown.size() > 8 else 4)
	for id in _player_cards.keys():
		if not shown.any(func(p): return p.id == id):
			_player_cards[id].panel.queue_free()
			_player_cards.erase(id)
	for p in shown:
		if not _player_cards.has(p.id):
			_player_cards[p.id] = _new_player_card()
		var c: Dictionary = _player_cards[p.id]
		c.name.text = "%02d %s" % [p.id, p.name.to_upper().left(10)]
		var answered: bool = p.answer >= 0
		var col: Color = CyberTile.BUTTON_COLORS[QuizRound.ANSWER_BUTTONS[p.answer]] if answered else Retro.DIM
		c.icon.visible = answered
		if answered:
			c.icon.button = QuizRound.ANSWER_BUTTONS[p.answer]
			c.icon.color = col
			c.icon.queue_redraw()
		var fill := col.darkened(0.7)
		var border := col
		var mark := "" if answered else "GEEN"
		c.shield.visible = false
		if phase == "reveal":
			if p.ok == true:
				fill = Retro.GOOD.darkened(0.6)
				border = Retro.GOOD
				mark = "✔"
			elif p.protected:
				fill = Retro.SHIELD.darkened(0.6)
				border = Retro.SHIELD
				mark = "♥"
				c.shield.visible = true
			else:
				fill = Retro.BAD.darkened(0.6)
				border = Retro.BAD
				mark = "✘"
		c.panel.add_theme_stylebox_override("panel", Retro.panel(fill, border, 5, 20, 22))
		c.mark.text = mark
		c.mark.add_theme_color_override("font_color", border if phase == "reveal" else Retro.DIM)
	if phase == "reveal":
		var right := shown.filter(func(p): return p.ok == true).size()
		_slide_status.text = "%d VAN %d SPELERS HADDEN HET GOED" % [right, shown.size()]


func _new_player_card() -> Dictionary:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(330, 0)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	var name_label := Retro.label(40, Retro.CREAM)
	box.add_child(name_label)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 18)
	box.add_child(row)
	var icon := Retro.ButtonIcon.new()
	icon.custom_minimum_size = Vector2(110, 110)
	row.add_child(icon)
	var shield := Retro.ShieldIcon.new()
	shield.custom_minimum_size = Vector2(60, 72)
	shield.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(shield)
	var mark := Retro.label(80, Retro.CREAM)
	row.add_child(mark)
	_player_grid.add_child(panel)
	return {"panel": panel, "name": name_label, "icon": icon, "mark": mark, "shield": shield}


## A plain Control around a container: the text inside can't push the layout
## (wrapped labels report their full height as minimum size); _fit shrinks it.
func _holder(content: Control) -> Control:
	var holder := Control.new()
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.clip_contents = true
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(content)
	return holder


## Scale the font sizes of labels (stacked vertically in area) down together
## until they fit. Only recomputed when the text or the area changes.
func _fit(area: Control, labels: Array, sizes: Array) -> void:
	var key := str(area.size)
	for l in labels:
		key += "|%s%s" % [l.visible, l.text]
	if _fit_keys.get(area) == key or area.size.x <= 0:
		return
	_fit_keys[area] = key
	var k := _fit_scale(area.size, labels, sizes)
	for i in labels.size():
		labels[i].add_theme_font_size_override("font_size", int(sizes[i] * k))


## The 4 answers share one font size (the one that fits the longest answer);
## the button names above them keep their size.
func _fit_answers() -> void:
	var area := _answer_labels[0].get_parent().get_parent() as Control
	var key := str(area.size)
	for l in _answer_labels:
		key += "|" + l.text
	if _fit_keys.get(_grid) == key or area.size.x <= 0:
		return
	_fit_keys[_grid] = key
	var k := 1.0
	for l in _answer_labels:
		k = minf(k, _fit_scale(area.size - Vector2(0, 34), [l], [ANSWER_SIZE]))
	for l in _answer_labels:
		l.add_theme_font_size_override("font_size", int(ANSWER_SIZE * k))


func _fit_scale(room: Vector2, labels: Array, sizes: Array) -> float:
	var k := 1.0
	while k > 0.35:
		var h := 0.0
		for i in labels.size():
			var l: Label = labels[i]
			if l.visible and l.text != "":
				h += Retro.FONT.get_multiline_string_size(l.text, l.horizontal_alignment,
					room.x, int(sizes[i] * k)).y + 16
		if h <= room.y:
			break
		k -= 0.05
	return k


## Round countdown: segmented ring (like an old dial) with the seconds left.
class CountdownRing:
	extends Control

	const SEGMENTS := 24
	var seconds := -1
	var symbol := "✔"                # shown instead of the seconds when seconds < 0
	var fraction := 1.0
	var color := Color.WHITE

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var c := size / 2
		var r := minf(size.x, size.y) * 0.42
		draw_circle(c, r + 12, Retro.PANEL)
		draw_arc(c, r + 12, 0, TAU, 32, Retro.DIM, 3, true)
		var lit := ceili(fraction * SEGMENTS)
		for k in SEGMENTS:
			var a0 := -PI / 2 + TAU * k / SEGMENTS
			var a1 := a0 + TAU / SEGMENTS * 0.7
			draw_arc(c, r - 4, a0, a1, 4, color if k < lit else Color(1, 1, 1, 0.08), 14, true)
		var text := str(seconds) if seconds >= 0 else symbol
		var fs := int(r * 0.95)
		var w := Retro.FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(Retro.FONT, c + Vector2(-w / 2, fs * 0.36), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Retro.CREAM)
