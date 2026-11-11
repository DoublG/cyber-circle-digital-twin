class_name TestPattern
extends Control
## Test screen for the physical setup (game mode SETUP), drawn over a whole
## screen on top of the tile slots (which show their tile number big):
##   which screen      "SCHERM 2 / 5", its tiles, monitor and node
##   edges / overscan  a 1 px border, corner marks and arrows: all four must be
##                     visible, "BOVEN" at the top (not mounted upside down)
##   scaling           the real window size next to the 1920x1080 it renders at;
##                     1 px lines at the left that must look sharp, not grey
##   colours           colour bars and an 11-step grey ramp: 0 % and 10 % must
##                     differ (black level), 90 % and 100 % too (white clipping)
##   live              a running clock and a sweeping bar: stops = frozen screen
##   tiles             per tile on this screen: its physical tile (online, firmware,
##                     address, Ethernet link, last hello) and its 4 buttons, lit
##                     when pressed (the wiring check); the overview: every place
##   network           the broker (master) or the link to the master (display node:
##                     ping, loss, last update), the display nodes (overview)
##   performance       fps, frame time, slow frames, renderer and GPU
## Plain 2D, cheap to draw.

const SLOW_MS := 1000.0 / 30.0
const LIT_MS := 1200               # a pressed button stays lit this long

const BARS := [Color.WHITE, Color.YELLOW, Color.CYAN, Color.GREEN, Color.MAGENTA, Color.RED, Color.BLUE, Color.BLACK]

var screen_number := 1
var screen_count := 1
var tiles: Array = []              # tile ids on this screen ([] = the overview)
var output := ""                   # e.g. "MONITOR 2" / "PREVIEW"
var node_name := ""
var wall: ScreenWall               # its diagnosis and the tiles' last presses
var _t := 0.0
var _frames: Array = []            # [msec, frame ms] of the last 2 s


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	_t += delta
	var now := Time.get_ticks_msec()
	_frames.append([now, delta * 1000.0])
	while not _frames.is_empty() and now - int(_frames[0][0]) > 2000:
		_frames.pop_front()
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	if tiles.is_empty():                   # the overview: a clean test screen, no 3D behind it
		draw_rect(Rect2(0, 0, w, h), Retro.PANEL)
	# edges: 1 px border, corner marks and arrows pointing out
	draw_rect(Rect2(0.5, 0.5, w - 1, h - 1), Color.WHITE, false, 1.0)
	for c in [Vector2(0, 0), Vector2(w, 0), Vector2(0, h), Vector2(w, h)]:
		var dx := 1.0 if c.x == 0 else -1.0
		var dy := 1.0 if c.y == 0 else -1.0
		draw_line(c + Vector2(dx * 2, dy * 2), c + Vector2(dx * 90, dy * 2), Retro.AMBER, 4.0)
		draw_line(c + Vector2(dx * 2, dy * 2), c + Vector2(dx * 2, dy * 90), Retro.AMBER, 4.0)
	_arrow(Vector2(w / 2, 6), Vector2(0, -1))
	_arrow(Vector2(w / 2, h - 6), Vector2(0, 1))
	_arrow(Vector2(6, h / 2), Vector2(-1, 0))
	_arrow(Vector2(w - 6, h / 2), Vector2(1, 0))
	_text("BOVEN", Vector2(w / 2, 70), 26, Retro.AMBER)
	# centre cross
	draw_line(Vector2(w / 2 - 40, h / 2), Vector2(w / 2 + 40, h / 2), Color(Color.WHITE, 0.6), 2.0)
	draw_line(Vector2(w / 2, h / 2 - 40), Vector2(w / 2, h / 2 + 40), Color(Color.WHITE, 0.6), 2.0)
	# which screen
	var head := Rect2(w / 2 - 520, 100, 1040, 150)
	draw_rect(head, Color(Retro.BG, 0.92))
	draw_rect(head, Retro.TEAL, false, 3.0)
	var title := "SCHERM %d / %d" % [screen_number, screen_count] if not tiles.is_empty() else "OVERZICHT"
	_text(title, Vector2(w / 2, 172), 72, Retro.TEAL)
	var info := "BEZOEKERSSCHERM"
	if not tiles.is_empty():
		info = "TEGELS " + "  ".join(tiles.map(func(id): return Retro.tile_label(id)))
	_text(info, Vector2(w / 2, 228), 30, Retro.CREAM)
	# output / node / resolution
	var win := get_window().size if get_window() else Vector2i.ZERO
	var line := "%s   NODE %s   IP %s   BEELD 1920×1080   VENSTER %d×%d" % [output, node_name,
		MqttBridge.lan_address(), win.x, win.y]
	_text(line, Vector2(w / 2, h - 236), 24, Retro.DIM)
	if wall:
		_draw_network(w, h)
		_draw_performance(w, h)
		if tiles.is_empty():
			_draw_overview(w)
		else:
			_draw_tiles(w)
	# 1 px sharpness lines (left, vertical and horizontal)
	for i in 12:
		draw_line(Vector2(30 + i * 2, h / 2 - 90), Vector2(30 + i * 2, h / 2 + 90), Color.WHITE, 1.0)
		draw_line(Vector2(70, h / 2 - 90 + i * 2), Vector2(130, h / 2 - 90 + i * 2), Color.WHITE, 1.0)
	_text("1 PX", Vector2(80, h / 2 + 120), 18, Retro.DIM)
	# colour bars and grey ramp
	var bw := (w - 240) / BARS.size()
	for i in BARS.size():
		draw_rect(Rect2(120 + i * bw, h - 200, bw, 70), BARS[i])
	var gw := (w - 240) / 11.0
	for i in 11:
		var g := i / 10.0
		draw_rect(Rect2(120 + i * gw, h - 126, gw, 54), Color(g, g, g))
		_text("%d%%" % (i * 10), Vector2(120 + (i + 0.5) * gw, h - 92), 18, Color.WHITE if g < 0.5 else Color.BLACK, false)
	# live: clock and a sweeping bar
	var sweep := fmod(_t, 2.0) / 2.0
	draw_rect(Rect2(120 + sweep * (w - 260), h - 60, 20, 30), Retro.GOOD)
	_text("%02d:%02d.%d" % [int(_t) / 60, int(_t) % 60, int(_t * 10) % 10], Vector2(w - 220, 70), 34, Retro.GOOD)


