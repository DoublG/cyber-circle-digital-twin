class_name CyberTile
extends Node3D
## Digital twin of one Cyber Circle floor tile ("tegel").
## Wraps models/tile.glb and exposes the same things the real tile has:
## 48-LED ring, 5-heart health bar (lives), and a glass plate with 4 etched
## button icons, each lit by an RGB LED and read by a pressure sensor.
## Forward (-Z) points at the robot.
## Tile states:
##   idle     no player: attract animation
##   pending  a player registered (QR scan) and must press all 4 icons to
##            activate; pressed icons stay lit, the ring fills a quarter each
##   playing  idle = false and pending = false: the game drives the LEDs and
##            the hearts show lives
##   setup    (the game in SETUP) the hearts show the place number in binary -
##            Heart_0 (nearest the logo) = 1, Heart_1 = 2, ... Heart_4 = 16 - so
##            the crew sees that every tile stands on the right place

signal button_pressed(tile_id: int, button: StringName)
signal button_released(tile_id: int, button: StringName)
signal pressure_changed(tile_id: int, button: StringName, value: float)
signal died(tile_id: int)   # health went from >0 to 0
signal health_changed(tile_id: int, health: int)
## A one-off effect, for the real tile (MqttBridge: tile/<n>/cmd {"fx": name, "color"}):
## attack, hit, block, life, doomed, death.
signal fx(tile_id: int, name: String, color: Color)

const TILE_SCENE := preload("res://models/tile.glb")
const LED_COUNT := 48           # LED_00 faces the robot, counting clockwise from above
const HEART_COUNT := 5          # Heart_0 nearest the logo
const BUTTONS: Array[StringName] = [&"Square", &"Triangle", &"Cross", &"Circle"]
const BUTTON_COLORS := {
	&"Square": Color(1.0, 0.35, 0.75),
	&"Triangle": Color(0.2, 1.0, 0.4),
	&"Cross": Color(0.3, 0.5, 1.0),
	&"Circle": Color(1.0, 0.15, 0.15),
}
const HEART_COLOR := Color(1.0, 0.05, 0.15)
const HEART_LOST_COLOR := Color(0.12, 0.0, 0.02)   # lost life: dim red; not in play: off
const OFF_COLOR := Color(0.15, 0.15, 0.15)
const SYMBOL_OFF_COLOR := Color(0.85, 0.85, 0.85)
const SHIELD_COLOR := Color(0.3, 0.75, 1.0)
const SHIELD_SHADER := preload("res://shaders/shield.gdshader")
const LED_SHADER := preload("res://shaders/led.gdshader")

@export var tile_id := 1
@export_range(0.0, 1.0) var press_threshold := 0.3  # normalised sensor value = "pressed"
@export_range(1, HEART_COUNT) var max_health := HEART_COUNT  # lives this player started with (age)
@export_range(0, HEART_COUNT) var health := HEART_COUNT: set = set_health
@export var idle := true: set = set_idle   # no player on this tile
## Out of service (taken out of the game during setup or play): all dark,
## status LED red, no idle animation.
@export var out_of_service := false: set = set_out_of_service

var _model: Node3D
var _ring: MultiMesh                 # the 48 ring LEDs: one draw call (instance colour = LED)
var _ring_colors: Array[Color] = []
var _hearts: Array[MeshInstance3D] = []
var _anchors := {}       # button -> Node3D at the icon centre on the glass
var _pressure := {}      # button -> float 0..1
var _clicked: StringName = &""
var _button_leds := {}   # button -> symbol MeshInstance3D (RGB LED below it)
var _status_led: MeshInstance3D
var is_dead := false
var _doomed := false     # exterminated, blinking red until the death animation
var _idle_time := 0.0
var pending := false
var _activation_pressed: Array[StringName] = []
var _activation_color := Color.WHITE
var _button_colors := {}          # button -> the colour its LED shows now (display_state)
var show_number := false: set = set_show_number   # setup: the hearts show tile_id in binary
## Protected (e.g. the question is too hard for the player's age): attacks are
## blocked. Twin: energy dome over the tile. Real tile: the LED ring glows blue.
var shielded := false: set = set_shielded
var _fx_root: Node3D = null      # see _fx_node()
var installed := true            # false: this place is not part of the installation (hidden, never used)
var _shield: MeshInstance3D
var _shield_mat: ShaderMaterial
var _shield_tween: Tween


