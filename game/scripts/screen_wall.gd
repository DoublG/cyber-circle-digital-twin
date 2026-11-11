class_name ScreenWall
extends CanvasLayer
## The 5 screens of the installation. Every screen serves a fixed group of
## tiles and shows the first-person view of each player on those tiles who is
## in the game (split screen):
##   a fixed layout: one equal slot per tile, side by side in tile order - the
##   player's view, or a TileSlot when there is no player (free, or invited:
##   the name of the player who registered in the app). Nothing resizes when
##   players come and go.
## Every player camera is fixed on its tile, at eye height, looking at the robot.
## Mobile players (drones, M1-M5) have screens of their own (mobile_groups,
## after the floor screens): their camera follows the drone in third person -
## behind and well above it, so their own drone is low in the view and the
## robot fully visible above it; it flies, swoops and falls with the drone. Those screens are not fixed:
## only the mobile players who play (or are invited) get a view, side by side
## from left to right, growing to fill the screen (1 player: the whole
## screen); nobody: the free slots.
## A player's HUD (plate, popups, round info) is laid out for a full 1920x1080
## screen and scaled with its cell, so it looks the same in every split.
## In rounds played on the tile itself (GameRound.on_tile) the camera tilts down
## to the player's own tile once the round starts, with an arrow hint (a drone
## camera swings up over the drone and looks down on its LEDs and icons).
## That is the "players" mode (lobby and personal rounds). In "shared" mode
## (shared rounds, intros, scoreboards) every screen shows the same view.
##
## multi_window = false: all 5 screens as a preview in the main window.
## multi_window = true:  screen 1 in the main window, screens 2-5 in their own
##                       full-screen windows on monitors 2-5 (if connected).
## observer_page: an extra full-screen display for visitors (ObserverView):
## the floating observer camera with the round and a live player list
## (multi_window: monitor 6; preview: next to screens 4 and 5).
## remote_screens: screens a display node renders (Replica: a Raspberry Pi per
## 2 screens): built here as always - the game drives them - but off stage and
## never rendered (only for a companion video). On a display node itself every
## screen it does not show is remote, and stays empty.

const SCREEN_RES := Vector2i(1920, 1080)   # resolution of each physical screen
const GUTTER := 10                          # px of screen background between split views
const WALL_SCREEN := preload("res://scenes/ui/wall_screen.tscn")
const JOIN_PANEL := preload("res://scenes/ui/join_panel.tscn")
const TIMER_LABEL := preload("res://scenes/ui/timer_label.tscn")
const PAUSE_BANNER := preload("res://scenes/ui/pause_banner.tscn")
const FLOATING_TEXT := preload("res://scenes/ui/floating_text.tscn")

@export var multi_window := false
@export var observer_page := true
## Tile ids shown on each screen (screen 1 first). 13 tiles over 5 screens.
@export var screen_groups: Array = [[1, 2, 3], [4, 5, 6], [7, 8, 9], [10, 11], [12, 13]]
## The mobile players' screens (drones M1-M5 = ids 14-18), after the floor screens.
@export var mobile_groups: Array = [[14, 15], [16, 17, 18]]
## multi_window: the monitor (OS numbering) of screen 1, 2, ... (the floor
## screens, then the mobile screens) and then the overview page. Empty / too
## short: screen k on monitor k-1, the overview next.
@export var monitors: Array = []
## Screen numbers (1-based) rendered by display nodes, not here.
@export var remote_screens: Array = []
@export var eye_height := 1.45          # camera height above the tile (m)
@export var player_fov := 70.0
@export var look_at := Vector3(0, 1.0, 0)  # robot point the players look at
@export var tilt_delay := 0.4           # s before the camera tilts down to the tile
@export var tilt_time := 1.6            # s the tilt takes
@export var tile_look_ahead := 0.3      # m in front of the player's feet (towards the robot)
@export var tile_fov := 48.0            # zoom in on the tile while tilting down
@export var hud_min_scale := 0.8        # narrow (3 side by side) views: keep the HUD readable
@export var drone_cam_back := 0.9       # drone camera (third person): m behind the drone ...
@export var drone_cam_up := 1.6         # ... and above it: looking down steeply, the drone under the robot
@export var drone_cam_aim := 0.45       # aim between the robot (0) and the drone (1)

