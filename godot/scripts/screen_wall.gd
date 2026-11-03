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

const SCREEN_RES := Vector2i(1920, 1080)   # resolution of each physical screen
const GUTTER := 10                          # px of screen background between split views

@export var multi_window := false
@export var observer_page := true
## Tile ids shown on each screen (screen 1 first). 13 tiles over 5 screens.
@export var screen_groups: Array = [[1, 2, 3], [4, 5, 6], [7, 8, 9], [10, 11], [12, 13]]
## The mobile players' screens (drones M1-M5 = ids 14-18), after the floor screens.
@export var mobile_groups: Array = [[14, 15], [16, 17, 18]]
## multi_window: the monitor (OS numbering) of screen 1, 2, ... (the floor
## screens, then the mobile screens) and then the overview page. Empty / too short: screen k on monitor k-1, the overview next.
@export var monitors: Array = []
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

var arena: Node3D                       # set by arena.gd
var _screens: Array[Control] = []       # one root Control per physical screen
var _huds := {}                         # tile_id -> {cell, name, lives, score, dead}
var _mode := "players"
var _overlay_factory := Callable()      # players mode: tile_id -> Control (or null)
var _look_down := false                 # players mode: cameras look at their own tile
var _tilt_done := false                 # the tilt already played (refresh: start looking down)
var _shared_factory := Callable()       # shared mode: () -> Control
var _timer_text := ""
var _timer_labels: Array[Label] = []
var shared_views: Array = []            # current shared views, one per screen
var _observer_screen: Control           # the overview page's screen (observer_page)
var _followers: Array[Camera3D] = []    # cameras that show the floating observer rig


func setup(arena_node: Node3D) -> void:
	arena = arena_node
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
	_followers = _followers.filter(func(c): return is_instance_valid(c))
	for cam in _followers:
		cam.global_transform = arena.observer.global_transform


func timer_text() -> String:
	return _timer_text


## A view of the floating observer camera (overview page, empty screens).
func make_observer_cell() -> Control:
	var cell := _view_cell(arena.observer.global_transform, 60.0)
	_followers.append(cell.get_meta(&"camera"))
	return cell


## Text in the top-right corner of every screen (countdown / round timer).
func set_timer(text: String) -> void:
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
	_huds[tile_id]["clip"] = true         # the clip says it all: hide the big status label
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
	if log:
		arena.game.log_event("%s  %s" % [arena.player_name(tile_id).to_upper(), text], color)
	if not _huds.has(tile_id):
		return
	var cell: Control = _huds[tile_id].hud
	var l := _label(130, color)
	l.text = text
	l.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	l.grow_horizontal = Control.GROW_DIRECTION_BOTH
	l.grow_vertical = Control.GROW_DIRECTION_BOTH
	cell.add_child(l)
	var tw := l.create_tween().set_parallel()
	tw.tween_property(l, "position:y", l.position.y - 80, 0.8)
	tw.tween_property(l, "modulate:a", 0.0, 0.8).set_delay(0.3)
	tw.chain().tween_callback(l.queue_free)


## Rebuild what the screens show (call when players join or leave).
func refresh() -> void:
	_huds.clear()
	shared_views.clear()
	_timer_labels.clear()
	for k in _screens.size():
		var screen := _screens[k]
		for child in screen.get_children():
			child.queue_free()
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
			var shown := ids.filter(func(id): return arena.is_playing(id) or arena.is_pending(id))
			ids = shown if not shown.is_empty() else ids
		for id in ids:                            # floor screens: fixed, one equal slot per tile
			row.add_child(_player_view(id) if arena.is_playing(id) else _tile_slot(id))
		if ids.is_empty():                        # no installed place on this screen: how to join
			row.add_child(_join_panel())
		_add_timer_label(screen)
	_test_patterns(arena.game.mode == GameManager.Mode.SETUP)
	for screen in _screens:
		if arena.game.mode == GameManager.Mode.PAUSED:
			var banner := Retro.label(120, Retro.AMBER, "PAUZE")
			banner.add_theme_stylebox_override("normal", Retro.panel(Color(Retro.PANEL, 0.92), Retro.ORANGE, 6, 24, 60))
			banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
			banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
			banner.grow_vertical = Control.GROW_DIRECTION_BOTH
			screen.add_child(banner)
	for id in _huds:
		update_player(id)
	play_death_clips(true)


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
	var l := _label(64, Retro.AMBER)
	l.text = _timer_text
	l.visible = _timer_text != ""
	l.add_theme_stylebox_override("normal", Retro.panel(Color(Retro.PANEL, 0.95), Retro.ORANGE, 4, 16, 26))
	l.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	l.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	l.offset_right = -24
	l.offset_top = 24
	screen.add_child(l)
	_timer_labels.append(l)


