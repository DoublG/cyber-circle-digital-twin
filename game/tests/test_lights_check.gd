extends Node
## The digital stand-ins of the external (DMX) lights: present, visible, and
## reacting to the light cues. tests/shots/89_lights_*.png

const ARENA := preload("res://scenes/arena.tscn")
var fails := 0


func check(ok: bool, what: String) -> void:
	print(("    [ok] " if ok else "    [FAIL] ") + what)
	fails += 0 if ok else 1


func _ready() -> void:
	var arena: Arena = ARENA.instantiate()
	add_child(arena)
	arena.game.use_database("")
	arena.sound.enabled = false
	var vp := SubViewport.new()
	vp.size = Vector2i(1600, 900)
	vp.world_3d = arena.get_world_3d()
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var cam := Camera3D.new()
	cam.fov = 75.0
	vp.add_child(cam)
	cam.position = Vector3(0, 2.0, -3.2)
	cam.look_at(Vector3(0, 1.6, 6))
	await get_tree().create_timer(1.0).timeout
	var washes := arena.room.find_child("PillarWashes", true, false) as MultiMeshInstance3D
	check(washes != null and washes.visible and washes.is_visible_in_tree(), "the pillar washes are there and visible")
	check(washes != null and washes.multimesh.instance_count == 16, "16 washes, one per pillar")
	check(arena.find_child("Lightning", true, false) != null, "the lightning mesh is there")
	arena.game.modes.change(GameManager.Mode.OPEN)
	await get_tree().create_timer(2.0).timeout
	var lit := 0
	for k in 16:
		if washes.multimesh.get_instance_color(k).v > 0.05:
			lit += 1
	check(lit == 16, "lobby: all 16 washes lit (%d)" % lit)
	vp.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://tests/shots/89_lights_lobby.png"))
	var before: Color = washes.multimesh.get_instance_color(8)
	arena.cue(&"explosion", 1)
	await get_tree().create_timer(0.15).timeout
	check(washes.multimesh.get_instance_color(8).v > before.v, "an explosion brightens the washes")
	vp.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://tests/shots/89_lights_explosion.png"))
	print("DONE: %d failure(s)" % fails)
	get_tree().quit()
