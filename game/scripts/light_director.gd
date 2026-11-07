class_name LightDirector
extends Node
## The room's lighting, driven by the game. Two outputs, the same cues:
##   * the real lights: the game events and the base look go out on MQTT
##     (MqttBridge: <prefix>/light/event, retained <prefix>/light/scene); the
##     lighting system (a DMX bridge, a lighting desk) turns them into looks;
##   * the virtual lights in the room: a wash of light up each of the 16 wall
##     pillars (one MultiMesh, additive: no real lights, cheap) and the colour
##     of the ceiling ring.
## Arena.cue(event, tile) feeds the events (the same moments as the sounds).
## Scenes (the base look, from the operating mode and the game state):
##   setup, closed, lobby, intro, playing, scoreboard, paused
## Lightning: electric arcs on the big moments (the robot charging up to the
## ceiling ring, a bolt down onto a condemned tile, arcs from a zapped tile to
## the wall, an arc hopping around the pillars at a round's start) and now and
## then a crackle between two pillars. All arcs are one ImmediateMesh (one
## draw call), rebuilt each frame; their shape jumps, their light fades
## smoothly (no strobing).
## Settings (web interface, group "Licht"): brightness of the virtual lights,
## flashes on / off (also sent along in the scene for the real lights).

signal scene_changed(scene: Dictionary)

const PILLARS := 16
const PILLAR_R := 6.3                  # in front of the pillars (room.glb: Pillar_00..15 at 6.48 m)
const WASH_SIZE := Vector2(0.7, 3.5)       # on the (darker) teal pillar: the colour shows there
const MAX_FLASH_HZ := 3.0              # photosensitive epilepsy guideline: no more than 3 flashes a second
## The colour of each round type (intro, playing; also sent to the real lights).
const ROUND_COLORS := {
	"quiz": Color(0.55, 0.25, 1.0), "cyclone": Color(1.0, 0.5, 0.05), "reaction": Color(1.0, 0.15, 0.1),
	"simon": Color(0.1, 0.6, 1.0), "zwarte_piet": Color(1.0, 0.8, 0.1), "rhythm": Color(1.0, 0.2, 0.7),
}
## Base looks: colour, level (0..1), motion ("still", "breathe", "chase").
const SCENES := {
	"setup": [Color(1.0, 0.97, 0.9), 0.8, "still"],
	"closed": [Color(0.15, 0.3, 1.0), 0.25, "still"],
	"lobby": [Color(0.1, 0.85, 1.0), 0.45, "chase"],
	"intro": [Color.WHITE, 0.8, "chase"],         # (colour: the round's)
	"playing": [Color.WHITE, 0.3, "breathe"],     # (colour: the round's)
	"scoreboard": [Color(1.0, 0.75, 0.2), 0.6, "breathe"],
	"paused": [Color(1.0, 0.55, 0.1), 0.2, "still"],
}
const EVENT_COLORS := {
	"hit": Color(1.0, 0.1, 0.05), "shield": Color(0.3, 0.6, 1.0), "life": Color(0.1, 1.0, 0.3),
	"join": Color.WHITE, "leave": Color(0.3, 0.3, 0.4), "death": Color(1.0, 0.0, 0.0),
	"zap": Color(0.6, 0.8, 1.0), "explosion": Color(1.0, 0.5, 0.1), "charge": Color(1.0, 0.1, 0.05),
	"attack": Color.WHITE, "scoreboard": Color(1.0, 0.75, 0.2), "countdown": Color(1.0, 0.6, 0.1),
}

var brightness := 100                  # % of the virtual lights
var flashes := 1                       # 0: no flashing (virtual; and told to the real lights)