var windowed := false                   # a display node: windows, not full screen (testing on one monitor)
var view_scale := 1.0                   # the 3D views' resolution (a display node: lighter, Arena --view-scale)
var view_msaa := Viewport.MSAA_2X
var view_lod := 1.0                     # mesh LOD threshold (higher: coarser models further away)
var arena: Arena                       # set by arena.gd
var diag := {}                    # SETUP: the installation's state for the test screens (MqttBridge.diagnosis)
var last_press := {}              # SETUP: tile id -> {"button", "msec"}: the test screens light it up
var shared_views: Array = []            # current shared views, one per screen

var _screens: Array[Control] = []       # one root Control per physical screen
var _huds := {}                         # tile_id -> {cell: ViewCell, hud: PlayerHud}
var _mode := "players"
var _overlay_factory := Callable()      # players mode: tile_id -> Control (or null)
var _look_down := false                 # players mode: cameras look at their own tile
var _tilt_done := false                 # the tilt already played (refresh: start looking down)
var _shared_factory := Callable()       # shared mode: () -> Control
var _timer_text := ""
var _timer_labels: Array[Label] = []
var _diag_at := 0
var _observer_screen: Control           # the overview page's screen (observer_page)
var _followers: Array[Camera3D] = []    # cameras that show the floating observer rig
var _offstage: SubViewport              # remote screens live here: in the tree, never rendered
var _rendered := {}                     # remote screen index -> users that need its picture here (companion video)
var _link: Array[Label] = []            # a display node: the connection notice on each screen
var _offline_since := -1.0              # a display node: msec the link to the master went (-1: online)


func setup(arena_node: Arena) -> void:
	arena = arena_node
	if not remote_screens.is_empty():
		_offstage = SubViewport.new()
		_offstage.name = "Offstage"
		_offstage.size = Vector2i(2, 2)
		_offstage.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(_offstage)
	if multi_window:
		_build_windows()
	else:
		_build_preview()
	refresh()


## Every screen shows the views of its players (lobby / personal rounds).
## look_down: tilt the cameras from the robot down to the player's own tile.
func show_players(overlay_factory := Callable(), look_down := false) -> void:
	_mode = "players"
	_overlay_factory = overlay_factory
	_look_down = look_down
	_tilt_done = false
	refresh()
	if look_down:
		get_tree().create_timer(tilt_delay + tilt_time).timeout.connect(func(): _tilt_done = true)


## Every screen shows its own instance of factory.call() (shared rounds, scores).
func show_shared(factory: Callable) -> void:
	_mode = "shared"
	_shared_factory = factory
	refresh()


func _process(_delta: float) -> void:
	if Replica.client:
		_update_link()
	elif arena.game.mode == GameManager.Mode.SETUP and Time.get_ticks_msec() - _diag_at >= 1000:
		_diag_at = Time.get_ticks_msec()          # (wall clock: the test screens' "seen 3 s ago")
		var mqtt := arena.get_node_or_null("Mqtt") as MqttBridge
		if mqtt:
			set_diag(mqtt.diagnosis())
	_followers = _followers.filter(func(c): return is_instance_valid(c))
	for cam in _followers:
		cam.global_transform = arena.observer.global_transform


func timer_text() -> String:
	return _timer_text


## A view of the floating observer camera (overview page, empty screens).
func make_observer_cell() -> Control:
	var cell := _view_cell(arena.observer.global_transform, 60.0)
	_followers.append(cell.camera)
	return cell


## SETUP: the master's diagnosis (its tiles, the broker), for the test screens.
func set_diag(d: Dictionary) -> void:
	Replica.relay_live("wall", &"set_diag", [d])
	diag = d


func _on_press(tile_id: int, button: StringName) -> void:
	last_press[tile_id] = {"button": button, "msec": Time.get_ticks_msec()}


