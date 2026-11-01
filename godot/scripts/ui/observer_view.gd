class_name ObserverView
extends Control
## The overview page for visitors (its own full-screen display): the floating
## observer camera with
##   top:          what is happening (round / state) + timer, a rotating
##                 call to action ("VERSLA DE DALEK!")
##   bottom-left:  how the current game works (the round's rules), every
##                 `page_time` seconds alternating with the overall ranking
##                 (top 10 by most rounds survived in one play)
##   right:        live player list (score, lives, overall rank, invites) and
##                 an event feed
## After every round the scoreboard (the same as on the player screens) takes
## the page (under the status bar) until the next round starts.

const LOBBY_RULES := "1. Haal een QR-codekaart.\n2. Registreer je met je gsm.\n3. Ga naar een gamemaster: die laat je toe tot het spel.\n4. Zoek de tegel in jouw kleur en druk op de 4 iconen.\n5. Blijf zo lang mogelijk in het spel!"
const MAX_EVENTS := 9
const TOP := 10
const MARGIN := 40               # px around the page
const BODY_TOP := 164            # under the status bar and the timer
const GAP := 24
const RIGHT_WIDTH := 760         # players + events column

var page_time := 10.0             # s per page in the bottom-left panel (rules / ranking)

var wall: ScreenWall
var _status: Label
var _timer: Label
var _list: VBoxContainer
var _list_panel: Control
var _list_scale := 1.0           # font scale of the player rows (smaller with more than 13)
var _rules_title: Label
var _rules: Label
var _events: VBoxContainer
var _under: Array[Control] = []   # panels hidden while the scoreboard shows
var _board: Control              # the UITSLAG (RankingView) or the ScoreboardView
var _refresh := 0.0
var _page_t := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var cell := wall.make_observer_cell()
	cell.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(cell)
	# top-left: what is happening
	var head := Retro.panel_container(Color(Retro.PANEL, 0.88), Retro.ORANGE, 4, 18, 26)
	head.position = Vector2(40, 36)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 22)
	head.add_child(hb)
	var logo := Retro.label(40, Retro.BG, "CYBER CIRCLE")
	logo.add_theme_stylebox_override("normal", Retro.panel(Retro.TEAL, Retro.TEAL, 0, 8, 14))
	hb.add_child(logo)
	_status = Retro.label(44, Retro.CREAM)
	hb.add_child(_status)
	add_child(head)
	# top-right: timer
	_timer = Retro.label(52, Retro.AMBER)              # (as tall as the status bar: above BODY_TOP)
	_timer.add_theme_stylebox_override("normal", Retro.panel(Color(Retro.PANEL, 0.95), Retro.ORANGE, 4, 16, 20))
	_timer.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_timer.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_timer.offset_right = -MARGIN
	_timer.offset_top = 36
	add_child(_timer)
	# under the status bar two columns that can't overlap: left the call to
	# action and the rules, right (fixed width) the players and the events
	var body := HBoxContainer.new()
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	body.offset_left = MARGIN
	body.offset_right = -MARGIN
	body.offset_top = BODY_TOP
	body.offset_bottom = -MARGIN
	body.add_theme_constant_override("separation", GAP)
	add_child(body)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", GAP)
	body.add_child(left)
	var cta_box := _holder(180)                    # (a wrapping label can't push the layout)
	var cta := CallToAction.new(64)
	cta.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cta.set_anchors_preset(Control.PRESET_FULL_RECT)
	cta_box.add_child(cta)
	left.add_child(cta_box)
	_under.append(cta_box)
	var spacer := Control.new()                    # the camera shows through here
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.add_child(spacer)
	# bottom-left: how the current game works
	var rules := Retro.panel_container(Color(Retro.PANEL, 0.85), Retro.ORANGE, 3, 16, 24)
	var rb := VBoxContainer.new()
	rules.add_child(rb)
	_rules_title = Retro.label(36, Retro.TEAL, "", HORIZONTAL_ALIGNMENT_LEFT)
	rb.add_child(_rules_title)
	_rules = Retro.label(28, Retro.CREAM, "", HORIZONTAL_ALIGNMENT_LEFT)
	_rules.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rb.add_child(_rules)
	left.add_child(rules)
	_under.append(rules)
	# right: players, and the event feed under it (takes the rest, clipped)
	var col := VBoxContainer.new()
	col.custom_minimum_size.x = RIGHT_WIDTH         # every row clips: the column never gets wider
	col.add_theme_constant_override("separation", 16)
	body.add_child(col)
	_under.append(col)
	var panel := Retro.panel_container(Color(Retro.PANEL, 0.82), Retro.ORANGE, 3, 16, 20)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 2)
	panel.add_child(_list)
	col.add_child(panel)
	_list_panel = panel
	var feed := Retro.panel_container(Color(Retro.PANEL, 0.82), Retro.ORANGE, 3, 16, 20)
	feed.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var feed_box := _holder(0)                     # the rest of the column; older events cut off
	feed.add_child(feed_box)
	var fb := VBoxContainer.new()
	fb.set_anchors_preset(Control.PRESET_FULL_RECT)
	feed_box.add_child(fb)
	fb.add_child(Retro.label(30, Retro.TEAL, "GEBEURTENISSEN", HORIZONTAL_ALIGNMENT_LEFT))
	_events = VBoxContainer.new()
	_events.add_theme_constant_override("separation", 2)
	fb.add_child(_events)
	col.add_child(feed)
	wall.arena.game.game_event.connect(_on_event)
	wall.arena.game.scores_shown.connect(_show_board)
	wall.arena.game.ranking_shown.connect(_show_ranking)
	wall.arena.exterminated.connect(_exterminated_popup)
	_update()


