class_name QuizView
extends Control
## Shared quiz screen, a slide show - one step at a time, with a fade between:
##   read      the question + the 4 buttons (icon and colour), no answers yet
##   question  the answers fade in, the countdown runs; small indicators of
##             who answered (not what)
##   timeup    "TIJD OM!"
##   answers   every player's chosen icon (big player cards) ...
##   reveal    ... then on the same slide, card by card, shown by the card's
##             frame (no ✔ / ✘): right = thick glowing green border; wrong =
##             thin red border, dimmed, it shakes; shielded = blue - the right
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

const SCENE := "res://scenes/ui/quiz_view.tscn"
const Q_SIZE := 62               # question (shrinks to fit)
const BODY_SIZE := 38            # longer text under it
const ANSWER_SIZE := 44

var _fit_keys := {}              # Control -> last fitted text + size
var _answer_labels: Array[Label] = []
var _player_cards := {}          # tile_id -> QuizPlayerCard
var _shown_ok := {}              # tile_id -> true: the card shows right / wrong (reveal animation)
var _answered_chips := {}        # tile_id -> Label
var _last_phase := ""

@onready var _content: VBoxContainer = %Content      # everything below the background (faded between steps)
@onready var _meta: Label = %Meta                    # category + age range
@onready var _countdown: CountdownRing = %Countdown
@onready var _slide: VBoxContainer = %Slide          # players slide: timeup / answers / reveal
@onready var _slide_title: Label = %SlideTitle
@onready var _grid_room: Control = %GridRoom         # the cards scale down to fit it (any number of players)
@onready var _player_grid: GridContainer = %PlayerGrid
@onready var _slide_status: Label = %SlideStatus
@onready var _legend: HBoxContainer = %Legend        # "shield = protected" explanation
@onready var _q_panel: PanelContainer = %QuestionPanel
@onready var _media: TextureRect = %Media
@onready var _text_area: Control = %TextArea
@onready var _question: Label = %Question
@onready var _body: Label = %Body                    # longer question text
@onready var _grid: GridContainer = %Answers         # the 4 QuizAnswerCards
@onready var _bar: ProgressBar = %TimeBar
@onready var _status: Label = %Status
@onready var _answered: HFlowContainer = %Answered   # question step: who answered already (not what)


static func create() -> QuizView:
	return load(SCENE).instantiate()


func _ready() -> void:
	for card: QuizAnswerCard in _grid.get_children():
		_answer_labels.append(card.answer)
	_grid_room.resized.connect(_fit_grid)
	_player_grid.minimum_size_changed.connect(_fit_grid)