## Text in the top-right corner of every screen (countdown / round timer).
func set_timer(text: String) -> void:
	Replica.relay_live("wall", &"set_timer", [text])
	_timer_text = text
	for l in _timer_labels:
		if is_instance_valid(l):
			l.text = text
			l.visible = text != ""


## Play a short movie (Theora .ogv) over one player's view, e.g. the death
## clip. It fills the view (cropped to its shape): make clips square with the
## important part in the centre 55%, then they work in every split (wide view,
## half, narrow third). Returns its length in seconds (0 when the player has
## no view or the file is missing).
## Only in the players' own (split screen) views - never over a shared screen
## (scoreboard, intro, quiz): then nothing, and it plays (from where it would
## be) once the screens show the players' views again.
## from: s into the clip (the screens were rebuilt while it played).
func play_clip(tile_id: int, path: String, from := 0.0) -> float:
	if _mode == "shared" or not _huds.has(tile_id) or not ResourceLoader.exists(path):
		return 0.0
	var cell: Control = _huds[tile_id].cell
	var player := VideoStreamPlayer.new()
	player.stream = load(path)
	player.visible = false                # decode only; shown via the TextureRect
	if not arena.sound.plays_here():
		player.volume_db = -80.0          # (the display nodes play its sound)
	cell.add_child(player)
	var back := ColorRect.new()
	back.color = Color.BLACK
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var view := TextureRect.new()
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	back.add_child(view)
	cell.add_child(back)
	cell.move_child(back, 1)              # over the 3D view, under the frame and the HUD
	(_huds[tile_id].hud as PlayerHud).clip_playing = true   # the clip says it all: no big status label
	update_player(tile_id)
	player.play()
	if from > 0.0:
		player.stream_position = from
	view.texture = player.get_video_texture()
	var length := player.get_stream_length()
	if length <= 0.0:
		length = 4.0
	player.finished.connect(func():           # too short: the last frame stays until the view goes
		var last := player.get_video_texture().get_image() if player.get_video_texture() else null
		if last:
			view.texture = ImageTexture.create_from_image(last)
		player.queue_free())
	return length - from


## Floating text (e.g. "+3") over one player's view.
## log = false: not in the overview's event feed (it already has a summary line).
func popup(tile_id: int, text: String, color: Color, log := true) -> void:
	Replica.relay("wall", &"popup", [tile_id, text, color, false])
	if log:
		arena.game.log_event("%s  %s" % [arena.players.player_name(tile_id).to_upper(), text], color)
	if not _huds.has(tile_id):
		return
	var l: Label = FLOATING_TEXT.instantiate()
	l.text = text
	l.add_theme_color_override("font_color", color)
	_huds[tile_id].hud.add_child(l)
	var tw := l.create_tween().set_parallel()
	tw.tween_property(l, "position:y", l.position.y - 80, 0.8)
	tw.tween_property(l, "modulate:a", 0.0, 0.8).set_delay(0.3)
	tw.chain().tween_callback(l.queue_free)


## refresh() here and on the display nodes (the game: players joined / left,
## a mode, a text changed). Their own show_players / show_shared refresh there.
func refresh_all() -> void:
	Replica.relay("wall", &"refresh", [])
	refresh()


## A method of every shared view (the quiz's show_question, the intro's
## show_message, the scoreboard's reveal_lives): here, and on the displays
## (live: called every frame - only the latest goes out, see Replica.relay_live).
func call_shared(method: StringName, args: Array, live := false) -> void:
	if live:
		Replica.relay_live("wall", &"call_shared", [method, args])
	else:
		Replica.relay("wall", &"call_shared", [method, args])
	for v in shared_views:
		if is_instance_valid(v) and v.has_method(method):
			v.callv(method, args)


## A display node: the link to the master came / went (Replica.online_changed).
func set_link(on: bool) -> void:
	_offline_since = -1.0 if on else Time.get_ticks_msec()
	_update_link()