## Refresh the name / lives overlay of one player view.
func update_player(tile_id: int) -> void:
	if not _huds.has(tile_id):
		return
	var hud: Dictionary = _huds[tile_id]
	var tile: CyberTile = arena.tiles[tile_id - 1]
	hud.tile.text = Retro.tile_label(tile_id)
	hud.name.text = arena.player_name(tile_id).to_upper().left(10)
	hud.lives.text = "♥".repeat(tile.health) + "♡".repeat(tile.max_health - tile.health)
	var game: GameManager = arena.game
	if game.state == GameManager.State.LOBBY:
		hud.score.text = "KLAAR"
	elif game.current and tile_id not in game.current.players:
		hud.score.text = "VOLGENDE RONDE"
	else:
		hud.score.text = Retro.rounds(game.survived.get(tile_id, 0))
	var place := game.overall_rank(tile_id)
	hud.rank.text = "#%d" % place if place > 0 else ""
	hud.rank.visible = place > 0
	hud.dead.visible = (tile.is_dead or tile.health == 0) and not hud.get("clip", false)


# ---------------------------------------------------------------- views

func _player_view(tile_id: int) -> Control:
	var tile: CyberTile = arena.tiles[tile_id - 1]
	var to_robot := (Vector3(0, tile.global_position.y, 0) - tile.global_position).normalized()
	var eye := tile.global_position - to_robot * 0.05 + Vector3(0, eye_height, 0)
	var robot_view := Transform3D(Basis(), eye).looking_at(look_at, Vector3.UP)
	var cell := _view_cell(robot_view, player_fov)
	var hud := Control.new()          # everything drawn over the view, scaled with the cell
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(hud)
	cell.resized.connect(func(): _fit_hud(cell, hud))
	if tile is DroneTile:             # the camera flies with the drone
		var rig := DroneCam.new()
		rig.wall = self
		rig.drone = tile
		rig.cam = cell.get_meta(&"camera")
		cell.add_child(rig)
		rig.follow()
		if _look_down and not tile.is_dead and not arena.dying.has(tile_id) and arena.game.in_round(tile_id):
			if _tilt_done:
				rig.down = 1.0
			else:
				var tw := rig.create_tween()
				tw.tween_interval(tilt_delay)
				tw.tween_property(rig, "down", 1.0, tilt_time).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
				var hint := LookDownHint.new()
				hint.lifetime = tilt_delay + tilt_time + 2.0
				hud.add_child(hint)
	elif _look_down and not tile.is_dead and not arena.dying.has(tile_id) and arena.game.in_round(tile_id):
		# (dying, or waiting for the next round: the view stays on the robot)
		var tile_view := Transform3D(Basis(), eye).looking_at(
			tile.global_position + to_robot * tile_look_ahead, robot_view.basis.y)
		var cam: Camera3D = cell.get_meta(&"camera")
		if _tilt_done:
			cam.transform = tile_view
			cam.fov = tile_fov
		else:
			cam.ready.connect(_tilt.bind(cam, robot_view, tile_view), CONNECT_ONE_SHOT)
			var hint := LookDownHint.new()
			hint.lifetime = tilt_delay + tilt_time + 2.0
			hud.add_child(hint)

	# one compact line in the top-left corner: [T03] NAME ♥♥♥ 3 RONDES #4 (overall place)
	var plate := Retro.panel_container(Color(Retro.PANEL, 0.85), Retro.ORANGE, 3, 14, 14)
	plate.position = Vector2(30, 26)    # inside the chamfered frame
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	plate.add_child(row)
	var tile_label := Retro.label(36, Retro.BG)
	tile_label.add_theme_stylebox_override("normal", Retro.panel(Retro.TEAL, Retro.TEAL, 0, 6, 8))
	row.add_child(tile_label)
	var name_label := Retro.label(38, Retro.CREAM)
	row.add_child(name_label)
	var lives := Retro.label(38, Color(1.0, 0.2, 0.3), "", HORIZONTAL_ALIGNMENT_LEFT)
	row.add_child(lives)
	var score := Retro.label(38, Retro.AMBER, "", HORIZONTAL_ALIGNMENT_LEFT)
	row.add_child(score)
	var rank := Retro.label(34, Retro.TEAL, "", HORIZONTAL_ALIGNMENT_LEFT)
	row.add_child(rank)
	hud.add_child(plate)

	var dead := Retro.label(80, Retro.BAD, "GEËXTERMINEERD!")
	dead.add_theme_stylebox_override("normal", Retro.panel(Color(0.1, 0.0, 0.0, 0.85), Retro.BAD, 6, 24, 40))
	dead.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	dead.grow_horizontal = Control.GROW_DIRECTION_BOTH
	dead.grow_vertical = Control.GROW_DIRECTION_BOTH
	hud.add_child(dead)
	if _overlay_factory.is_valid():
		var overlay: Control = _overlay_factory.call(tile_id)
		if overlay:
			hud.add_child(overlay)
	_huds[tile_id] = {"cell": cell, "hud": hud, "tile": tile_label, "name": name_label, "lives": lives,
		"rank": rank,
		"score": score, "dead": dead}
	return cell