func _ready() -> void:
	# the scene has the model as child "Model" (visible in the editor);
	# fall back to instancing it when the script is used on its own
	_model = get_node_or_null("Model")
	if _model == null:
		_model = TILE_SCENE.instantiate()
		add_child(_model)
	_build_ring()
	for i in HEART_COUNT:
		_hearts.append(_led("Heart_%d" % i))
	for b in BUTTONS:
		var anchor := _model.find_child("Button_%s" % b, true, false) as Node3D
		_anchors[b] = anchor
		_pressure[b] = 0.0
		_button_leds[b] = _led("Button_%s_Symbol" % b, SYMBOL_OFF_COLOR)
		_button_leds[b].cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_add_click_area(b, anchor)
	_status_led = _led("Status_LED")
	_build_shield()
	if not (self is DroneTile):
		_contact_shadow()
	_idle_time = randf() * 10.0  # tiles don't animate in lockstep
	clear_ring()
	set_health(health)
	set_status(Color(0.1, 1.0, 0.2))
	set_idle(idle)


func _process(delta: float) -> void:
	if out_of_service:
		return
	if pending:
		_idle_time += delta
		_run_pending_animation()
	elif idle:
		_idle_time += delta
		_run_idle_animation()


# ---------------------------------------------------------------- activation

## A player registered on this tile: light it up in their colour and wait
## for all 4 icons.
func start_activation(color := Color.WHITE) -> void:
	pending = true
	_activation_color = color
	_activation_pressed.clear()
	for h in _hearts:
		_paint(h, Color.BLACK)


## The icons pressed so far during activation (the invite on the screen greys them out).
func activation_pressed() -> Array[StringName]:
	return _activation_pressed


## Registers one press during activation; returns true once all 4 were pressed.
func activation_press(button: StringName) -> bool:
	if pending and button not in _activation_pressed:
		_activation_pressed.append(button)
	return _activation_pressed.size() == BUTTONS.size()


func cancel_activation() -> void:
	pending = false


func _run_pending_animation() -> void:
	var t := _idle_time
	# the ring pulses in the player's colour; each pressed icon fills its quarter
	for i in LED_COUNT:
		var quarter := BUTTONS[i * BUTTONS.size() / LED_COUNT]
		if quarter in _activation_pressed:
			set_ring_led(i, _activation_color)
		else:
			set_ring_led(i, _activation_color * (0.2 + 0.25 * (1.0 + sin(t * 5.0 - i * 0.3))))
	# pressed icons stay lit, the others blink
	var blink := 1.0 if fmod(t, 0.8) < 0.4 else 0.15
	for b in BUTTONS:
		set_button_led(b, BUTTON_COLORS[b] * (1.0 if b in _activation_pressed else blink))
	set_status(_activation_color)


func set_out_of_service(on: bool) -> void:
	out_of_service = on
	if _ring == null:  # not built yet; _ready() applies it
		return
	if on:
		clear_ring()
		for b in BUTTONS:
			set_button_led(b, Color.BLACK)
		for h in _hearts:
			_paint(h, Color.BLACK)
		set_status(Color(1.0, 0.1, 0.05))
	else:
		set_idle(idle)


# ---------------------------------------------------------------- idle

## Idle = no player: attract animation. Leaving idle hands the LEDs to the game.
func set_idle(on: bool) -> void:
	idle = on
	pending = false
	if on:
		shielded = false
	if _ring == null:  # not built yet; _ready() applies it
		return
	if on:
		for h in _hearts:
			_paint(h, Color.BLACK)
		if show_number:                # (setup: the number stays on the hearts)
			set_show_number(true)
	else:
		clear_ring()
		for b in BUTTONS:
			set_button_led(b, BUTTON_COLORS[b])
		set_status(Color(0.1, 1.0, 0.2))
		set_health(health)


