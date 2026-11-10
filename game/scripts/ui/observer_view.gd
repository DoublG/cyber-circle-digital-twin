class_name ObserverView
extends Control
## The overview page for visitors (its own full-screen display): the floating
## observer camera, the status bar (what is happening + timer) always on top,
## and under it a loop for the people watching, scene after scene:
##   scores   a rotating call to action ("VERSLA DE ROBOT!"), the overall
##            ranking (top 10 by most rounds survived in one play) bottom-left,
##            the live player list and the event feed right
##   games    every game explained, one after the other (title and rules) -
##            the one being played now first ("NU BEZIG")
##   join     how to join, big
##   robot    nothing over the camera: it circles close around the robot
## An extermination interrupts: everything steps aside (the camera drifts over
## to watch, a GEËXTERMINEERD popup). After every round the UITSLAG and the
## scoreboard (the same as on the player screens) take the page.

const MAX_EVENTS := 9
const TOP := 10
const MARGIN := 40               # px around the page
const BODY_TOP := 164            # under the status bar and the timer
const GAP := 24
const RIGHT_WIDTH := 760         # players + events column

## The loop: [scene, seconds] ("games": seconds per game).
var scenes := [["scores", 14.0], ["games", 8.0], ["join", 12.0], ["robot", 14.0]]

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
var _scene := 0                  # index in `scenes`
var _scene_left := 0.0           # s until the next scene (or the next game)
var _game := 0                   # games scene: which game now
var _games: Array = []           # [{title, rules}] of every round type
var _center: PanelContainer      # games / join: the big panel in the middle
var _center_title: Label
var _center_sub: Label
var _center_body: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var cell := wall.make_observer_cell()
	cell.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(cell)
	add_child(_build_status_bar())
	add_child(_build_timer())
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
	body.add_child(_build_left_column())
	body.add_child(_build_right_column())
	add_child(_build_center_panel())
	_load_games()
	_scene_left = scenes[0][1]
	wall.arena.game.game_event.connect(_on_event)
	wall.arena.game.scores_shown.connect(_show_board)
	wall.arena.game.ranking_shown.connect(_show_ranking)
	wall.arena.exterminated.connect(_exterminated_popup)
	_update()


## Top-left: what is happening.
func _build_status_bar() -> Control:
	var head := Retro.panel_container(Color(Retro.PANEL, 0.88), Retro.ORANGE, 4, 18, 26)
	head.position = Vector2(40, 36)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 22)
	head.add_child(hb)
	var logo := Retro.label(40, Retro.BG, "CYBER CIRCLE CHALLENGE")
	logo.add_theme_stylebox_override("normal", Retro.panel(Retro.TEAL, Retro.TEAL, 0, 8, 14))
	hb.add_child(logo)
	_status = Retro.label(44, Retro.CREAM)
	hb.add_child(_status)
	return head


## Top-right: the timer.
func _build_timer() -> Control:
	_timer = Retro.label(52, Retro.AMBER)              # (as tall as the status bar: above BODY_TOP)
	_timer.add_theme_stylebox_override("normal", Retro.panel(Color(Retro.PANEL, 0.95), Retro.ORANGE, 4, 16, 20))
	_timer.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_timer.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_timer.offset_right = -MARGIN
	_timer.offset_top = 36
	return _timer


## Left: the call to action, room for the camera, and the rules at the bottom.
func _build_left_column() -> Control:
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", GAP)
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
	var rules := _build_rules()
	left.add_child(rules)
	_under.append(rules)
	return left


## Bottom-left: how the current game works.
func _build_rules() -> Control:
	var rules := Retro.panel_container(Color(Retro.PANEL, 0.85), Retro.ORANGE, 3, 16, 24)
	var rb := VBoxContainer.new()
	rules.add_child(rb)
	_rules_title = Retro.label(36, Retro.TEAL, "", HORIZONTAL_ALIGNMENT_LEFT)
	rb.add_child(_rules_title)
	_rules = Retro.label(28, Retro.CREAM, "", HORIZONTAL_ALIGNMENT_LEFT)
	_rules.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rb.add_child(_rules)
	return rules


## Right: players, and the event feed under it (takes the rest, clipped).
func _build_right_column() -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size.x = RIGHT_WIDTH         # every row clips: the column never gets wider
	col.add_theme_constant_override("separation", 16)
	var panel := Retro.panel_container(Color(Retro.PANEL, 0.82), Retro.ORANGE, 3, 16, 20)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 2)
	panel.add_child(_list)
	col.add_child(panel)
	_list_panel = panel
	col.add_child(_build_event_feed())
	_under.append(col)
	return col


## The event feed: the newest events, older ones cut off.
func _build_event_feed() -> Control:
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
	return feed


## Middle: the games explained / how to join (the loop's big panel).
func _build_center_panel() -> Control:
	_center = Retro.panel_container(Color(Retro.PANEL, 0.92), Retro.ORANGE, 5, 20, 40)
	_center.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_center.custom_minimum_size = Vector2(1300, 0)
	_center.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_center.grow_vertical = Control.GROW_DIRECTION_BOTH
	_center.offset_top = 60                         # (under the status bar)
	var cb := VBoxContainer.new()
	cb.add_theme_constant_override("separation", 14)
	_center.add_child(cb)
	_center_sub = Retro.label(34, Retro.TEAL)
	cb.add_child(_center_sub)
	_center_title = Retro.label(80, Retro.AMBER)
	cb.add_child(_center_title)
	_center_body = Retro.label(38, Retro.CREAM, "", HORIZONTAL_ALIGNMENT_LEFT)
	_center_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_center_body.custom_minimum_size.x = 1200
	cb.add_child(_center_body)
	_center.visible = false
	return _center


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
	_apply_scene()