var arena: Node3D
var scene := {}                        # the current base look (as published)
var _wash: MultiMeshInstance3D
var _angles := PackedFloat32Array()    # each wash's angle (deg, clockwise from T01 seen from above)
var _base := Color.BLACK               # the base colour now (fading to the scene's)
var _base_level := 0.0
var _flash := []                       # [{angle (or -1: everywhere), width, color, level, decay, hold, flicker}]
var _dim := 0.0                        # 0..1: the room dimmed (an extermination)
var _dark := 0.0                       # 0..1: the room dark (the robot powering up / down) ...
var _dark_target := 0.0                # ... going there
var _dark_rate := 1.0                  # per second
var _time := 0.0
var _ring_default := Color(0.7, 0.85, 1.0)
var _bolts := []                       # [{a, b, color, life, age, width, points, next, delay}]
var _arc_mesh := ImmediateMesh.new()
var _arcs: MeshInstance3D
var _next_crackle := 3.0
var _ring_centre := Vector3(0, 8.44, 0)
const RING_R := 0.96                   # the ceiling ring (room.glb: Ceiling_Ring)
const PILLAR_TOP := 3.3                # crackles run between the pillars up here


func setup(arena_node: Node3D) -> void:
	arena = arena_node
	_ring_default = arena.room.ring_color
	_build_washes()
	_build_arcs()
	arena.game.state_changed.connect(func(_s): _update_scene())
	arena.game.mode_changed.connect(func(_m): _update_scene())
	_update_scene()


## The settings for the web interface (as GameRound.tunables).
func tunables() -> Array:
	return [
		GameRound.setting("brightness", "Achtergrondlicht in het spel (%)", 0, 100, 5),
		GameRound.setting("flashes", "Flitsen (0 = uit, ook voor de echte lampen)", 0, 1, 1),
	]


## A game event (Arena.cue): the virtual lights react. `data` has "tile" and
## "angle" for an event at a tile.
func on_cue(event: StringName, data: Dictionary) -> void:
	var at: float = data.get("angle", -1.0)
	var color: Color = Color(data.color) if data.has("color") else EVENT_COLORS.get(String(event), Color.WHITE)
	match event:
		&"hit", &"shield", &"life", &"join":
			_add(at, 50.0, color, 1.0, 2.5)
		&"leave":
			_add(at, 50.0, color, 0.6, 1.5)
		&"registered":                         # the player's colour, while they look for their tile
			_add(at, 40.0, color, 1.0, 0.5, 3.0)
		&"charge":
			_add(-1.0, 0.0, color, 0.5, 2.0)
			for i in 3:                         # the robot charges from the ceiling ring
				var a := randf() * TAU
				_bolt(_robot_top(), _ring_centre + Vector3(cos(a), 0, sin(a)) * RING_R, color.lightened(0.4), 0.6, 0.05, i * 0.08)
		&"attack":
			_add(-1.0, 0.0, color, 1.0 if flashes else 0.4, 6.0)
		&"death":
			_dim = 1.0
			_add(at, 35.0, color, 1.0, 0.3, 3.0)
			if data.has("tile"):                # judgement from above
				var t := _tile_pos(int(data.tile))
				_bolt(_ring_centre + Vector3(RING_R, 0, 0), t, Color(1.0, 0.3, 0.3), 0.9, 0.07)
				_bolt(_ring_centre - Vector3(RING_R, 0, 0), t, Color(1.0, 0.85, 0.85), 0.7, 0.04, 0.15)
		&"zap":
			_add(at, 45.0, color, 1.0, 1.0, 1.0, flashes == 1)
			if data.has("tile"):                # arcs from the tile to the nearest pillars
				var t := _tile_pos(int(data.tile))
				for k in _nearest_pillars(at, 2):
					_bolt(t, _pillar_point(k, 1.2), color, 1.0, 0.04)
		&"explosion":
			_add(at, 70.0, color, 1.0, 1.2)
			_add(-1.0, 0.0, color, 0.5, 2.0)
			if data.has("tile"):                # short arcs over the floor
				var t := _tile_pos(int(data.tile))
				for i in 5:
					var a := randf() * TAU
					_bolt(t, t + Vector3(cos(a), 0.0, sin(a)) * randf_range(1.0, 2.0), Color(1.0, 0.75, 0.4), 0.35, 0.03)
		&"round_start", &"scoreboard":
			_add(-1.0, 0.0, _scene_color(), 0.8, 1.5)
			if event == &"round_start":         # an arc hops around the room, pillar to pillar
				var c := _scene_color().lightened(0.3)
				for k in PILLARS:
					_bolt(_pillar_point(k, PILLAR_TOP), _pillar_point((k + 1) % PILLARS, PILLAR_TOP), c, 0.25, 0.04, k * 0.06)
		&"countdown":
			_add(-1.0, 0.0, color, 0.5, 4.0)
		&"boot":                                 # the robot comes to life: dark, then power from the ceiling
			_dark = 1.0
			_dark_target = 0.0
			_dark_rate = 1.0 / 13.0
			for i in 6:
				var a := randf() * TAU
				_bolt(_ring_centre + Vector3(cos(a), 0, sin(a)) * RING_R, _robot_top(), Color(0.5, 0.8, 1.0), 0.5, 0.05, 1.5 + i * 0.6)
		&"boot_done":                            # awake: a flash, an arc around the room
			_dark_target = 0.0
			_dark_rate = 2.0
			_add(-1.0, 0.0, Color(0.6, 0.85, 1.0), 1.0 if flashes else 0.5, 1.5)
			for k in PILLARS:
				_bolt(_pillar_point(k, PILLAR_TOP), _pillar_point((k + 1) % PILLARS, PILLAR_TOP), Color(0.6, 0.85, 1.0), 0.3, 0.05, k * 0.04)
		&"shutdown":                             # the players' last attack: lightning from every pillar
			for k in PILLARS:
				_bolt(_pillar_point(k, 1.5), _robot_top(), Color(0.3, 1.0, 0.4), 0.8, 0.06, k * 0.08)
			_add(-1.0, 0.0, Color(0.3, 1.0, 0.4), 1.0 if flashes else 0.4, 0.8, 1.0, flashes == 1)
		&"power_down":                           # dying: the room goes dark with it
			_dark_target = 0.85
			_dark_rate = 1.0 / 4.0
		&"off":                                  # a last spark; then the closed look comes back slowly
			_bolt(_robot_top(), _robot_top() + Vector3(0.6, 0.8, 0.2), Color(0.9, 0.95, 1.0), 0.25, 0.03)
			_dark_target = 0.0
			_dark_rate = 1.0 / 6.0