func _run_idle_animation() -> void:
	var t := _idle_time
	# slow rainbow that breathes around the ring
	for i in LED_COUNT:
		var hue := fmod(float(i) / LED_COUNT + t * 0.08, 1.0)
		var v := 0.25 + 0.2 * sin(t * 1.4 + i * 0.26)
		set_ring_led(i, Color.from_hsv(hue, 0.85, v))
	# the icons light up one after another in their own colour
	var active := int(t * 1.2) % BUTTONS.size()
	for k in BUTTONS.size():
		var b := BUTTONS[k]
		var fade := clampf(1.0 - fmod(t * 1.2, 1.0) * 1.5, 0.0, 1.0) if k == active else 0.0
		set_button_led(b, BUTTON_COLORS[b] * fade)
	# status LED: slow blue pulse = "waiting for a player"
	set_status(Color(0.1, 0.3, 1.0) * (0.4 + 0.4 * sin(t * 2.0)))


# ---------------------------------------------------------------- LEDs

func set_ring_led(index: int, color: Color) -> void:
	index = posmod(index, LED_COUNT)
	_ring_colors[index] = color
	var on := color.v > 0.01
	_ring.set_instance_color(index, Color(color.r, color.g, color.b, 1.0) if on else Color(0, 0, 0, 0))


## colors: up to LED_COUNT entries, starting at LED_00.
func set_ring(colors: Array) -> void:
	for i in mini(colors.size(), LED_COUNT):
		set_ring_led(i, colors[i])


## Current colours of the 48 ring LEDs (e.g. to mirror them on a screen).
func get_ring_colors() -> Array[Color]:
	return _ring_colors.duplicate()


func fill_ring(color: Color) -> void:
	for i in LED_COUNT:
		set_ring_led(i, color)


## The ring LEDs of tile.glb (LED_00..47) replaced by one MultiMesh.
func _build_ring() -> void:
	var leds: Array[MeshInstance3D] = []
	for i in LED_COUNT:
		var mi := _model.find_child("LED_%02d" % i, true, false) as MeshInstance3D
		assert(mi != null, "tile.glb is missing node LED_%02d" % i)
		leds.append(mi)
	_ring = MultiMesh.new()
	_ring.transform_format = MultiMesh.TRANSFORM_3D
	_ring.use_colors = true
	_ring.mesh = leds[0].mesh
	_ring.instance_count = LED_COUNT
	var to_tile := global_transform.affine_inverse()
	for i in LED_COUNT:
		_ring.set_instance_transform(i, to_tile * leds[i].global_transform)
		leds[i].queue_free()
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Ring_LEDs"
	mmi.multimesh = _ring
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = LED_SHADER
	mat.set_shader_parameter("off_color", OFF_COLOR)
	mmi.material_override = mat
	add_child(mmi)
	_ring_colors.resize(LED_COUNT)
	_ring_colors.fill(Color.BLACK)


func clear_ring() -> void:
	fill_ring(Color.BLACK)


func set_show_number(on: bool) -> void:
	show_number = on
	if _hearts.is_empty():
		return
	if on:
		for i in HEART_COUNT:
			_paint(_hearts[i], HEART_COLOR if tile_id >> i & 1 else HEART_LOST_COLOR)
	elif idle:
		for h in _hearts:
			_paint(h, Color.BLACK)
	else:
		set_health(health)


func set_health(value: int) -> void:
	var was := health
	health = clampi(value, 0, max_health)
	if _hearts.is_empty():  # not built yet; _ready() applies it
		return
	if not idle:
		for i in HEART_COUNT:
			var c := Color.BLACK
			if i < health:
				c = HEART_COLOR
			elif i < max_health:
				c = HEART_LOST_COLOR
			_paint(_hearts[i], c)
	if health != was:
		health_changed.emit(tile_id, health)
	if was > 0 and health == 0 and not is_dead and not idle:
		is_dead = true
		died.emit(tile_id)


## Death effect on the tile: red wipe around the ring, blinking, then dark.
## Exterminated, waiting for the robot: the whole ring blinks red (until play_death).
func blink_doomed() -> void:
	fx.emit(tile_id, "doomed", Color.RED)
	is_dead = true
	shielded = false
	_doomed = true
	var on := true
	while _doomed:
		fill_ring(Color.RED if on else Color.BLACK)
		for b in BUTTONS:
			set_button_led(b, Color.RED if on else Color.BLACK)
		on = not on
		await get_tree().create_timer(0.25).timeout