## state keys: phase (video / read / question / timeup /
## answers / reveal), question, answers (4 strings, in ANSWER_BUTTONS order),
## time_left, time_total, players: [{id, name, answer (-1 = none), dead,
## protected, streak, ok (reveal: right or not)}]. No right answer: never shown.
func show_question(state: Dictionary) -> void:
	var phase: String = state.phase
	if phase != _last_phase:                       # a new step: fade it in
		if phase == "reveal" and _last_phase == "answers":
			_reveal_cards(state.players)            # same slide: card by card right / wrong
		elif phase == "question" and _last_phase == "read":
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
	var meta: Array = [state.category.to_upper(), state.ages].filter(func(t): return t != "")
	_meta.text = "  ▸  ".join(meta)
	_meta.visible = not meta.is_empty()

	_q_panel.visible = not slide
	_grid.visible = phase in ["read", "question"]
	_bar.visible = phase in ["read", "question"]
	_status.visible = phase in ["read", "question", "video"]
	_answered.visible = phase in ["read", "question"]    # read and question: the same layout,
	_slide.visible = slide                                # nothing moves when the answers come in
	_countdown.visible = not slide
	_countdown.modulate.a = 0.0 if phase == "read" else 1.0
	if slide:
		_show_players_slide(phase, players)
		return

	# question slides: video / read / question
	_question.text = state.question
	_media.texture = state.get("media", state.video)
	_media.visible = _media.texture != null
	_media.size_flags_stretch_ratio = 3.0 if watching else 0.9
	_body.text = state.text
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
		_answer_labels[i].text = state.answers[i] if phase == "question" else ""
	if phase == "read":                            # the buttons, no answers yet
		_bar.value = 1.0
		_update_answered(players)
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
	_status.text = "DRUK OP JE TEGEL  ▸  WISSELEN MAG TOT DE TIJD OM IS  ▸  %d/%d GEANTWOORD" % [answered, alive]
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
			var chip := Retro.label(28 if shown.size() <= 13 else 22, Retro.CREAM)
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
	_grid_room.visible = phase != "timeup"
	# the result line and the shield legend keep their room from the answers on
	# (only faded in): the cards never move when they appear
	_slide_status.visible = phase != "timeup"
	_legend.visible = phase != "timeup" and players.any(func(p): return p.protected and not p.dead)
	_legend.modulate.a = 1.0 if phase == "reveal" and players.any(
		func(p): return p.protected and not p.dead and p.ok == false) else 0.0
	var shown := players.filter(func(p): return not p.dead)
	_player_grid.columns = _columns(shown.size())
	var many := shown.size() > 10                  # (3 rows of cards: tighter, the legend stays on screen)
	_slide.add_theme_constant_override("separation", 20 if many else 36)
	if phase != "timeup":
		_slide_title.add_theme_font_size_override("font_size", 80 if many else 96)
	for id in _player_cards.keys():
		if not shown.any(func(p): return p.id == id):
			_player_cards[id].queue_free()
			_player_cards.erase(id)
	for p in shown:
		if not _player_cards.has(p.id):
			_player_cards[p.id] = QuizPlayerCard.create()
			_player_grid.add_child(_player_cards[p.id])
		var card: QuizPlayerCard = _player_cards[p.id]
		card.show_player(p, phase == "reveal" and _shown_ok.has(p.id))
	_slide_status.modulate.a = 1.0 if phase == "reveal" and _shown_ok.size() >= shown.size() else 0.0
	var right := shown.filter(func(p): return p.ok == true).size()
	_slide_status.text = "%d VAN %d SPELERS HADDEN HET GOED" % [right, shown.size()]


## The reveal, one card after the other: the card pops into its result (right:
## a thick glowing border; wrong: dimmed, thin red, it shakes; shielded: blue).
func _reveal_cards(players: Array) -> void:
	_shown_ok.clear()
	var shown := players.filter(func(p): return not p.dead)
	var step := minf(0.3, 2.4 / maxf(shown.size(), 1.0))  # (13 players: all within 2.4 s)
	var k := 0
	for p in shown:
		var panel: QuizPlayerCard = _player_cards.get(p.id)
		if panel == null:
			continue
		var id: int = p.id
		var right: bool = p.ok == true
		var tw := panel.create_tween()
		tw.tween_interval(0.35 + step * k)
		tw.tween_callback(func():
			_shown_ok[id] = true
			panel.pivot_offset = panel.size / 2.0)
		tw.tween_property(panel, "scale", Vector2(1.12, 1.12), 0.12)
		tw.tween_property(panel, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK)
		if not right:
			for dx in [-14.0, 14.0, -9.0, 9.0, 0.0]:   # (the shake: rotation, containers own the position)
				tw.tween_property(panel, "rotation", deg_to_rad(dx * 0.25), 0.05)
		k += 1


## Columns for n cards: up to 4 in one row, then about twice as wide as tall
## (13: 5 x 3, 20: 5 x 4, 24: 6 x 4, 30: 8 x 4).
static func _columns(n: int) -> int:
	if n <= 8:
		return clampi(n, 1, 4)
	var rows := ceili(sqrt(n / 2.0))
	return ceili(float(n) / rows)


## The cards in their room: as big as they are, scaled down (as a whole) when
## there are too many, centred.
func _fit_grid() -> void:
	var need := _player_grid.get_combined_minimum_size()
	if need.x <= 0.0 or need.y <= 0.0:
		return
	var k := minf(1.0, minf(_grid_room.size.x / need.x, _grid_room.size.y / need.y))
	_player_grid.scale = Vector2(k, k)
	_player_grid.size = need
	_player_grid.position = ((_grid_room.size - need * k) / 2.0).floor()


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