func _add(angle: float, width: float, color: Color, level: float, decay: float, hold := 0.0, flicker := false) -> void:
	_flash.append({"angle": angle, "width": width, "color": color, "level": level, "decay": decay,
		"hold": hold, "flicker": flicker})


# ---------------------------------------------------------------- lightning

func _build_arcs() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = false
	_arcs = MeshInstance3D.new()
	_arcs.name = "Lightning"
	_arcs.mesh = _arc_mesh
	_arcs.material_override = mat
	_arcs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	arena.add_child(_arcs)
	var ring := arena.room.find_child("Ceiling_Ring", true, false) as Node3D
	if ring:
		_ring_centre = ring.global_position


## An arc from a to b (arena space), `life` s, starting after `delay` s.
func _bolt(a: Vector3, b: Vector3, color: Color, life: float, width: float, delay := 0.0) -> void:
	if brightness <= 0:
		return
	_bolts.append({"a": a, "b": b, "color": color, "life": life, "age": -delay, "width": width,
		"points": PackedVector3Array(), "next": 0.0})


func _robot_top() -> Vector3:
	return arena.robot.head.global_position + Vector3(0, 0.35, 0)


func _tile_pos(tile_id: int) -> Vector3:
	return arena.tiles[tile_id - 1].global_position + Vector3(0, 0.1, 0)


func _pillar_point(k: int, y: float) -> Vector3:
	var a := TAU * k / PILLARS + PI / PILLARS
	return Vector3(PILLAR_R * cos(a), y, -PILLAR_R * sin(a))


func _nearest_pillars(angle: float, n: int) -> Array:
	var ks := range(PILLARS)
	ks.sort_custom(func(x, y): return absf(angle_diff(_angles[x], angle)) < absf(angle_diff(_angles[y], angle)))
	return ks.slice(0, n)