func play_death() -> void:
	fx.emit(tile_id, "death", Color.RED)
	_doomed = false
	is_dead = true
	shielded = false
	await _electrocute(1.0)
	_explode()
	for i in LED_COUNT:
		set_ring_led(i, Color.RED)
		await get_tree().create_timer(0.012).timeout
	for n in 3:
		fill_ring(Color.BLACK)
		await get_tree().create_timer(0.15).timeout
		fill_ring(Color.RED)
		await get_tree().create_timer(0.15).timeout
	for b in BUTTONS:
		set_button_led(b, Color.BLACK)
	var fade := create_tween()
	fade.tween_method(func(v: float): fill_ring(Color(v, 0, 0)), 1.0, 0.0, 1.0)
	await fade.finished
	set_status(Color.RED)


## Death part 1: lightning arcs jitter over the glass (blue-white ribbons),
## a flickering blue light and the ring flashing.
func _electrocute(seconds: float) -> void:
	var glass_y: float = (_anchors[BUTTONS[0]] as Node3D).position.y + 0.004
	var mesh := ImmediateMesh.new()
	var arcs := MeshInstance3D.new()
	arcs.mesh = mesh
	arcs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.75, 0.9, 1.0)
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	arcs.material_override = mat
	add_child(arcs)
	var light := OmniLight3D.new()
	light.light_color = Color(0.5, 0.75, 1.0)
	light.omni_range = 2.0
	light.position = Vector3(0, glass_y + 0.25, 0)
	add_child(light)
	var t := 0.0
	while t < seconds:
		mesh.clear_surfaces()
		mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		for n in 4:
			_bolt(mesh, Vector3(0, glass_y, 0), Vector2.from_angle(randf() * TAU) * 0.33, glass_y)
		mesh.surface_end()
		light.light_energy = randf_range(1.0, 5.0)
		fill_ring(Color(0.6, 0.85, 1.0) if randf() < 0.5 else Color.BLACK)
		await get_tree().create_timer(0.05).timeout
		t += 0.05
	arcs.queue_free()
	light.queue_free()


## One jagged lightning ribbon on the glass, from the centre to the rim.
func _bolt(mesh: ImmediateMesh, from: Vector3, to_xz: Vector2, y: float) -> void:
	var to := Vector3(to_xz.x, y, to_xz.y)
	var prev := from
	var steps := 7
	for i in range(1, steps + 1):
		var p := from.lerp(to, float(i) / steps)
		if i < steps:
			p += Vector3(randf_range(-0.05, 0.05), 0, randf_range(-0.05, 0.05))
		var dir := (p - prev).normalized()
		var side := dir.cross(Vector3.UP) * 0.008
		for v in [prev - side, prev + side, p + side, prev - side, p + side, p - side]:
			mesh.surface_add_vertex(v)
		prev = p