func _update_link() -> void:
	var off := -1.0 if _offline_since < 0.0 else (Time.get_ticks_msec() - _offline_since) / 1000.0
	var never: bool = arena.replica == null or arena.replica.stats.snapshots == 0
	for l in _link:
		if not is_instance_valid(l):
			continue
		if never:
			l.text = "WACHTEN OP DE MASTER …"
			l.visible = true
		elif off >= 30.0:
			l.text = "GEEN VERBINDING MET DE MASTER (%d s)\nHET SPEL LOOPT DOOR" % int(off)
			l.visible = true
		elif off >= 3.0:
			l.text = "VERBINDING HERSTELLEN …"
			l.visible = true
		else:
			l.visible = false
		l.add_theme_font_size_override("font_size", 64 if off >= 30.0 or never else 34)


## Rebuild what the screens show (call when players join or leave).
func refresh() -> void:
	_huds.clear()
	shared_views.clear()
	_timer_labels.clear()
	for k in _screens.size():
		var screen := _screens[k]
		for child in screen.get_children():
			child.queue_free()
		if Replica.client and is_remote(k):
			continue                                    # (a display node: not one of its screens)
		if _mode == "shared":
			var view: Control = _shared_factory.call()
			view.set_anchors_preset(Control.PRESET_FULL_RECT)
			screen.add_child(view)
			if view.has_method("highlight_tiles"):     # player lists: the players facing this screen find their row
				view.highlight_tiles(groups()[k])
			shared_views.append(view)
			_add_timer_label(screen)
			continue
		var mobile := k >= screen_groups.size()
		var row := HBoxContainer.new()             # left to right
		row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, GUTTER)
		row.add_theme_constant_override("separation", GUTTER)
		screen.add_child(row)
		var ids: Array = groups()[k]
		if mobile:                                # mobile screen: only who plays / is invited, scaled up
			var shown := ids.filter(func(id): return arena.players.is_playing(id) or arena.players.is_pending(id))
			ids = shown if not shown.is_empty() else ids
		for id in ids:                            # floor screens: fixed, one equal slot per tile
			row.add_child(_player_view(id) if arena.players.is_playing(id) else _tile_slot(id))
		if ids.is_empty():                        # no installed place on this screen: how to join
			row.add_child(_join_panel())
		_add_timer_label(screen)
	_test_patterns(arena.game.mode == GameManager.Mode.SETUP)
	for screen in _screens:
		if arena.game.mode == GameManager.Mode.PAUSED:
			screen.add_child(PAUSE_BANNER.instantiate())
	for id in _huds:
		update_player(id)
	play_death_clips(true)
	_freeze_remote()


func is_remote(k: int) -> bool:
	return (k + 1) in remote_screens


## The remote screens and their 3D views: never rendered here (the displays
## do) - unless their picture is needed here (render_remote: a companion video).
func _freeze_remote() -> void:
	for k in _screens.size():
		if is_remote(k):
			var mode := SubViewport.UPDATE_ALWAYS if _rendered.get(k, 0) > 0 else SubViewport.UPDATE_DISABLED
			var vp := _screens[k].get_viewport() as SubViewport
			vp.render_target_update_mode = mode
			for sub in vp.find_children("*", "SubViewport", true, false):
				(sub as SubViewport).render_target_update_mode = mode


## A remote screen rendered here after all (on = true) or not any more.
func render_remote(k: int, on: bool) -> void:
	if not is_remote(k):
		return
	_rendered[k] = maxi(int(_rendered.get(k, 0)) + (1 if on else -1), 0)
	_freeze_remote()


## Death clips (only in split-screen player views, never over shared screens):
## a waiting one starts from the beginning as soon as the player's view is on
## screen; after a rebuild (resume) a playing one continues where it was.
func play_death_clips(resume := false) -> void:
	if _mode == "shared":
		return
	for id in arena.clip_waiting.keys():
		if arena.clip_started.has(id):
			if resume:
				var at: float = arena.clock - float(arena.clip_started[id])
				if arena.death_clip_pending(id):    # (past its end: just its last frame)
					play_clip(id, arena.death_clip, minf(at, arena.death_clip_length() - 0.1))
		elif arena.death_clip_pending(id) and play_clip(id, arena.death_clip) > 0.0:
			arena.clip_started[id] = arena.clock