func _hide_board() -> void:
	if _board:
		_board.queue_free()
		_board = null
	_apply_scene()


func scene_name() -> String:
	return scenes[_scene][0]


## Jump to a scene of the loop (tests, screenshots).
func show_scene(name: String) -> void:
	_scene = scenes.find_custom(func(s): return s[0] == name)
	_start_scene()


func _next_scene() -> void:
	if scene_name() == "games" and _game + 1 < _games.size():
		_game += 1                                  # the next game
		_scene_left = scenes[_scene][1]
		_apply_scene()
		return
	_scene = (_scene + 1) % scenes.size()
	_start_scene()


## Every game's name and rules (with the operator's texts: Texts).
func _load_games() -> void:
	var game: GameManager = wall.arena.game
	_games.clear()
	for t in RoundPicker.ROUND_TYPES:
		var r: GameRound = t.new()
		r.prepare(game, [])
		Texts.dress(r, RoundPicker.type_name(t))
		_games.append({"title": r.title, "rules": r.rules})


func _start_scene() -> void:
	_scene_left = scenes[_scene][1]
	_game = 0
	_load_games()                                   # (the texts may have changed)
	if scene_name() == "games":                     # the game being played now first
		var game: GameManager = wall.arena.game
		if game.current and game.state in [GameManager.State.INTRO, GameManager.State.PLAYING]:
			var now := _games.find_custom(func(g): return g.title == game.current.title)
			if now > 0:
				_games.push_front(_games.pop_at(now))
	if scene_name() == "robot":
		wall.arena.observer.close_up(_scene_left)
	_apply_scene()


## What shows over the camera: the board after a round, nothing during an
## extermination, else the loop's scene.
func _apply_scene() -> void:
	var arena := wall.arena
	var scene := scene_name()
	var free: bool = _board == null and arena.dying.is_empty()
	for c in _under:
		c.visible = free and scene == "scores"
	_center.visible = free and scene in ["games", "join"]
	if scene == "games":
		var g: Dictionary = _games[_game]
		var game: GameManager = arena.game
		var now: bool = game.current != null and game.current.title == g.title \
			and game.state in [GameManager.State.INTRO, GameManager.State.PLAYING]
		_center_sub.text = "NU BEZIG" if now else "DE SPELLEN  %d/%d" % [_game + 1, _games.size()]
		_center_sub.add_theme_color_override("font_color", Retro.GOOD if now else Retro.TEAL)
		_center_title.text = str(g.title).to_upper()
		_center_body.text = g.rules
	elif scene == "join":
		_center_sub.text = "DOE MEE!"
		_center_sub.add_theme_color_override("font_color", Retro.TEAL)
		_center_title.text = "HOE DOE JE MEE?"
		_center_body.text = Texts.join_steps()


func _process(delta: float) -> void:
	_scene_left -= delta
	if _scene_left <= 0.0:
		_next_scene()
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
			_status.text = "WACHT OP SPELERS" if arena.players.player_ids().is_empty() else "SPEL START ZO"
		GameManager.State.INTRO, GameManager.State.PLAYING:
			_status.text = game.current.title.to_upper()
		GameManager.State.SCOREBOARD:
			_status.text = "UITSLAG" if _board is RankingView else "SCOREBORD"
	if _board and (game.state != GameManager.State.SCOREBOARD or game.mode != GameManager.Mode.OPEN):
		_hide_board()
	if _board:                     # an extermination: the board steps aside for the robot
		_board.visible = arena.dying.is_empty()
	_apply_scene()
	var ranking := game.standings.ranking()
	if not ranking.is_empty():
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
		_rules.text = Texts.join_steps()
	_timer.text = game.overview_timer()
	_timer.visible = _timer.text != ""
	for c in _list.get_children():
		c.queue_free()
	var ids: Array = arena.players.player_ids()
	var invited := range(1, arena.tiles.size() + 1).filter(func(id): return not arena.players.pending_info(id).is_empty())
	var count := ids.size() + invited.size()
	_list_scale = clampf(13.0 / maxf(count, 13.0), 0.55, 1.0)   # more than 13 (mobile tiles): smaller rows
	ids.sort_custom(func(a, b): return game.survived.get(a, 0) > game.survived.get(b, 0))
	for i in ids.size():
		var id: int = ids[i]
		var tile: CyberTile = arena.tiles[id - 1]
		var col := Retro.AMBER if i == 0 and game.survived.get(id, 0) > 0 else Retro.CREAM
		if tile.is_dead:
			col = Retro.DIM
		var place := game.standings.rank(id)
		_row(Retro.tile_label(id), arena.players.player_name(id).to_upper().left(10),
			"♥".repeat(maxi(tile.health, 0)), Retro.rounds(game.survived.get(id, 0)), col, "#%d" % place if place > 0 else "")
	var rows := ids.size()
	for id in range(1, arena.tiles.size() + 1):
		var invite: Dictionary = arena.players.pending_info(id)
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