## Death part 2: small explosion - orange flash, sparks and a puff of smoke.
func _explode() -> void:
	var y: float = (_anchors[BUTTONS[0]] as Node3D).position.y + 0.05
	_flash(Color(1.0, 0.7, 0.4), 12.0, 4.5, 0.08, 0.8, y + 0.4)   # white-hot, then orange in the glow
	_glow_ball(Color(1.0, 0.95, 0.8), 0.15, 1.2, 0.3, y + 0.25)   # the white core
	_glow_ball(Color(1.0, 0.45, 0.05), 0.3, 2.0, 0.8, y + 0.35)   # the fireball
	_shockwave(Color(1.0, 0.5, 0.1), 2.6, 0.7, y)
	_debris(30, 0.08, 1.0, 0.35, y)                      # the tile breaks: chunks rain down

	var sparks := CPUParticles3D.new()
	sparks.position = Vector3(0, y, 0)
	sparks.one_shot = true
	sparks.amount = 120
	sparks.lifetime = 1.1
	sparks.explosiveness = 1.0
	sparks.direction = Vector3.UP
	sparks.spread = 80.0
	sparks.initial_velocity_min = 2.5
	sparks.initial_velocity_max = 6.0
	sparks.gravity = Vector3(0, -9.8, 0)
	var spark_mesh := SphereMesh.new()
	spark_mesh.radius = 0.022
	spark_mesh.height = 0.044
	var spark_mat := StandardMaterial3D.new()
	spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_mat.vertex_color_use_as_albedo = true
	spark_mesh.material = spark_mat
	sparks.mesh = spark_mesh
	var fire := Gradient.new()
	fire.set_color(0, Color(1.0, 0.95, 0.6))
	fire.set_color(1, Color(1.0, 0.25, 0.0))
	sparks.color_ramp = fire
	_fx_node().add_child(sparks)
	sparks.emitting = true

	var smoke := CPUParticles3D.new()
	smoke.position = Vector3(0, y, 0)
	smoke.one_shot = true
	smoke.amount = 24
	smoke.lifetime = 2.0
	smoke.explosiveness = 0.85
	smoke.direction = Vector3.UP
	smoke.spread = 35.0
	smoke.initial_velocity_min = 0.3
	smoke.initial_velocity_max = 0.8
	smoke.gravity = Vector3(0, 0.2, 0)
	var puff := QuadMesh.new()
	puff.size = Vector2(0.5, 0.5)
	var puff_mat := StandardMaterial3D.new()
	puff_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	puff_mat.vertex_color_use_as_albedo = true
	var soft := GradientTexture2D.new()        # round, soft-edged puff
	soft.fill = GradientTexture2D.FILL_RADIAL
	soft.fill_from = Vector2(0.5, 0.5)
	soft.fill_to = Vector2(0.5, 0.0)
	var edge := Gradient.new()
	edge.set_color(0, Color(1, 1, 1, 1))
	edge.set_color(1, Color(1, 1, 1, 0))
	soft.gradient = edge
	puff_mat.albedo_texture = soft
	puff.material = puff_mat
	smoke.mesh = puff
	var grey := Gradient.new()
	grey.set_color(0, Color(0.35, 0.33, 0.32, 0.8))
	grey.set_color(1, Color(0.2, 0.2, 0.2, 0.0))
	smoke.color_ramp = grey
	var grow := Curve.new()
	grow.add_point(Vector2(0, 0.4))
	grow.add_point(Vector2(1, 1.6))
	smoke.scale_amount_curve = grow
	_fx_node().add_child(smoke)
	smoke.emitting = true
	get_tree().create_timer(2.5).timeout.connect(func():
		sparks.queue_free()
		smoke.queue_free())


## Debris (one draw call) from this tile, landing on the floor around it.
func _debris(count: int, size: float, speed: float, hot: float, y: float) -> void:
	var parent := get_parent() as Node3D
	Debris.spawn(parent, parent.to_local(to_global(Vector3(0, y, 0))), count, size, speed, hot)


## A soft dark disc on the floor under the tile: it stands on the floor (the
## baked room has no tile shadows, so a place that is not installed leaves no
## dark spot - bake_models.py), and it goes when the tile is hidden.
static var _shadow_mat: StandardMaterial3D

func _contact_shadow() -> void:
	if _shadow_mat == null:
		_shadow_mat = StandardMaterial3D.new()
		_shadow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_shadow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_shadow_mat.albedo_color = Color(0, 0, 0, 0.85)
		_shadow_mat.albedo_texture = _soft_texture([0.0, 0.66, 0.78, 1.0], [1.0, 0.9, 0.45, 0.0])
	var quad := QuadMesh.new()
	quad.size = Vector2(0.98, 0.98)                  # the tile is 0.70 across: a soft edge round it
	quad.orientation = PlaneMesh.FACE_Y
	quad.material = _shadow_mat
	var mi := MeshInstance3D.new()
	mi.name = "ContactShadow"
	mi.mesh = quad
	mi.position.y = 0.003
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


## Where the effects go (flash, fireball, sparks, ...): this tile, or an
## anchor in the room standing where it is (a drone hides itself right after
## its explosion, which would hide them too).
func _fx_node() -> Node3D:
	return _fx_root if is_instance_valid(_fx_root) else self


## Where a shot from the robot hits the shield (tile space): the dome's robot
## side (-Z). DroneTile: its bubble.
func _shield_impact() -> Vector3:
	return _shield.position + Vector3(0, 0.9, -0.45)


## Sparks bouncing off the shield, back towards the robot (one draw call).
func _deflect_sparks(at: Vector3) -> void:
	var sparks := CPUParticles3D.new()
	sparks.position = at
	sparks.one_shot = true
	sparks.amount = 36
	sparks.lifetime = 0.6
	sparks.explosiveness = 1.0
	sparks.direction = (to_local(Vector3(0, global_position.y + 1.5, 0)) - at).normalized()   # (the robot)
	sparks.spread = 55.0
	sparks.initial_velocity_min = 2.0
	sparks.initial_velocity_max = 4.5
	sparks.gravity = Vector3(0, -6.0, 0)
	var m := SphereMesh.new()
	m.radius = 0.014
	m.height = 0.028
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.7, 0.9, 1.0)
	m.material = mat
	sparks.mesh = m
	_fx_node().add_child(sparks)
	sparks.emitting = true
	get_tree().create_timer(1.0).timeout.connect(sparks.queue_free)