## The timer, top-right on every screen (no player's plate is there).
func _add_timer_label(screen: Control) -> void:
	var l: Label = TIMER_LABEL.instantiate()
	l.text = _timer_text
	l.visible = _timer_text != ""
	screen.add_child(l)
	_timer_labels.append(l)


## Refresh the name / lives overlay of one player view.
func update_player(tile_id: int) -> void:
	if not _huds.has(tile_id):
		return
	var tile: CyberTile = arena.tiles[tile_id - 1]
	var game: GameManager = arena.game
	var score := Retro.rounds(game.survived.get(tile_id, 0))
	if game.state == GameManager.State.LOBBY:
		score = "KLAAR"
	elif game.current and tile_id not in game.current.players:
		score = "VOLGENDE RONDE"
	(_huds[tile_id].hud as PlayerHud).show_player(Retro.tile_label(tile_id),
		arena.players.player_name(tile_id).to_upper().left(10),
		"♥".repeat(tile.health) + "♡".repeat(tile.max_health - tile.health), score,
		tile.is_dead or tile.health == 0)


# ---------------------------------------------------------------- views

## One player's part of a screen: the view from their tile (a drone: from
## behind it) with their name plate and the round's overlay over it.
func _player_view(tile_id: int) -> Control:
	var tile: CyberTile = arena.tiles[tile_id - 1]
	var to_robot := (Vector3(0, tile.global_position.y, 0) - tile.global_position).normalized()
	var eye := tile.global_position - to_robot * 0.05 + Vector3(0, eye_height, 0)
	var robot_view := Transform3D(Basis(), eye).looking_at(look_at, Vector3.UP)
	var cell := _view_cell(robot_view, player_fov)
	var hud := PlayerHud.create()     # everything drawn over the view, scaled with the cell
	cell.add_child(hud)
	cell.resized.connect(hud.fit.bind(cell, Vector2(SCREEN_RES), hud_min_scale))
	# (dying, or waiting for the next round: the view stays on the robot)
	var look_down: bool = _look_down and not tile.is_dead and not arena.dying.has(tile_id) \
			and arena.game.in_round(tile_id)
	var tilting := false
	if tile is DroneTile:
		tilting = _drone_camera(cell, tile, look_down)
	elif look_down:
		var tile_view := Transform3D(Basis(), eye).looking_at(
			tile.global_position + to_robot * tile_look_ahead, robot_view.basis.y)
		tilting = _tile_camera(cell.camera, robot_view, tile_view)
	if tilting:
		var hint := LookDownHint.create()
		hint.lifetime = tilt_delay + tilt_time + 2.0
		hud.add_child(hint)
		hud.move_child(hint, 0)       # under the name plate
	if _overlay_factory.is_valid():
		var overlay: Control = _overlay_factory.call(tile_id)
		if overlay:
			hud.add_child(overlay)
	_huds[tile_id] = {"cell": cell, "hud": hud}
	return cell


## A drone's view: the camera flies with the drone, and tilts over it when the
## players look down. Returns true while that tilt plays (the look-down hint).
func _drone_camera(cell: ViewCell, drone: DroneTile, look_down: bool) -> bool:
	var rig := DroneCam.new()
	rig.wall = self
	rig.drone = drone
	rig.cam = cell.camera
	cell.add_child(rig)
	rig.follow()
	if not look_down:
		return false
	if _tilt_done:
		rig.down = 1.0
		return false
	var tw := rig.create_tween()
	tw.tween_interval(tilt_delay)
	tw.tween_property(rig, "down", 1.0, tilt_time).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	return true


## A floor player's camera looks down at their tile. Returns true while the
## tilt plays (the look-down hint); already played: it starts looking down.
func _tile_camera(cam: Camera3D, robot_view: Transform3D, tile_view: Transform3D) -> bool:
	if _tilt_done:
		cam.transform = tile_view
		cam.fov = tile_fov
		return false
	cam.ready.connect(_tilt.bind(cam, robot_view, tile_view), CONNECT_ONE_SHOT)
	return true