## A plain clipping Control of a fixed height (0: whatever its container
## gives): what's inside can't make it bigger.
func _holder(height: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = height
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL if height == 0 else Control.SIZE_FILL
	c.clip_contents = true
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


## Over the floating camera: who was just exterminated (several stack up).
func _exterminated_popup(_tile_id: int, player: String) -> void:
	var l := Retro.label(76, Retro.CREAM, "☠  %s GEËXTERMINEERD  ☠" % player.to_upper())
	l.add_theme_stylebox_override("normal", Retro.panel(Color(0.35, 0.0, 0.0, 0.92), Retro.BAD, 6, 16, 34))
	l.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	l.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var shown := get_children().filter(func(c): return c.has_meta(&"doom_popup")).size()
	l.offset_top = 340 + shown * 130
	l.set_meta(&"doom_popup", true)
	add_child(l)
	l.pivot_offset = Vector2(500, 50)
	l.scale = Vector2(1.5, 1.5)
	var tw := l.create_tween()
	tw.tween_property(l, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(3.5)
	tw.tween_property(l, "modulate:a", 0.0, 0.8)
	tw.tween_callback(l.queue_free)


## The round's scoreboard, over the rules, players and events.
func _show_board(title: String, subtitle: String, rows: Array) -> void:
	var board := ScoreboardView.new()
	_place_board(board)
	board.show_scores(title, subtitle, rows, false)
	wall.arena.game.lives_revealed.connect(board.reveal_lives)


## The round's places (UITSLAG) before it, in the same place.
func _show_ranking(title: String, label: String, rows: Array) -> void:
	var board := RankingView.new()
	_place_board(board)
	board.show_ranking(title, label, rows)


func _place_board(board: Control) -> void:
	_hide_board()
	_board = board
	_board.offset_left = MARGIN
	_board.offset_right = -MARGIN
	_board.offset_top = BODY_TOP
	_board.offset_bottom = -MARGIN
	add_child(_board)
	for c in _under:
		c.visible = false


func _hide_board() -> void:
	if _board:
		_board.queue_free()
		_board = null
	for c in _under:
		c.visible = true


func _process(delta: float) -> void:
	_page_t += delta
	_refresh -= delta
	if _refresh <= 0.0:
		_refresh = 0.25
		_update()


func _update() -> void:
	var arena := wall.arena
	var game: GameManager = arena.game
	if game.mode != GameManager.Mode.OPEN:
		_status.text = {GameManager.Mode.SETUP: "SETUP", GameManager.Mode.CLOSED: "GESLOTEN",
			GameManager.Mode.PAUSED: "PAUZE"}[game.mode]
	else: match game.state:
		GameManager.State.LOBBY:
			_status.text = "WACHT OP SPELERS" if arena.player_ids().is_empty() else "SPEL START ZO"
		GameManager.State.INTRO, GameManager.State.PLAYING:
			_status.text = game.current.title.to_upper()
		GameManager.State.SCOREBOARD:
			_status.text = "UITSLAG" if _board is RankingView else "SCOREBORD"
	if _board and (game.state != GameManager.State.SCOREBOARD or game.mode != GameManager.Mode.OPEN):
		_hide_board()
	if _board:                     # an extermination: the board steps aside for the robot
		_board.visible = arena.dying.is_empty()
	var ranking := game.overall_ranking()
	if int(_page_t / page_time) % 2 == 1 and not ranking.is_empty():
		_rules_title.text = "RANGLIJST - MEESTE RONDES OVERLEEFD"
		var lines := PackedStringArray()
		for i in mini(ranking.size(), TOP):
			var r: Dictionary = ranking[i]
			lines.append("%2d  %-12s %6d" % [i + 1, str(r.name).to_upper().left(12), r.best])
		_rules.text = "\n".join(lines)
	elif game.state in [GameManager.State.INTRO, GameManager.State.PLAYING] and game.current:
		_rules_title.text = "HOE SPEEL JE: " + game.current.title.to_upper()
		_rules.text = game.current.rules
	else:
		_rules_title.text = "HOE DOE JE MEE?"
		_rules.text = LOBBY_RULES
	_timer.text = wall.timer_text()
	_timer.visible = _timer.text != ""
	for c in _list.get_children():
		c.queue_free()
	var ids: Array = arena.player_ids()
	var count := ids.size() + range(1, arena.tiles.size() + 1).filter(func(id): return not arena.pending_info(id).is_empty()).size()
	_list_scale = clampf(13.0 / maxf(count, 13.0), 0.55, 1.0)   # more than 13 (mobile tiles): smaller rows
	ids.sort_custom(func(a, b): return game.survived.get(a, 0) > game.survived.get(b, 0))
	for i in ids.size():
		var id: int = ids[i]
		var tile: CyberTile = arena.tiles[id - 1]
		var col := Retro.AMBER if i == 0 and game.survived.get(id, 0) > 0 else Retro.CREAM
		if tile.is_dead:
			col = Retro.DIM
		var place := game.overall_rank(id)
		_row(Retro.tile_label(id), arena.player_name(id).to_upper().left(10),
			"♥".repeat(maxi(tile.health, 0)), Retro.rounds(game.survived.get(id, 0)), col, "#%d" % place if place > 0 else "")
	var rows := ids.size()
	for id in range(1, arena.tiles.size() + 1):
		var invite: Dictionary = arena.pending_info(id)
		if not invite.is_empty():
			rows += 1
			_row(Retro.tile_label(id), str(invite.name).to_upper().left(10), "", "ACTIVEREN", invite.color)
	_list_panel.visible = rows > 0                 # nobody yet: no list (the old rows are still freeing)


func _row(tile: String, name: String, hearts: String, score: String, col: Color, rank := "") -> void:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 14)
	# fixed widths (the name takes the rest), long text is cut off
	var cells := [[tile, 34, Retro.TEAL, 80], [name, 34, col, 0], [hearts, 30, Color(1, 0.2, 0.3), 110],
		[score, 34, col, 190], [rank, 30, Retro.TEAL, 70]]
	for c in cells:
		var l := Retro.label(int(c[1] * _list_scale), c[2], c[0], HORIZONTAL_ALIGNMENT_LEFT)
		l.custom_minimum_size.x = c[3]
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		if c[3] == 0:
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r.add_child(l)
	_list.add_child(r)


## Newest event on top; older ones fade out.
func _on_event(text: String, color: Color) -> void:
	var l := Retro.label(28, color, text, HORIZONTAL_ALIGNMENT_LEFT)
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.clip_text = true
	_events.add_child(l)
	_events.move_child(l, 0)
	while _events.get_child_count() > MAX_EVENTS:
		_events.get_child(_events.get_child_count() - 1).free()
	for i in _events.get_child_count():
		_events.get_child(i).modulate.a = 1.0 - 0.08 * i