## A short bright light: full `energy` for `hold` s, then out in `fade` s
## (at height y, or at `at` when given).
func _flash(color: Color, energy: float, light_range: float, hold: float, fade: float, y: float, at = null) -> void:
	var flash := OmniLight3D.new()
	flash.light_color = color
	flash.omni_range = light_range
	flash.light_energy = energy
	flash.shadow_enabled = false
	flash.position = at if at != null else Vector3(0, y, 0)
	_fx_node().add_child(flash)
	var t := flash.create_tween()
	t.tween_interval(hold)
	t.tween_property(flash, "light_energy", 0.0, fade).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	t.tween_callback(flash.queue_free)


## A soft glowing ball (always facing the camera) that grows from `r0` to
## `r1` m across and fades out: a fireball, an impact. Additive, so it shows
## also where real lights do not (the baked room).
func _glow_ball(color: Color, r0: float, r1: float, seconds: float, y: float) -> void:
	_glow_ball_at(color, r0, r1, seconds, Vector3(0, y, 0))


func _glow_ball_at(color: Color, r0: float, r1: float, seconds: float, at: Vector3) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mat := _additive(color, _soft_texture([0.0, 0.35, 1.0], [1.0, 0.6, 0.0]))
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.material = mat
	_grow_and_fade(quad, mat, color, r0, r1, seconds, at)


## A bright ring that runs out flat over the floor to `r1` m across.
func _shockwave(color: Color, r1: float, seconds: float, y: float) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.orientation = PlaneMesh.FACE_Y
	var mat := _additive(color, _soft_texture([0.0, 0.7, 0.88, 1.0], [0.0, 0.0, 1.0, 0.0]))
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	quad.material = mat
	_grow_and_fade(quad, mat, color, 0.2, r1, seconds, Vector3(0, y + 0.01, 0))


func _grow_and_fade(quad: QuadMesh, mat: StandardMaterial3D, color: Color, r0: float, r1: float,
		seconds: float, at: Vector3) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = at
	mi.scale = Vector3.ONE * r0
	_fx_node().add_child(mi)
	var t := mi.create_tween().set_parallel()
	t.tween_property(mi, "scale", Vector3.ONE * r1, seconds).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	t.tween_method(func(v: float): mat.albedo_color = color * v, 1.0, 0.0, seconds) \
		.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	t.chain().tween_callback(mi.queue_free)