## A screen without installed places (a partial installation): the call to
## action and how to join, instead of an empty screen.
func _join_panel() -> Control:
	var panel: Control = JOIN_PANEL.instantiate()
	(panel.get_node("%How") as Label).text = Texts.join_text()
	return panel


func _tile_slot(tile_id: int) -> Control:
	var slot := TileSlot.create()
	slot.tile_id = tile_id
	slot.out_of_service = not arena.installation.is_enabled(tile_id)
	slot.mode = arena.game.modes.name()
	var invite: Dictionary = arena.players.pending_info(tile_id)
	if not invite.is_empty():
		slot.player = invite.name
		slot.color = invite.color
		slot.tile = arena.tiles[tile_id - 1]     # (the icons pressed so far)
	return slot


## A cell with its own camera rendering the shared 3D world.
func _view_cell(xform: Transform3D, fov: float) -> ViewCell:
	var cell := ViewCell.create(xform, fov)
	cell.viewport.msaa_3d = view_msaa
	cell.viewport.scaling_3d_scale = view_scale
	cell.viewport.mesh_lod_threshold = view_lod
	return cell


## Smoothly turn a player camera from one view to another (same position).
func _tilt(cam: Camera3D, from: Transform3D, to: Transform3D) -> void:
	var q0 := from.basis.get_rotation_quaternion()
	var q1 := to.basis.get_rotation_quaternion()
	var tween := cam.create_tween()
	tween.tween_interval(tilt_delay)
	var fov0 := cam.fov
	tween.tween_method(func(t: float):
		cam.basis = Basis(q0.slerp(q1, t))
		cam.fov = lerpf(fov0, tile_fov, t), 0.0, 1.0, tilt_time) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## The floor screens and then the mobile screens: the tile ids of each screen.
## The tiles on each screen (floor screens, then the mobile screens), without
## the places that are not installed (Installation.set_installed).
func groups() -> Array:
	if arena == null:
		return screen_groups + mobile_groups
	return (screen_groups + mobile_groups).map(func(g): return g.filter(arena.installation.is_installed))


# ---------------------------------------------------------------- layout

## A screen of the wall (WallScreen: rendered at SCREEN_RES, scaled as a whole
## to fit). Returns what it shows: refresh() replaces its children.
## register = false: not one of the 5 player screens (the observer page).
func _new_screen(parent: Node, register := true) -> Control:
	var screen: WallScreen = WALL_SCREEN.instantiate()
	parent.add_child(screen)
	if register:
		_screens.append(screen.content)
		if Replica.client:            # a display node: the link to the master, over everything
			_link.append(screen.link)
	return screen.content


## Screen k's own rendered picture (the SubViewport it is drawn in): the
## companion stream reads it back (CompanionStream).
func screen_viewport(k: int) -> Viewport:
	return _screens[k].get_viewport() if k >= 0 and k < _screens.size() else null


func _add_observer_page(parent: Node) -> void:
	var page := ObserverView.create(self)
	_observer_screen = _new_screen(parent, false)
	_observer_screen.add_child(page)


## SETUP: a test pattern over every screen (which screen, edges, colours, live)
## and the overview page; the CRT effect off so lines and colours are exact.
func _test_patterns(on: bool) -> void:
	if on:                                   # which button a tile last got (the wiring check)
		for t in arena.tiles:
			if not t.button_pressed.is_connected(_on_press):
				t.button_pressed.connect(_on_press)
	var mqtt := arena.get_node_or_null("Mqtt") as MqttBridge
	var node: String = mqtt.node_id if mqtt and mqtt.node_id != "" else "-"
	var all: Array[Control] = _screens.duplicate()
	if _observer_screen:
		all.append(_observer_screen)
	for k in all.size():
		var screen := all[k]
		var old := screen.get_node_or_null("TestPattern")
		if old:
			screen.remove_child(old)
			old.queue_free()
		(screen.owner as WallScreen).crt.visible = not on
		if not on:
			continue
		var tp := TestPattern.new()
		tp.name = "TestPattern"
		tp.screen_number = k + 1
		tp.screen_count = _screens.size()
		tp.tiles = groups()[k] if k < groups().size() else []
		var m: int = int(monitors[k]) if k < monitors.size() else k
		tp.output = "MONITOR %d" % m if multi_window else "PREVIEW"
		tp.node_name = node
		tp.wall = self
		screen.add_child(tp)


