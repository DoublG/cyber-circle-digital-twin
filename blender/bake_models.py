"""Bake the lighting of the static environment into textures (Cycles, GPU).

Nothing in the room needs real-time lighting: the room, the floor, the ducts
and cables are merged into a few meshes whose lighting, shadows (also from the
robot and the tiles standing on the floor) and emissive glow are baked into
two texture atlases. In Godot these are drawn unshaded - no lights, no
shadows, a handful of draw calls (e.g. for a Raspberry Pi per screen).

Run headless after build_models.py (it reads the .blend files):
    blender -b -P bake_models.py -- environment [--samples 1024] [--size 4096]

Output: ../godot/models/environment_baked.glb (+ the atlases as PNG next to it)
Kept as separate objects (the Godot scripts drive them):
    Console_Lamp_*, Ceiling_Ring, Door_Light, Spoke_Light_*   emissive, colour set at runtime
    Door_Frame, Door_L, Door_R, Door_L_Stripe, Door_R_Stripe  the sliding door (baked too)
"""

import math
import os
import sys
import time

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_models as bm  # noqa: E402  (constants: ARENA_R, TILE_COUNT, GODOT_DIR)

DYNAMIC = ("Console_Lamp_", "Ceiling_Ring", "Door_Light", "Spoke_Light_")
MOVING = ("Door_Frame", "Door_L", "Door_R")              # prefixes: also the stripes
SHELL_AREA = 2.0       # m2: bigger surfaces go to the shell atlas, the rest to details


def arg(name, default):
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    return type(default)(argv[argv.index(name) + 1]) if name in argv else default


def append_objects(blend):
    """Append every object of another .blend; returns them."""
    with bpy.data.libraries.load(blend, link=False) as (src, dst):
        dst.objects = list(src.objects)
    objs = [o for o in dst.objects if o is not None]
    for o in objs:
        bpy.context.scene.collection.objects.link(o)
    return objs


def add_casters():
    """Robot and 13 tiles: they cast shadows on the floor, but are not exported."""
    casters = append_objects(os.path.join(HERE, "robot.blend"))
    step = 2 * math.pi / bm.TILE_COUNT
    tile_objs = append_objects(os.path.join(HERE, "tile.blend"))
    roots = [o for o in tile_objs if o.parent is None]
    for i in range(bm.TILE_COUNT):
        a = math.pi / 2 - i * step
        d = Vector((math.cos(a), math.sin(a)))
        for root in roots:
            r = root if i == 0 else root.copy()
            if i > 0:
                bpy.context.scene.collection.objects.link(r)
                for child in root.children_recursive:
                    c = child.copy()
                    bpy.context.scene.collection.objects.link(c)
                    casters.append(c)
                    c.parent = r
            r.location = (d.x * bm.ARENA_R, d.y * bm.ARENA_R, 0)
            r.rotation_euler = (0, 0, math.atan2(-d.y, -d.x) - math.pi / 2)  # +Y to the robot
            casters.append(r)
    return list(dict.fromkeys(casters + tile_objs))       # each object once


def setup_lighting():
    """The Godot room lighting: the ring light under the dome + ambient."""
    light = bpy.data.lights.new("Ring_Light", "POINT")
    light.energy = 900.0                 # tuned to the Godot look (ring light 1.6 + filmic tonemap)
    light.color = (0.7, 0.85, 1.0)
    light.shadow_soft_size = 0.6
    obj = bpy.data.objects.new("Ring_Light", light)
    obj.location = (0, 0, 4.2)
    bpy.context.scene.collection.objects.link(obj)
    world = bpy.data.worlds.new("Ambient")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.45, 0.42, 0.6, 1.0)
    bg.inputs["Strength"].default_value = 0.25
    bpy.context.scene.world = world


def setup_cycles(samples):
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    for kind in ("OPTIX", "CUDA"):
        try:
            prefs.compute_device_type = kind
            prefs.get_devices()
            if any(d.type == kind for d in prefs.devices):
                for d in prefs.devices:
                    d.use = d.type == kind
                scene.cycles.device = "GPU"
                print("bake: GPU", kind)
                break
        except TypeError:
            continue
    scene.cycles.samples = samples
    scene.render.bake.margin = 8
    scene.render.bake.use_clear = True


def flatten_metals():
    """Baked lighting is view-independent: show metals as their (light) colour."""
    for m in bpy.data.materials:
        if m.use_nodes and "Principled BSDF" in m.node_tree.nodes:
            bsdf = m.node_tree.nodes["Principled BSDF"]
            if bsdf.inputs["Metallic"].default_value > 0.5:
                bsdf.inputs["Metallic"].default_value = 0.0
                c = bsdf.inputs["Base Color"].default_value
                bsdf.inputs["Base Color"].default_value = (c[0] * 0.55, c[1] * 0.55, c[2] * 0.6, 1)


def mesh_area(o):
    return sum(p.area for p in o.data.polygons) * max(o.scale) ** 2


def select_only(objs):
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]


def unwrap(objs, margin=0.003):
    """One shared, non-overlapping UV layout ("Baked") over all objects."""
    for o in objs:
        uv = o.data.uv_layers.get("Baked") or o.data.uv_layers.new(name="Baked")
        o.data.uv_layers.active = uv
    select_only(objs)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    t = time.time()
    bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=margin,
                             area_weight=1.0, correct_aspect=True, scale_to_bounds=False)
    bpy.ops.object.mode_set(mode="OBJECT")            # (smart_project packs the islands itself)
    print(f"bake: unwrapped {len(objs)} objects in {time.time() - t:.0f} s", flush=True)