func _additive(color: Color, tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = false
	mat.albedo_color = color
	mat.albedo_texture = tex
	return mat


## A round texture, brightness by radius: offsets 0 (centre) .. 1 (edge).
func _soft_texture(offsets: Array, values: Array) -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	var colors := PackedColorArray()
	for v in values:
		colors.append(Color(1, 1, 1, v))
	g.colors = colors
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 128
	tex.height = 128
	return tex


## Attack towards the robot: two lights run from the back of the ring along
## both sides to LED_00 (the robot side). Returns when they meet.
func play_attack(color := Color(0.2, 1.0, 0.3)) -> void:
	fx.emit(tile_id, "attack", color)
	var half := LED_COUNT / 2
	for step in half + 1:
		clear_ring()
		for trail in 4:  # short fading tail
			var k := step - trail
			if k < 0:
				break
			var c := color * (1.0 - trail * 0.25)
			set_ring_led(half - k, c)
			set_ring_led(half + k, c)
		await get_tree().create_timer(0.012).timeout
	fill_ring(color)
	await get_tree().create_timer(0.08).timeout
	_shield_glow()


## Hit by the robot: red runs from LED_00 (robot side) along both sides to the
## back of the ring, then the whole ring flashes.
func play_hit(color := Color(1.0, 0.1, 0.05)) -> void:
	fx.emit(tile_id, "hit", color)
	var y: float = (_anchors[BUTTONS[0]] as Node3D).position.y + 0.05
	_flash(color, 7.0, 3.0, 0.06, 0.4, y + 0.3)            # the impact: visible from across the room
	_glow_ball(color.lightened(0.3), 0.1, 0.9, 0.35, y + 0.1)
	_shockwave(color, 1.1, 0.45, y)
	_debris(6, 0.03, 0.6, 0.0, y)                        # a few chips off the glass
	var half := LED_COUNT / 2
	for step in half + 1:
		clear_ring()
		for trail in 4:
			var k := step - trail
			if k < 0:
				break
			var c := color * (1.0 - trail * 0.25)
			set_ring_led(k, c)
			set_ring_led(-k, c)
		await get_tree().create_timer(0.012).timeout
	for n in 2:
		fill_ring(color)
		await get_tree().create_timer(0.1).timeout
		clear_ring()
		await get_tree().create_timer(0.08).timeout
	_shield_glow()


# ---------------------------------------------------------------- shield

func _build_shield() -> void:
	var mesh := SphereMesh.new()      # half an ellipsoid around the player
	mesh.is_hemisphere = true
	mesh.radius = 0.5
	mesh.height = 1.9                 # hemisphere: height = dome height (m)
	mesh.radial_segments = 48
	mesh.rings = 24
	_shield_mat = ShaderMaterial.new()
	_shield_mat.shader = SHIELD_SHADER
	_shield_mat.set_shader_parameter("color", SHIELD_COLOR)
	_shield_mat.set_shader_parameter("strength", 0.0)   # so the fade-in tween has a start value
	_shield = MeshInstance3D.new()
	_shield.name = "Shield"
	_shield.mesh = mesh
	_shield.material_override = _shield_mat
	_shield.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shield.visible = false
	add_child(_shield)


func set_shielded(on: bool) -> void:
	var changed := on != shielded
	shielded = on
	if _shield == null or not changed:
		return
	if _shield_tween:
		_shield_tween.kill()
	_shield.visible = true
	_shield_tween = create_tween()
	_shield_tween.tween_property(_shield_mat, "shader_parameter/strength", 1.0 if on else 0.0, 0.6)
	if not on:
		_shield_tween.tween_callback(func(): _shield.visible = shielded)
	if not idle and not pending and not is_dead:
		_shield_glow()


func _shield_glow() -> void:
	if shielded:
		fill_ring(SHIELD_COLOR * 0.35)
	else:
		clear_ring()


## An attack hits the shield: red stops at the front of the ring, the ring
## flashes blue and the dome ripples from the robot side. No life lost.
func play_block(color := Color(1.0, 0.1, 0.05)) -> void:
	fx.emit(tile_id, "block", color)
	_shield.visible = true
	var hit_at := _shield_impact()                     # (tile space) where the shot hits the shield
	_shield_mat.set_shader_parameter("impact", _shield.transform.affine_inverse() * hit_at)
	_shield_mat.set_shader_parameter("flash", 1.0)
	_shield_mat.set_shader_parameter("heat", 1.0)
	create_tween().tween_method(func(v): _shield_mat.set_shader_parameter("heat", v), 1.0, 0.0, 1.8) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)
	_flash(SHIELD_COLOR, 8.0, 3.0, 0.05, 0.5, 0.0, hit_at)
	_glow_ball_at(Color(0.75, 0.9, 1.0), 0.1, 0.9, 0.3, hit_at)
	_deflect_sparks(hit_at)
	var t := create_tween().set_parallel()
	t.tween_property(_shield_mat, "shader_parameter/flash", 0.0, 0.8)
	t.tween_method(func(v): _shield_mat.set_shader_parameter("ripple", v), 0.0, 1.0, 0.9)
	for step in 4:  # the red only gets a few LEDs in
		clear_ring()
		for k in step + 1:
			set_ring_led(k, color)
			set_ring_led(-k, color)
		await get_tree().create_timer(0.03).timeout
	for n in 3:
		fill_ring(SHIELD_COLOR)
		await get_tree().create_timer(0.1).timeout
		fill_ring(SHIELD_COLOR * 0.2)
		await get_tree().create_timer(0.07).timeout
	_shield_mat.set_shader_parameter("ripple", -1.0)
	_shield_glow()