## A jagged line from a to b: midpoint displacement, sideways ~12 % of its length.
static func _jag(a: Vector3, b: Vector3) -> PackedVector3Array:
	var pts := PackedVector3Array([a, b])
	var amp := a.distance_to(b) * 0.12
	for level in 4:
		var out := PackedVector3Array()
		for i in pts.size() - 1:
			out.append(pts[i])
			var m := (pts[i] + pts[i + 1]) * 0.5
			out.append(m + Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * amp)
		out.append(pts[-1])
		pts = out
		amp *= 0.5
	return pts


func _draw_arcs(delta: float) -> void:
	_arc_mesh.clear_surfaces()
	if not _bolts.any(func(b): return b.age + delta >= 0.0):   # (none yet: only delayed ones)
		for b in _bolts:
			b.age += delta
		return
	_arc_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for bolt in _bolts:
		bolt.age += delta
		if bolt.age < 0.0:
			continue
		bolt.next -= delta
		if bolt.next <= 0.0:                    # a new shape ~20x a second
			bolt.next = 0.05
			bolt.points = _jag(bolt.a, bolt.b)
		var k: float = 1.0 - bolt.age / bolt.life
		var c: Color = bolt.color * (k * 1.6) * (brightness / 100.0)
		var pts: PackedVector3Array = bolt.points
		var dir: Vector3 = (bolt.b - bolt.a).normalized()
		var s1: Vector3 = dir.cross(Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT).normalized() * bolt.width
		var s2: Vector3 = dir.cross(s1).normalized() * bolt.width
		for side in [s1, s2]:                   # two crossed ribbons: visible from every screen
			for i in pts.size() - 1:
				var p0 := pts[i]
				var p1 := pts[i + 1]
				for v in [p0 - side, p0 + side, p1 + side, p0 - side, p1 + side, p1 - side]:
					_arc_mesh.surface_set_color(c)
					_arc_mesh.surface_add_vertex(v)
	_arc_mesh.surface_end()
	_bolts = _bolts.filter(func(b): return b.age < b.life)


func _crackle(delta: float) -> void:
	if flashes == 0 or not scene.get("scene", "") in ["lobby", "intro", "playing"]:
		return
	_next_crackle -= delta
	if _next_crackle > 0.0:
		return
	_next_crackle = randf_range(4.0, 10.0)
	var k := randi() % PILLARS
	var c := _scene_color().lightened(0.5)
	_bolt(_pillar_point(k, PILLAR_TOP), _pillar_point((k + 1) % PILLARS, PILLAR_TOP - randf_range(0.0, 0.6)), c, 0.3, 0.03)
	_add(_angles[k], 30.0, c, 0.5, 2.0)


# ---------------------------------------------------------------- the base look

func _update_scene() -> void:
	var game: GameManager = arena.game
	var name: String
	match game.mode:
		GameManager.Mode.SETUP: name = "setup"
		GameManager.Mode.CLOSED: name = "closed"
		GameManager.Mode.PAUSED: name = "paused"
		_: name = ["lobby", "intro", "playing", "scoreboard"][game.state]
	var round_type := ""
	if name in ["intro", "playing"] and game.current:
		round_type = game.round_type_name(game.current.get_script())
	var s := {"scene": name, "round": round_type, "color": "#" + _scene_color(name, round_type).to_html(false),
		"flashes": flashes == 1}
	if s != scene:
		scene = s
		scene_changed.emit(scene)


func _scene_color(name := "", round_type := "") -> Color:
	if name == "":
		name = scene.get("scene", "closed")
		round_type = scene.get("round", "")
	if name in ["intro", "playing"] and ROUND_COLORS.has(round_type):
		return ROUND_COLORS[round_type]
	return SCENES[name][0]


## Settings changed: the scene carries the flash setting.
func refresh() -> void:
	if arena:
		_update_scene()


# ---------------------------------------------------------------- the virtual lights