## Preview: 3 per row (floor screens, mobile screens, then the overview), each
## kept at 16:9 - 8 panes fill a 16:9 window.
func _build_preview() -> void:
	var back := ColorRect.new()
	back.color = Color(0.08, 0.08, 0.1)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(back)
	var rows := VBoxContainer.new()
	rows.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(rows)
	var row: HBoxContainer
	var shown := 0
	for k in groups().size():
		if is_remote(k):
			_new_screen(_offstage)
			continue
		if shown % 3 == 0:
			row = HBoxContainer.new()
			row.size_flags_vertical = Control.SIZE_EXPAND_FILL
			row.alignment = BoxContainer.ALIGNMENT_CENTER
			rows.add_child(row)
		var aspect := AspectRatioContainer.new()
		aspect.ratio = 16.0 / 9.0
		aspect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(aspect)
		_new_screen(aspect)
		shown += 1
	if observer_page:
		if shown % 3 == 0:
			row = HBoxContainer.new()
			row.size_flags_vertical = Control.SIZE_EXPAND_FILL
			row.alignment = BoxContainer.ALIGNMENT_CENTER
			rows.add_child(row)
		var aspect := AspectRatioContainer.new()
		aspect.ratio = 16.0 / 9.0
		aspect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(aspect)
		_add_observer_page(aspect)


## One screen per monitor: screen 1 in the main window, the others in windows.
## Remote screens (display nodes) get no window: the first window here (a
## screen, or only the overview) is the main window.
func _build_windows() -> void:
	var local := 0
	for k in groups().size():
		if is_remote(k):
			_new_screen(_offstage)
			continue
		if local == 0:
			_place(get_window(), k, local)
			_new_screen(self)
		else:
			var win := Window.new()
			win.title = "Cyber Circle Challenge - scherm %d" % (k + 1)
			win.size = Vector2i(1280, 720)
			add_child(win)
			_place(win, k, local)
			_new_screen(win)
		local += 1
	if observer_page:
		if local == 0:
			_place(get_window(), groups().size(), 0)
			_add_observer_page(self)
			return
		var win := Window.new()
		win.title = "Cyber Circle Challenge - overzicht"
		win.size = Vector2i(1280, 720)
		add_child(win)
		_place(win, groups().size(), local)
		_add_observer_page(win)


## Full screen on the monitor for window k (screens first, then the overview).
## Not enough monitors (e.g. testing on one big screen): the windows that have
## no monitor of their own are put in a 3-column grid on the first monitor.
func _place(win: Window, k: int, local := -1) -> void:
	if local < 0:
		local = k
	var count := DisplayServer.get_screen_count()
	var m: int = int(monitors[k]) if k < monitors.size() else local
	var windows := groups().size() - remote_screens.size() + (1 if observer_page else 0)
	if count >= windows and m < count and not windowed:
		win.position = DisplayServer.screen_get_position(m)
		win.mode = Window.MODE_FULLSCREEN
		return
	var area := DisplayServer.screen_get_usable_rect(0)
	var cols := 4
	var rows := ceili(windows / float(cols))
	var cell := Vector2i(area.size.x / cols, area.size.y / rows)
	var size := Vector2i(cell.x, cell.x * 9 / 16)
	if size.y > cell.y:
		size = Vector2i(cell.y * 16 / 9, cell.y)
	win.mode = Window.MODE_WINDOWED
	win.size = size
	win.position = area.position + Vector2i((local % cols) * cell.x, (local / cols) * cell.y)