## Back to life with full health; lives (1..HEART_COUNT) sets a new maximum.
func revive(lives := -1) -> void:
	is_dead = false
	if lives > 0:
		max_health = clampi(lives, 1, HEART_COUNT)
	set_health(max_health)
	set_status(Color(0.1, 1.0, 0.2))


## Colour of the RGB LED under a button symbol (Color.BLACK = off).
func set_button_led(button: StringName, color: Color) -> void:
	_button_colors[button] = color
	_paint(_button_leds[button], color)


## What the real tile should show, as data (MqttBridge: tile/<n>/state, retained):
##   mode     off (out of service) / setup (hearts: the number) / pending (the
##            invite's colour, the tile lights the pressed icons itself) /
##            idle / dead / playing
##   color    pending: the gamemaster's colour
##   lives / max_lives, shield, buttons {Square: "#rrggbb" ("" = off), ...}
## Rings during the tile games and Zwarte Piet: the tile's own programs.
func display_state() -> Dictionary:
	var mode := "playing"
	if out_of_service:
		mode = "off"
	elif show_number:
		mode = "setup"
	elif pending:
		mode = "pending"
	elif idle:
		mode = "idle"
	elif is_dead:
		mode = "dead"
	var buttons := {}
	for b in BUTTONS:
		var c: Color = _button_colors.get(b, Color.BLACK)
		buttons[str(b)] = "#" + c.to_html(false) if c.v > 0.01 else ""
	return {"mode": mode, "number": tile_id, "color": "#" + _activation_color.to_html(false),
		"lives": health, "max_lives": max_health, "shield": shielded,
		"buttons": buttons if mode == "playing" else {}}


func set_status(color: Color) -> void:
	_paint(_status_led, color)


# ---------------------------------------------------------------- buttons

## Feed a (normalised 0..1) reading from the pressure sensor under a symbol.
## Crossing press_threshold emits button_pressed / button_released.
func set_pressure(button: StringName, value: float) -> void:
	value = clampf(value, 0.0, 1.0)
	var was_pressed := is_pressed(button)
	_pressure[button] = value
	var mat := _button_leds[button].material_override as StandardMaterial3D
	mat.emission_energy_multiplier = 3.0 + 6.0 * value  # symbol glows brighter under a foot
	pressure_changed.emit(tile_id, button, value)
	if is_pressed(button) and not was_pressed:
		button_pressed.emit(tile_id, button)
	elif was_pressed and not is_pressed(button):
		button_released.emit(tile_id, button)


func get_pressure(button: StringName) -> float:
	return _pressure[button]


func is_pressed(button: StringName) -> bool:
	return _pressure[button] >= press_threshold


## Simulated tap (full press, released after `hold` seconds).
func press_button(button: StringName, hold := 0.15) -> void:
	set_pressure(button, 1.0)
	get_tree().create_timer(hold).timeout.connect(set_pressure.bind(button, 0.0))


## Mouse test: hold the left button on an etched symbol to "stand" on it.
func _add_click_area(button: StringName, anchor: Node3D) -> void:
	var area := Area3D.new()
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.05
	cyl.height = 0.01
	shape.shape = cyl
	area.add_child(shape)
	anchor.add_child(area)
	area.input_event.connect(func(_cam, event, _pos, _normal, _idx):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_clicked = button
				set_pressure(button, 1.0)
			elif _clicked == button:  # released on the icon (also works in other windows)
				_clicked = &""
				set_pressure(button, 0.0))


func _input(event: InputEvent) -> void:
	if _clicked != &"" and event is InputEventMouseButton and not event.pressed:
		set_pressure(_clicked, 0.0)
		_clicked = &""


# ---------------------------------------------------------------- internals

func _led(node_name: String, off_color := OFF_COLOR) -> MeshInstance3D:
	var mi := _model.find_child(node_name, true, false) as MeshInstance3D
	assert(mi != null, "tile.glb is missing node %s" % node_name)
	var mat := StandardMaterial3D.new()
	mat.emission_enabled = true
	mat.emission_energy_multiplier = 3.0
	mat.roughness = 0.3
	mi.material_override = mat
	mi.set_meta(&"off_color", off_color)
	return mi


func _paint(mi: MeshInstance3D, color: Color) -> void:
	var mat := mi.material_override as StandardMaterial3D
	var on := color.v > 0.01
	mat.albedo_color = color if on else mi.get_meta(&"off_color")
	mat.emission = color if on else Color.BLACK