func _build_washes() -> void:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;
void fragment() {
	float up = 1.0 - UV.y;                                  // 0 at the floor
	float across = 1.0 - pow(abs(UV.x * 2.0 - 1.0), 2.0);   // soft sides
	float fall = pow(1.0 - up, 1.6) * across;               // bright low, fading up the wall
	float spot = smoothstep(0.12, 0.0, up) * smoothstep(0.35, 0.0, abs(UV.x - 0.5));   // the fixture
	float beam = smoothstep(0.18, 0.0, abs(UV.x - 0.5)) * (1.0 - up * 0.6);   // a bright core up the pillar
	ALBEDO = COLOR.rgb * (fall * 2.0 + beam * 1.5 + spot * 4.0);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var quad := QuadMesh.new()
	quad.size = WASH_SIZE
	quad.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = PILLARS
	for k in PILLARS:
		var a := TAU * k / PILLARS + PI / PILLARS             # (assets/blender/build_models.py: the wall corners)
		var p := Vector3(PILLAR_R * cos(a), WASH_SIZE.y / 2.0 + 0.02, -PILLAR_R * sin(a))
		var t := Transform3D(Basis.IDENTITY, p).looking_at(Vector3(0, p.y, 0), Vector3.UP, true)
		mm.set_instance_transform(k, t)
		mm.set_instance_color(k, Color.BLACK)
		_angles.append(angle_of(p))
	_wash = MultiMeshInstance3D.new()
	_wash.name = "PillarWashes"
	_wash.multimesh = mm
	_wash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	arena.room.add_child(_wash)


## The angle of a point (deg, clockwise from T01 seen from above): the same
## numbers as "angle" in the light events.
static func angle_of(p: Vector3) -> float:
	return fposmod(rad_to_deg(atan2(p.x, -p.z)), 360.0)


func _process(delta: float) -> void:
	if arena == null:
		return
	_time += delta
	var look: Array = SCENES[scene.get("scene", "closed")]
	var fade := 1.0 - exp(-delta * 3.0)                        # base look changes over ~0.5 s
	_base = _base.lerp(_scene_color(), fade)
	_base_level = lerpf(_base_level, look[1], fade)
	_dim = maxf(_dim - delta / 3.0, 0.0)
	_dark = move_toward(_dark, _dark_target, _dark_rate * delta)
	for f in _flash:
		if f.hold > 0.0:
			f.hold -= delta
		else:
			f.level -= f.decay * delta
	_flash = _flash.filter(func(f): return f.level > 0.0)
	var gain := brightness / 100.0
	var global := Color.BLACK                                 # flashes everywhere (for the ring too)
	for k in PILLARS:
		var level: float = _base_level
		match look[2]:
			"breathe":
				level *= 0.75 + 0.25 * sin(_time * 1.6)
			"chase":                                           # a brighter spot running around
				var speed := 45.0 if scene.get("scene") == "lobby" else 240.0
				var d := absf(angle_diff(_angles[k], fposmod(_time * speed, 360.0)))
				level *= 0.6 + 0.9 * clampf(1.0 - d / 60.0, 0.0, 1.0)
		var c := _base * level * (1.0 - 0.85 * _dim)
		for f in _flash:
			var w: float = f.level
			if f.flicker and fmod(_time * MAX_FLASH_HZ, 1.0) > 0.5:
				w *= 0.15
			if f.angle >= 0.0:
				w *= clampf(1.0 - absf(angle_diff(_angles[k], f.angle)) / f.width, 0.0, 1.0)
			elif k == 0:
				global += f.color * w
			c += f.color * w
		_wash.multimesh.set_instance_color(k, c * gain * (1.0 - _dark))
	_crackle(delta)
	_draw_arcs(delta)
	arena.room.set_ring_color(((_ring_default.lerp(_base, 0.3) * (1.0 - 0.6 * _dim) + global * 0.5) * (1.0 - _dark)).clamp())


static func angle_diff(a: float, b: float) -> float:
	return fposmod(a - b + 180.0, 360.0) - 180.0