# ---------------------------------------------------------------- diagnosis

## A place's state: [text, colour] (its physical tile, from the master's diagnosis).
func _tile_state(id: int) -> Array:
	var d: Dictionary = wall.diag
	if d.is_empty():
		return ["WACHT OP MASTER" if Replica.client else "…", Retro.DIM]
	if str(d.get("broker", "")) == "":
		return ["SIMULATIE", Retro.AMBER]                 # (no MQTT: the game plays the tiles itself)
	if not d.get("mqtt", false):
		return ["GEEN BROKER", Retro.BAD]
	var t: Dictionary = d.get("tiles", {}).get(str(id), {})
	if t.is_empty():
		return ["GEEN TEGEL", Retro.AMBER]                # (no physical tile on this place: Tegels tab)
	return ["ONLINE", Retro.GOOD] if t.get("online", false) else ["OFFLINE", Retro.BAD]


func _press(id: int) -> Dictionary:
	return wall.last_press.get(id, {})


func _draw_tiles(w: float) -> void:
	var n := tiles.size()
	var gap := 20.0
	var cw := minf(440.0, (w - 320.0 - gap * (n - 1)) / n)
	var ch := 236.0
	var x0 := (w - (cw * n + gap * (n - 1))) / 2.0
	var now := Time.get_ticks_msec()
	for i in n:
		var id: int = tiles[i]
		var r := Rect2(x0 + i * (cw + gap), 284, cw, ch)
		var st := _tile_state(id)
		draw_rect(r, Color(Retro.BG, 0.94))
		draw_rect(r, st[1], false, 3.0)
		var left := r.position.x + 18
		_text_left(Retro.tile_label(id), Vector2(left, r.position.y + 36), 40, Retro.TEAL)
		_text_right(st[0], Vector2(r.end.x - 18, r.position.y + 34), 26, st[1])
		var t: Dictionary = wall.diag.get("tiles", {}).get(str(id), {})
		var y := r.position.y + 76
		if not t.is_empty():
			_text_left("TEGEL " + str(t.device).to_upper(), Vector2(left, y), 20, Retro.CREAM)
			_text_left("FW %s   IP %s" % [t.fw if t.fw != "" else "?", t.ip if t.ip != "" else "?"],
				Vector2(left, y + 28), 20, Retro.DIM)
			var link: String = ("KABEL " + str(t.link).to_upper()) if t.link != "" else "KABEL ?"
			var seen := "GEZIEN %d s" % int(t.age) if float(t.age) >= 0.0 else "NOOIT GEZIEN"
			_text_left("%s   %s" % [link, seen], Vector2(left, y + 56), 20, Retro.DIM)
		# the 4 buttons: lit when pressed (press each one: the right tile, the right button?)
		var p := _press(id)
		var bs := 46.0
		for k in CyberTile.BUTTONS.size():
			var b: StringName = CyberTile.BUTTONS[k]
			var col: Color = CyberTile.BUTTON_COLORS[b]
			var br := Rect2(left + k * (bs + 12), r.end.y - 62, bs, bs)
			var lit: bool = not p.is_empty() and p.button == b and now - int(p.msec) < LIT_MS
			draw_rect(br, col if lit else col.darkened(0.8))
			draw_rect(br, col, false, 2.0)
		if not p.is_empty():
			var name: String = Retro.BUTTON_NAMES.get(p.button, str(p.button))
			_text_left("%s %d s" % [name, (now - int(p.msec)) / 1000],
				Vector2(left + 4 * (bs + 12) + 6, r.end.y - 32), 20, Retro.CREAM)
		else:
			_text_left("DRUK!", Vector2(left + 4 * (bs + 12) + 6, r.end.y - 32), 20, Retro.DIM)


