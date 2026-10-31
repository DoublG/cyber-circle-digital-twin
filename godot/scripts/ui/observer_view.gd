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

var page_time := 10.0             # s per page in the bottom-left panel (rules / ranking)

var wall: ScreenWall
var _status: Label
var _timer: Label
var _list: VBoxContainer
var _rules_title: Label
var _rules: Label
var _events: VBoxContainer
var _under: Array[Control] = []   # panels hidden while the scoreboard shows
var _board: ScoreboardView
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
	# big rotating call to action across the top (left of the player list)
	var cta := CallToAction.new(64)
	cta.position = Vector2(40, 150)
	cta.size = Vector2(1100, 180)
	add_child(cta)
	_under.append(cta)
	# top-right: timer
	_timer = Retro.label(64, Retro.AMBER)
	_timer.add_theme_stylebox_override("normal", Retro.panel(Color(Retro.PANEL, 0.95), Retro.ORANGE, 4, 16, 26))
	_timer.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_timer.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_timer.offset_right = -40
	_timer.offset_top = 36
	add_child(_timer)
	# bottom-left: how the current game works
	var rules := Retro.panel_container(Color(Retro.PANEL, 0.85), Retro.ORANGE, 3, 16, 24)
	rules.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	rules.grow_vertical = Control.GROW_DIRECTION_BEGIN
	rules.offset_left = 40
	rules.offset_bottom = -40
	rules.custom_minimum_size.x = 980
	var rb := VBoxContainer.new()
	rules.add_child(rb)
	_rules_title = Retro.label(36, Retro.TEAL, "", HORIZONTAL_ALIGNMENT_LEFT)
	rb.add_child(_rules_title)
	_rules = Retro.label(28, Retro.CREAM, "", HORIZONTAL_ALIGNMENT_LEFT)
	_rules.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rules.custom_minimum_size.x = 930
	rb.add_child(_rules)
	add_child(rules)
	_under.append(rules)
	# right: players, and the event feed under it
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	col.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	col.offset_right = -40
	col.offset_top = 160
	col.offset_bottom = -40
	col.add_theme_constant_override("separation", 16)
	add_child(col)
	_under.append(col)
	var panel := Retro.panel_container(Color(Retro.PANEL, 0.82), Retro.ORANGE, 3, 16, 20)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 4)
	panel.add_child(_list)
	col.add_child(panel)
	var feed := Retro.panel_container(Color(Retro.PANEL, 0.82), Retro.ORANGE, 3, 16, 20)
	var fb := VBoxContainer.new()
	fb.clip_contents = true
	feed.add_child(fb)
	fb.add_child(Retro.label(30, Retro.TEAL, "GEBEURTENISSEN", HORIZONTAL_ALIGNMENT_LEFT))
	_events = VBoxContainer.new()
	_events.add_theme_constant_override("separation", 2)
	fb.add_child(_events)
	col.add_child(feed)
	wall.arena.game.game_event.connect(_on_event)
	wall.arena.game.scores_shown.connect(_show_board)
	wall.arena.exterminated.connect(_exterminated_popup)
	_update()


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
	_hide_board()
	_board = ScoreboardView.new()
	_board.offset_left = 40
	_board.offset_right = -40
	_board.offset_top = 150
	_board.offset_bottom = -40
	add_child(_board)
	_board.show_scores(title, subtitle, rows, false)
	wall.arena.game.lives_revealed.connect(_board.reveal_lives)
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
			_status.text = "SCOREBORD"
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
	ids.sort_custom(func(a, b): return game.survived.get(a, 0) > game.survived.get(b, 0))
	for i in ids.size():
		var id: int = ids[i]
		var tile: CyberTile = arena.tiles[id - 1]
		var col := Retro.AMBER if i == 0 and game.survived.get(id, 0) > 0 else Retro.CREAM
		if tile.is_dead:
			col = Retro.DIM
		var place := game.overall_rank(id)
		_row("T%02d" % id, arena.player_name(id).to_upper().left(10),
			"♥".repeat(maxi(tile.health, 0)), Retro.rounds(game.survived.get(id, 0)), col, "#%d" % place if place > 0 else "")
	for id in range(1, arena.tiles.size() + 1):
		var invite: Dictionary = arena.pending_info(id)
		if not invite.is_empty():
			_row("T%02d" % id, str(invite.name).to_upper().left(10), "", "ACTIVEREN", invite.color)
	if _list.get_child_count() == 0:
		_row("", "NOG GEEN SPELERS", "", "", Retro.DIM)


func _row(tile: String, name: String, hearts: String, score: String, col: Color, rank := "") -> void:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 14)
	var cells := [[tile, 34, Retro.TEAL, 80], [name, 34, col, 230], [hearts, 30, Color(1, 0.2, 0.3), 120],
		[score, 34, col, 140], [rank, 30, Retro.TEAL, 70]]
	for c in cells:
		var l := Retro.label(c[1], c[2], c[0], HORIZONTAL_ALIGNMENT_LEFT)
		l.custom_minimum_size.x = c[3]
		r.add_child(l)
	_list.add_child(r)


## Newest event on top; older ones fade out.
func _on_event(text: String, color: Color) -> void:
	var l := Retro.label(28, color, text, HORIZONTAL_ALIGNMENT_LEFT)
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.custom_minimum_size.x = 620
	_events.add_child(l)
	_events.move_child(l, 0)
	while _events.get_child_count() > MAX_EVENTS:
		_events.get_child(_events.get_child_count() - 1).free()
	for i in _events.get_child_count():
		_events.get_child(i).modulate.a = 1.0 - 0.08 * i