def bake_atlas(objs, name, size):
    """Bake light + colour + glow of objs into one image; returns the image."""
    img = bpy.data.images.new(name, size, size, alpha=False, float_buffer=False)
    unwrap(objs)
    for o in objs:
        for slot in o.material_slots:
            m = slot.material
            if m is None or not m.use_nodes:
                continue
            nodes = m.node_tree.nodes
            node = nodes.get("BakeTarget") or nodes.new("ShaderNodeTexImage")
            node.name = "BakeTarget"
            node.image = img
            uv = nodes.get("BakeUV") or nodes.new("ShaderNodeUVMap")
            uv.name = "BakeUV"
            uv.uv_map = "Baked"                        # bake into the new layout, not the render UV
            m.node_tree.links.new(uv.outputs["UV"], node.inputs["Vector"])
            nodes.active = node
    select_only(objs)
    print(f"bake: {name} {size}px, {len(objs)} objects ...", flush=True)
    t = time.time()
    bpy.ops.object.bake(type="COMBINED", pass_filter={"EMIT", "DIRECT", "INDIRECT", "DIFFUSE"},
                        use_clear=True, margin=8)
    path = os.path.join(bm.GODOT_DIR, "models", name + ".png")
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    print(f"bake: baked in {time.time() - t:.0f} s, saved {path}", flush=True)
    return img


def baked_material(name, img):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nodes = m.node_tree.nodes
    bsdf = nodes["Principled BSDF"]
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = img
    uv = nodes.new("ShaderNodeUVMap")
    uv.uv_map = "Baked"
    m.node_tree.links.new(uv.outputs["UV"], tex.inputs["Vector"])
    m.node_tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 1.0
    return m


def use_baked(objs, mat):
    """Only the baked UV and the baked material are left."""
    for o in objs:
        for uv in [u for u in o.data.uv_layers if u.name != "Baked"]:
            o.data.uv_layers.remove(uv)
        o.data.materials.clear()
        o.data.materials.append(mat)


def merge(objs, name):
    """Join objects into one mesh in world space (single-user data, no parents)."""
    for o in objs:
        o.data = o.data.copy()
        mw = o.matrix_world.copy()
        o.parent = None
        o.matrix_world = mw
    select_only(objs)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    if len(objs) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    return obj


def bake_environment(samples, size):
    bpy.ops.wm.open_mainfile(filepath=os.path.join(HERE, "room.blend"))
    env = [o for o in bpy.context.scene.objects]
    env += append_objects(os.path.join(HERE, "arena_floor.blend"))
    env = [o for o in env if o.type == "MESH" and "colonly" not in o.name]
    casters = add_casters()
    setup_lighting()
    setup_cycles(samples)
    flatten_metals()
    dynamic = [o for o in env if o.name.startswith(DYNAMIC)]
    moving = [o for o in env if o.name.startswith(MOVING)]
    static = [o for o in env if o not in dynamic and o not in moving]
    for o in moving + dynamic:                       # keep these as they are, in world space
        o.data = o.data.copy()
        mw = o.matrix_world.copy()
        o.parent = None
        o.matrix_world = mw
    shell = [o for o in static if mesh_area(o) >= SHELL_AREA]
    detail = [o for o in static if mesh_area(o) < SHELL_AREA]
    print(f"bake: {len(shell)} shell, {len(detail)} detail, {len(moving)} moving, "
          f"{len(dynamic)} dynamic, {len(casters)} casters", flush=True)

    # Cycles bakes every selected object in its own pass (re-syncing the whole
    # scene): merge first, so each atlas is one bake - and the casters one mesh
    t = time.time()
    shell_obj = merge(shell, "Env_Shell")
    detail_obj = merge(detail, "Env_Detail")
    caster_meshes = [o for o in casters if o.type == "MESH"]
    caster_other = [o for o in casters if o.type != "MESH"]   # (joined objects are gone after the merge)
    merge(caster_meshes, "Casters")
    for o in caster_other:
        bpy.data.objects.remove(o, do_unlink=True)
    print(f"bake: merged in {time.time() - t:.0f} s", flush=True)

    shell_img = bake_atlas([shell_obj], "Env_Shell_Baked", size)
    detail_img = bake_atlas([detail_obj] + moving, "Env_Detail_Baked", size)
    use_baked([shell_obj], baked_material("Baked_Env_Shell", shell_img))
    use_baked([detail_obj] + moving, baked_material("Baked_Env_Detail", detail_img))

    bpy.data.objects.remove(bpy.data.objects["Casters"], do_unlink=True)   # not exported
    for o in [o for o in bpy.context.scene.objects if o.type == "LIGHT"]:
        bpy.data.objects.remove(o, do_unlink=True)

    glb = os.path.join(bm.GODOT_DIR, "models", "environment_baked.glb")
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(HERE, "environment_baked.blend"))
    bpy.ops.export_scene.gltf(filepath=glb, export_format="GLB", export_yup=True,
                              export_apply=True, export_animations=False)
    print("bake: exported", glb, flush=True)


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    what = argv[0] if argv else "environment"
    if what in ("environment", "all"):
        bake_environment(arg("--samples", 512), arg("--size", 4096))