## The overview: every place of the installation at a glance, and the display nodes.
func _draw_overview(w: float) -> void:
	var ids := range(1, wall.arena.tiles.size() + 1).filter(func(id): return wall.arena.installation.is_installed(id))
	var per_row := 9
	var cw := 150.0
	var ch := 70.0
	var gap := 12.0
	var now := Time.get_ticks_msec()
	var rows := ceili(ids.size() / float(per_row))
	for i in ids.size():
		var id: int = ids[i]
		var row := i / per_row
		var in_row := mini(per_row, ids.size() - row * per_row)
		var x0 := (w - (cw * in_row + gap * (in_row - 1))) / 2.0
		var r := Rect2(x0 + (i % per_row) * (cw + gap), 284 + row * (ch + gap), cw, ch)
		var st := _tile_state(id)
		var p := _press(id)
		var lit: bool = not p.is_empty() and now - int(p.msec) < LIT_MS
		draw_rect(r, (CyberTile.BUTTON_COLORS[p.button] as Color).darkened(0.3) if lit else Color(Retro.BG, 0.94))
		draw_rect(r, st[1], false, 3.0)
		_text(Retro.tile_label(id), r.position + Vector2(cw / 2, 26), 28, Retro.TEAL)
		_text(st[0], r.position + Vector2(cw / 2, 54), 16, st[1])
	var y := 284 + rows * (ch + gap) + 30
	var unplaced: Array = wall.diag.get("unplaced", [])
	if not unplaced.is_empty():
		_text("%d TEGEL(S) ZONDER PLAATS: %s" % [unplaced.size(), "  ".join(unplaced.slice(0, 6)).to_upper()],
			Vector2(w / 2, y), 22, Retro.AMBER)
		y += 34
	var r: Replica = wall.arena.replica
	if r and Replica.server:
		var peers := r.peer_list()
		if peers.is_empty():
			_text("GEEN DISPLAY NODES VERBONDEN", Vector2(w / 2, y), 22, Retro.DIM)
		for d in peers:
			var bad: bool = float(d.get("loss", 0.0)) > 1.0 or int(d.get("rtt_ms", 0)) > 50
			_text("DISPLAY %s   SCHERMEN %s   IP %s   PING %d ms   VERLIES %.1f %%" % [str(d.node).to_upper(),
				", ".join(d.get("screens", []).map(func(k): return str(k))), d.get("host", "?"),
				int(d.get("rtt_ms", 0)), float(d.get("loss", 0.0))], Vector2(w / 2, y), 22, Retro.AMBER if bad else Retro.GOOD)
			y += 30