## A screen without installed places (a partial installation): the call to
## action and how to join, instead of an empty screen.
func _join_panel() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", Retro.panel(Color(Retro.PANEL, 0.95), Retro.ORANGE, 2, 0, 40))
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 40)
	panel.add_child(box)
	box.add_child(Retro.label(96, Retro.TEAL, "CYBER CIRCLE"))
	var cta := CallToAction.new(64)
	cta.custom_minimum_size.y = 220
	box.add_child(cta)
	var how := Retro.label(40, Retro.CREAM, Texts.join_text())
	how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(how)
	return panel


func _tile_slot(tile_id: int) -> Control:
	var slot := TileSlot.new()
	slot.tile_id = tile_id
	slot.out_of_service = not arena.is_enabled(tile_id)
	slot.mode = arena.game.mode_name()
	var invite: Dictionary = arena.pending_info(tile_id)
	if not invite.is_empty():
		slot.player = invite.name
		slot.color = invite.color
		slot.tile = arena.tiles[tile_id - 1]     # (the icons pressed so far)
	return slot


## Scale a player HUD with its cell: 1 at full screen, smaller in a split.
func _fit_hud(cell: Control, hud: Control) -> void:
	var full := Vector2(SCREEN_RES)
	var s := clampf(sqrt(cell.size.x * cell.size.y / (full.x * full.y)), hud_min_scale, 1.0)
	hud.scale = Vector2(s, s)
	hud.size = cell.size / s


## A cell with its own camera rendering the shared 3D world.
func _view_cell(xform: Transform3D, fov: float) -> Control:
	var cell := Control.new()
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cell.clip_contents = true
	var container := SubViewportContainer.new()
	container.stretch = true
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	cell.add_child(container)
	var vp := SubViewport.new()
	vp.physics_object_picking = true   # click the tile icons inside a view
	vp.msaa_3d = Viewport.MSAA_2X
	container.add_child(vp)
	cell.add_child(Retro.ViewFrame.new())
	var cam := Camera3D.new()
	cam.fov = fov
	cam.transform = xform
	vp.add_child(cam)
	cam.current = true
	cell.set_meta(&"camera", cam)
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
## the places that are not installed (Arena.set_installed).
func groups() -> Array:
	if arena == null:
		return screen_groups + mobile_groups
	return (screen_groups + mobile_groups).map(func(g): return g.filter(func(id): return arena.is_installed(id)))