## The network line: the broker (the master) or the link to the master (a display node).
func _draw_network(w: float, h: float) -> void:
	var text := ""
	var col := Retro.GOOD
	if Replica.client:
		var l: Dictionary = wall.arena.replica.link() if wall.arena.replica else {}
		if not l.get("online", false):
			text = "GEEN VERBINDING MET DE MASTER %s" % l.get("master", "(zoekt via beacon)")
			col = Retro.BAD
		else:
			var last := float(l.get("last_rx_s", -1.0))
			text = "MASTER %s   PING %d ms   VERLIES %.1f %%   LAATSTE UPDATE %.1f s" % [l.master,
				int(l.get("rtt_ms", 0)), float(l.get("loss", 0.0)), last]
			if int(l.get("rtt_ms", 0)) > 50 or float(l.get("loss", 0.0)) > 1.0 or last > 2.0:
				col = Retro.AMBER
	else:
		var d: Dictionary = wall.diag
		if str(d.get("broker", "")) == "":
			text = "GEEN MQTT: DE TEGELS WORDEN GESIMULEERD"
			col = Retro.AMBER
		elif d.get("mqtt", false):
			text = "MQTT VERBONDEN %s" % d.broker
		else:
			text = "MQTT NIET VERBONDEN %s" % d.broker
			col = Retro.BAD
		if wall.arena.replica and Replica.server:
			text += "   ·   %d DISPLAY NODE(S)" % wall.arena.replica.peers.size()
	_text(text, Vector2(w / 2, h - 300), 24, col)


## The performance line: fps, frame times over the last 2 s, renderer, GPU.
func _draw_performance(w: float, h: float) -> void:
	var sum := 0.0
	var worst := 0.0
	var slow := 0
	for f in _frames:
		sum += f[1]
		worst = maxf(worst, f[1])
		if f[1] > SLOW_MS:
			slow += 1
	var avg := sum / maxi(_frames.size(), 1)
	var col := Retro.GOOD if slow == 0 else (Retro.AMBER if slow < 10 else Retro.BAD)
	var text := "FPS %d   FRAME %.1f ms (MAX %.0f)   TRAAG %d IN 2 s   %s   %s" % [
		Engine.get_frames_per_second(), avg, worst, slow,
		str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")).to_upper(),
		RenderingServer.get_video_adapter_name().to_upper().left(40)]
	_text(text, Vector2(w / 2, h - 268), 22, col)


func _text_left(s: String, pos: Vector2, font_size: int, col: Color) -> void:
	draw_string(Retro.FONT, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)


func _text_right(s: String, pos: Vector2, font_size: int, col: Color) -> void:
	var width := Retro.FONT.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(Retro.FONT, pos - Vector2(width, 0), s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)


func _arrow(tip: Vector2, dir: Vector2) -> void:
	var side := Vector2(-dir.y, dir.x)
	draw_colored_polygon(PackedVector2Array([tip, tip - dir * 40 + side * 26, tip - dir * 40 - side * 26]), Retro.AMBER)


func _text(s: String, centre: Vector2, font_size: int, col: Color, outline := true) -> void:
	var font := Retro.FONT
	var width := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var pos := centre - Vector2(width / 2, -font_size * 0.35)
	if outline:
		draw_string_outline(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 6, Color(Retro.BG, 0.9))
	draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