## A drone player's camera, third person: behind and well above the drone,
## looking down past it at the robot - the drone low in the view, the robot
## above it (the drone flies higher than the robot: from just behind it would
## cover the robot). down = 1: over the drone, looking down at its top (LEDs,
## icons; the robot side up), for the rounds on the tile.
class DroneCam:
	extends Node
	var wall: ScreenWall
	var drone: DroneTile
	var cam: Camera3D
	var down := 0.0

	func _process(_delta: float) -> void:
		follow()

	func follow() -> void:
		if not is_instance_valid(drone) or not cam.is_inside_tree():
			return
		var p := drone.global_position
		var out := Vector3(p.x, 0, p.z).normalized()
		if out.is_zero_approx():
			return
		var r := minf(Vector2(p.x, p.z).length() + wall.drone_cam_back, 6.0)   # (inside the room)
		var eye := Vector3(out.x * r, p.y + wall.drone_cam_up, out.z * r)
		var chase := Transform3D(Basis(), eye).looking_at(wall.look_at.lerp(p, wall.drone_cam_aim), Vector3.UP)
		var over := Transform3D(Basis(), p + Vector3(0, 0.95, 0) + out * 0.3).looking_at(
			p + Vector3(0, 0.05, 0) - out * 0.05, -out)
		cam.global_transform = chase.interpolate_with(over, down)
		cam.fov = lerpf(wall.player_fov, wall.tile_fov, down)


func _label(font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Retro.BG)
	l.add_theme_constant_override("outline_size", 10)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


# ---------------------------------------------------------------- layout

## Every screen renders at a fixed SCREEN_RES (the real 1080p monitors) and is
## scaled as a whole to fit, so the layout is identical in the preview and on
## any monitor.
## register = false: not one of the 5 player screens (the observer page).
func _new_screen(parent: Node, register := true) -> Control:
	var holder := Control.new()
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.clip_contents = true
	parent.add_child(holder)
	var container := SubViewportContainer.new()
	container.size = SCREEN_RES
	holder.add_child(container)
	var vp := SubViewport.new()
	vp.size = SCREEN_RES
	vp.physics_object_picking = true
	container.add_child(vp)
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.size = SCREEN_RES
	bg.theme = Retro.theme()
	vp.add_child(bg)
	var crt := Retro.crt_overlay()   # stays on top: refresh() only replaces bg's children
	crt.set_anchors_preset(Control.PRESET_TOP_LEFT)
	crt.size = SCREEN_RES
	vp.add_child(crt)
	var fit := func():
		var k := minf(holder.size.x / SCREEN_RES.x, holder.size.y / SCREEN_RES.y)
		container.scale = Vector2(k, k)
		container.position = (holder.size - Vector2(SCREEN_RES) * k) / 2
	holder.resized.connect(fit)
	fit.call()
	if register:
		_screens.append(bg)
	return bg


func _add_observer_page(parent: Node) -> void:
	var page := ObserverView.new()
	page.wall = self
	_observer_screen = _new_screen(parent, false)
	_observer_screen.add_child(page)


## SETUP: a test pattern over every screen (which screen, edges, colours, live)
## and the overview page; the CRT effect off so lines and colours are exact.
func _test_patterns(on: bool) -> void:
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
		var crt := screen.get_parent().get_child(1) as CanvasItem   # (see _new_screen)
		if crt:
			crt.visible = not on
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
	for k in groups().size():
		if k % 3 == 0:
			row = HBoxContainer.new()
			row.size_flags_vertical = Control.SIZE_EXPAND_FILL
			row.alignment = BoxContainer.ALIGNMENT_CENTER
			rows.add_child(row)
		var aspect := AspectRatioContainer.new()
		aspect.ratio = 16.0 / 9.0
		aspect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(aspect)
		_new_screen(aspect)
	if observer_page:
		if groups().size() % 3 == 0:
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
func _build_windows() -> void:
	for k in groups().size():
		if k == 0:
			_place(get_window(), 0)
			_new_screen(self)
			continue
		var win := Window.new()
		win.title = "Cyber Circle - scherm %d" % (k + 1)
		win.size = Vector2i(1280, 720)
		add_child(win)
		_place(win, k)
		_new_screen(win)
	if observer_page:
		var win := Window.new()
		win.title = "Cyber Circle - overzicht"
		win.size = Vector2i(1280, 720)
		add_child(win)
		_place(win, groups().size())
		_add_observer_page(win)


## Full screen on the monitor for window k (screens first, then the overview).
## Not enough monitors (e.g. testing on one big screen): the windows that have
## no monitor of their own are put in a 3-column grid on the first monitor.
func _place(win: Window, k: int) -> void:
	var count := DisplayServer.get_screen_count()
	var m: int = int(monitors[k]) if k < monitors.size() else k
	var windows := groups().size() + (1 if observer_page else 0)
	if count >= windows and m < count:
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
	win.position = area.position + Vector2i((k % cols) * cell.x, (k / cols) * cell.y)
