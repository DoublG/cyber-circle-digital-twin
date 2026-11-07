"""Generate the Cyber Circle Challenge tile and robot models.

Run headless:
    blender -b -P build_models.py -- tile
    blender -b -P build_models.py -- robot
    blender -b -P build_models.py -- drone
    blender -b -P build_models.py -- all

Outputs (relative to this file):
    tile.blend / robot.blend            editable Blender sources
    ../game/models/tile.glb / robot.glb  ready for Godot 4 import

Conventions (Blender Z-up, meters; glTF export converts to Godot Y-up):
    Blender +Y  == Godot -Z == "forward" (tile: towards the robot, robot: eye direction)
    Object names are the API the Godot scripts rely on -- keep them stable.
"""

import math
import os
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
GODOT_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "game"))
TEX_DIR = os.path.join(HERE, "textures")      # the generated room textures (retro_textures.py), as PNG
sys.path.insert(0, HERE)
import retro_textures  # noqa: E402


# ---------------------------------------------------------------- helpers

def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.render.fps = 24


def material(name, color, metallic=0.0, roughness=0.5, emission=None,
             emission_strength=0.0, alpha=1.0):
    m = bpy.data.materials.get(name)
    if m:
        return m
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    if emission is not None:
        bsdf.inputs["Emission Color"].default_value = (*emission, 1.0)
        bsdf.inputs["Emission Strength"].default_value = emission_strength
    if alpha < 1.0:
        bsdf.inputs["Alpha"].default_value = alpha
        m.surface_render_method = "BLENDED"
    m.diffuse_color = (*color, alpha)
    return m


def image_material(name, image):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.6
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = image
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    return m


def np_image(name, arr, non_color=False):
    """A Blender image from a numpy array (h, w[, 3]), row 0 = bottom; also saved
    as textures/<name>.png and packed into the .blend."""
    if arr.ndim == 2:
        arr = np.repeat(arr[..., None], 3, axis=2)
    h, w = arr.shape[:2]
    rgba = np.ones((h, w, 4), dtype=np.float32)
    rgba[..., :3] = np.clip(arr, 0, 1)
    old = bpy.data.images.get(name)
    if old:
        bpy.data.images.remove(old)
    im = bpy.data.images.new(name, w, h, alpha=False, float_buffer=not non_color)
    if non_color:
        im.colorspace_settings.name = "Non-Color"
    im.pixels.foreach_set(rgba.ravel())
    os.makedirs(TEX_DIR, exist_ok=True)
    im.filepath_raw = os.path.join(TEX_DIR, name + ".png")
    im.file_format = "PNG"
    im.save()
    im.pack()
    return im


def textured_material(name, albedo, height, roughness=0.6, bump=0.5, bump_distance=0.01):
    """Colour from an image on the "Tex" UV map, its relief from a height image
    (a Bump node: baked into the lighting by bake_models.py)."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = roughness
    uv = nt.nodes.new("ShaderNodeUVMap")
    uv.uv_map = "Tex"
    col = nt.nodes.new("ShaderNodeTexImage")
    col.image = np_image(name + "_Albedo", albedo)
    hgt = nt.nodes.new("ShaderNodeTexImage")
    hgt.image = np_image(name + "_Height", height, non_color=True)
    b = nt.nodes.new("ShaderNodeBump")
    b.inputs["Strength"].default_value = bump
    b.inputs["Distance"].default_value = bump_distance
    for node in (col, hgt):
        nt.links.new(uv.outputs["UV"], node.inputs["Vector"])
    nt.links.new(col.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(hgt.outputs["Color"], b.inputs["Height"])
    nt.links.new(b.outputs["Normal"], bsdf.inputs["Normal"])
    m.diffuse_color = (*albedo.reshape(-1, 3).mean(axis=0), 1.0)
    return m


def set_uv(obj, fn, name="Tex"):
    """A UV map from a function of each corner's object-space position and its
    face's normal: fn(co, normal) -> (u, v). With `wrap` set on fn (a period),
    u is kept continuous within a face (for angles)."""
    me = obj.data
    layer = me.uv_layers.get(name) or me.uv_layers.new(name=name)
    period = getattr(fn, "wrap", None)
    for poly in me.polygons:
        uvs = [fn(me.vertices[me.loops[li].vertex_index].co, poly.normal) for li in poly.loop_indices]
        if period:
            u0 = uvs[0][0]
            uvs = [(u - round((u - u0) / period) * period, v) for u, v in uvs]
        for li, uv in zip(poly.loop_indices, uvs):
            layer.data[li].uv = uv


def link(obj, mat=None, parent=None):
    if mat is not None:
        obj.data.materials.clear()
        obj.data.materials.append(mat)
    if parent is not None:
        set_parent(obj, parent)
    return obj


def set_parent(child, parent):
    bpy.context.view_layer.update()
    mw = child.matrix_world.copy()
    child.parent = parent
    child.matrix_parent_inverse = parent.matrix_world.inverted()
    child.matrix_world = mw


def new_object(name, bm):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(obj)
    return obj


def rename(obj, name):
    obj.name = name
    obj.data.name = name
    return obj


def smooth(obj, angle=35):
    obj.data.shade_smooth()
    obj.data.set_sharp_from_angle(angle=math.radians(angle))


def box(name, size, loc, rot=(0, 0, 0), mat=None, parent=None):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    obj = rename(bpy.context.active_object, name)
    for v in obj.data.vertices:
        v.co = Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2]))
    return link(obj, mat, parent)


def cylinder(name, r, depth, loc, rot=(0, 0, 0), verts=32, mat=None, parent=None,
             smooth_sides=True):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=depth,
                                        location=loc, rotation=rot)
    obj = rename(bpy.context.active_object, name)
    if smooth_sides:
        smooth(obj)
    return link(obj, mat, parent)


def sphere(name, r, loc, segs=16, rings=8, mat=None, parent=None):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segs, ring_count=rings, radius=r,
                                         location=loc)
    obj = rename(bpy.context.active_object, name)
    obj.data.shade_smooth()
    return link(obj, mat, parent)


def torus(name, major, minor, loc, mat=None, parent=None):
    bpy.ops.mesh.primitive_torus_add(major_radius=major, minor_radius=minor,
                                     major_segments=48, minor_segments=10, location=loc)
    obj = rename(bpy.context.active_object, name)
    obj.data.shade_smooth()
    return link(obj, mat, parent)


def disc(name, r, z, segs=96, mat=None):
    """Flat disc facing +Z with planar UVs covering 0..1."""
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    verts = [bm.verts.new((r * math.cos(2 * math.pi * i / segs),
                           r * math.sin(2 * math.pi * i / segs), z)) for i in range(segs)]
    face = bm.faces.new(verts)
    for loop in face.loops:
        loop[uv].uv = (loop.vert.co.x / (2 * r) + 0.5, loop.vert.co.y / (2 * r) + 0.5)
    return link(new_object(name, bm), mat)


def annulus(name, r_in, r_out, z, segs=96, mat=None):
    bm = bmesh.new()
    inner = [bm.verts.new((r_in * math.cos(2 * math.pi * i / segs),
                           r_in * math.sin(2 * math.pi * i / segs), z)) for i in range(segs)]
    outer = [bm.verts.new((r_out * math.cos(2 * math.pi * i / segs),
                           r_out * math.sin(2 * math.pi * i / segs), z)) for i in range(segs)]
    for i in range(segs):
        j = (i + 1) % segs
        bm.faces.new((inner[i], outer[i], outer[j], inner[j]))
    return link(new_object(name, bm), mat)


def tube(name, r_in, r_out, z0, z1, segs=96, mat=None):
    bm = bmesh.new()
    ring = lambda r, z: [bm.verts.new((r * math.cos(2 * math.pi * i / segs),
                                       r * math.sin(2 * math.pi * i / segs), z))
                         for i in range(segs)]
    ib, ob, it, ot = ring(r_in, z0), ring(r_out, z0), ring(r_in, z1), ring(r_out, z1)
    for i in range(segs):
        j = (i + 1) % segs
        bm.faces.new((it[i], ot[i], ot[j], it[j]))   # top
        bm.faces.new((ib[j], ob[j], ob[i], ib[i]))   # bottom
        bm.faces.new((ob[i], ob[j], ot[j], ot[i]))   # outer wall
        bm.faces.new((ib[j], ib[i], it[i], it[j]))   # inner wall
    obj = new_object(name, bm)
    obj.data.shade_smooth()
    obj.data.set_sharp_from_angle(angle=math.radians(35))
    return link(obj, mat)


def prism(name, pts, z0, z1, loc=(0, 0, 0), mat=None):
    """Extrude a 2D polygon (counter-clockwise points) from z0 to z1."""
    bm = bmesh.new()
    bottom = [bm.verts.new((x, y, z0)) for x, y in pts]
    face = bm.faces.new(bottom)
    ret = bmesh.ops.extrude_face_region(bm, geom=[face])
    top = [e for e in ret["geom"] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, verts=top, vec=(0, 0, z1 - z0))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    obj = new_object(name, bm)
    obj.location = loc
    return link(obj, mat)


def frustum(name, n, r_bottom, r_top, z0, z1, mat=None, angle0=0.0):
    """n-sided frustum, vertex k at angle angle0 + k*360/n (flat shaded panels)."""
    bm = bmesh.new()
    a = [angle0 + 2 * math.pi * k / n for k in range(n)]
    lo = [bm.verts.new((r_bottom * math.cos(t), r_bottom * math.sin(t), z0)) for t in a]
    hi = [bm.verts.new((r_top * math.cos(t), r_top * math.sin(t), z1)) for t in a]
    for k in range(n):
        j = (k + 1) % n
        bm.faces.new((lo[k], lo[j], hi[j], hi[k]))
    bm.faces.new(hi)
    bm.faces.new(list(reversed(lo)))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return link(new_object(name, bm), mat)


def join(objs, name):
    for o in bpy.context.selected_objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    return rename(bpy.context.active_object, name)


def save_and_export(basename):
    blend = os.path.join(HERE, basename + ".blend")
    glb = os.path.join(GODOT_DIR, "models", basename + ".glb")
    bpy.ops.wm.save_as_mainfile(filepath=blend)
    bpy.ops.export_scene.gltf(filepath=glb, export_format="GLB", export_yup=True,
                              export_apply=True, export_animations=True,
                              export_animation_mode="NLA_TRACKS")
    print(f"saved {blend}\nexported {glb}")


# ---------------------------------------------------------------- tile

TILE_R = 0.35          # outer radius (~70 cm tile)
TILE_TOP = 0.045       # top of the white plate (logo, LEDs, hearts sit here)
GLASS_R = 0.322
GLASS_GAP = 0.018      # space under the glass for button sensors + LEDs
GLASS_TOP = TILE_TOP + GLASS_GAP + 0.006   # 6 mm glass: the walking surface
LED_COUNT = 48
LED_RING_R = 0.304
HEART_COUNT = 5

# angle (deg, CCW from +X) -> button.  +Y (90 deg) points to the robot.
BUTTONS = {"Triangle": 45, "Square": 135, "Cross": 225, "Circle": 315}
BUTTON_R = 0.215


def yin_yang_image(path, res=1024, ss=2):
    """Yin-yang with the '0' (top, white lobe) and '1' (bottom, black lobe)."""
    n = res * ss
    c = (np.arange(n) + 0.5) / n * 2 - 1
    x, y = np.meshgrid(c, c)            # row 0 == bottom (Blender pixel order)
    rr = np.hypot(x, y)
    r_logo = 0.97

    def circle(cx, cy, r):
        return np.hypot(x - cx, y - cy) < r

    white = ((x < 0) & ~circle(0, -0.5 * r_logo, 0.5 * r_logo)) | circle(0, 0.5 * r_logo, 0.5 * r_logo)
    img = np.where(white, 0.92, 0.07)

    # "0": rounded rectangle outline, black, in the white lobe
    px, py = np.abs(x), np.abs(y - 0.48)
    bx, by, rad = 0.13, 0.22, 0.03
    qx, qy = px - bx + rad, py - by + rad
    sd = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - rad
    img = np.where((sd < 0) & (sd > -0.055), 0.07, img)

    # "1": stem + flag + foot, white, in the black lobe
    def rect(x0, x1, y0, y1):
        return (x > x0) & (x < x1) & (y > y0) & (y < y1)
    one = rect(-0.01, 0.05, -0.72, -0.27) | rect(-0.11, 0.05, -0.33, -0.27) | rect(-0.13, 0.19, -0.72, -0.66)
    img = np.where(one, 0.92, img)

    # thin black outline and white outside
    img = np.where((rr > r_logo) & (rr < 1.0), 0.07, img)
    img = np.where(rr >= 1.0, 0.92, img)

    img = img.reshape(res, ss, res, ss).mean(axis=(1, 3))
    rgba = np.ones((res, res, 4), dtype=np.float32)
    rgba[..., 0] = rgba[..., 1] = rgba[..., 2] = img
    im = bpy.data.images.new("yin_yang_01", res, res, alpha=False)
    im.pixels.foreach_set(rgba.ravel())
    im.filepath_raw = path
    im.file_format = "PNG"
    im.save()
    im.pack()
    return im


def heart_outline(size, n=40):
    pts = []
    for i in range(n):
        t = 2 * math.pi * i / n
        hx = 16 * math.sin(t) ** 3
        hy = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        pts.append((hx, hy + 2.5))
    s = size / 32.0
    pts = [(px * s, py * s) for px, py in pts]
    return list(reversed(pts))  # curve runs clockwise -> make CCW


def etched_buttons(glass_plate, glass_top, button_r, k, sym):
    """The 4 icons etched in a glass plate (tile, drone), k = size factor:
      Button_<name>          empty marking the button centre on the glass
      Button_<name>_Symbol   the etched icon"""
    for name, deg in BUTTONS.items():
        a = math.radians(deg)
        cx, cy = button_r * math.cos(a), button_r * math.sin(a)
        anchor = bpy.data.objects.new(f"Button_{name}", None)
        anchor.location = (cx, cy, glass_top)
        anchor.empty_display_size = 0.03
        bpy.context.collection.objects.link(anchor)
        top = glass_top + 0.0003  # etching: very thin frosted layer on the glass
        t = 0.009 * k
        parts = []
        if name == "Square":
            sq = 0.062 * k
            parts += [box("s", (sq, t, 0.0004), (cx, cy + sq / 2, top)),
                      box("s", (sq, t, 0.0004), (cx, cy - sq / 2, top)),
                      box("s", (t, sq, 0.0004), (cx + sq / 2, cy, top)),
                      box("s", (t, sq, 0.0004), (cx - sq / 2, cy, top))]
        elif name == "Triangle":
            r = 0.042 * k
            p = [(cx + r * math.cos(math.radians(90 + 120 * j)),
                  cy + r * math.sin(math.radians(90 + 120 * j))) for j in range(3)]
            for j in range(3):
                (x0, y0), (x1, y1) = p[j], p[(j + 1) % 3]
                length = math.hypot(x1 - x0, y1 - y0) + t
                parts.append(box("s", (length, t, 0.0004), ((x0 + x1) / 2, (y0 + y1) / 2, top),
                                 rot=(0, 0, math.atan2(y1 - y0, x1 - x0))))
        elif name == "Cross":
            for rz in (math.pi / 4, -math.pi / 4):
                parts.append(box("s", (0.082 * k, t, 0.0004), (cx, cy, top), rot=(0, 0, rz)))
        else:
            parts.append(torus("s", 0.033 * k, 0.0048 * k, (cx, cy, top)))
        for o in parts:
            o.scale.z = 0.15  # flatten tori into an etched line
        bpy.context.view_layer.update()
        symbol = join(parts, f"Button_{name}_Symbol")
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        link(symbol, sym, parent=glass_plate)
        set_parent(anchor, glass_plate)


def build_tile():
    reset_scene()
    white = material("Tile_White", (0.86, 0.86, 0.84), roughness=0.7)
    alu = material("Tile_Aluminium", (0.75, 0.76, 0.78), metallic=0.8, roughness=0.35)
    black = material("Tile_Black", (0.02, 0.02, 0.02), roughness=0.8)
    clear = material("Clear_Plastic", (0.9, 0.95, 1.0), roughness=0.1, alpha=0.35)
    led = material("LED", (0.15, 0.15, 0.15), roughness=0.3, emission=(0, 0, 0))
    # etched (frosted) glass, lit from below by an RGB LED
    sym = material("Button_Symbol", (0.95, 0.95, 0.95), roughness=0.9, emission=(0, 0, 0),
                   alpha=0.8)
    glass = material("Glass", (0.9, 0.97, 0.97), roughness=0.0, alpha=0.06)

    # Body: dark base, aluminium edge, white top plate
    cylinder("Tile_Base", TILE_R, TILE_TOP - 0.006, (0, 0, (TILE_TOP - 0.006) / 2),
             verts=96, mat=black)
    tube("Tile_Rim", GLASS_R - 0.002, TILE_R, TILE_TOP - 0.006, GLASS_TOP + 0.001, mat=alu)
    cylinder("Tile_Top", TILE_R - 0.004, 0.006, (0, 0, TILE_TOP - 0.003), verts=96, mat=white)
    annulus("LED_Channel", LED_RING_R - 0.009, LED_RING_R + 0.009, TILE_TOP + 0.0008,
            mat=black)

    for i in range(12):  # rim screws
        a = 2 * math.pi * (i + 0.5) / 12
        cylinder(f"Screw_{i:02d}", 0.008, 0.004,
                 (0.335 * math.cos(a), 0.335 * math.sin(a), GLASS_TOP + 0.002),
                 verts=12, mat=alu)

    # Joints between the four floor plates (left, right, bottom)
    for name, size, loc in (("Seam_L", (0.15, 0.004, 0.001), (-0.235, 0, TILE_TOP + 0.0005)),
                            ("Seam_R", (0.15, 0.004, 0.001), (0.235, 0, TILE_TOP + 0.0005)),
                            ("Seam_B", (0.004, 0.15, 0.001), (0, -0.235, TILE_TOP + 0.0005))):
        box(name, size, loc, mat=black)

    # Centre logo
    tex_path = os.path.join(GODOT_DIR, "textures", "yin_yang_01.png")
    logo = image_material("Logo_YinYang", yin_yang_image(tex_path))
    disc("Logo", 0.16, TILE_TOP + 0.0012, mat=logo)

    # LED ring: LED_00 at the robot side (+Y), counting clockwise seen from above
    for i in range(LED_COUNT):
        a = math.pi / 2 - 2 * math.pi * i / LED_COUNT
        box(f"LED_{i:02d}", (0.012, 0.007, 0.003),
            (LED_RING_R * math.cos(a), LED_RING_R * math.sin(a), TILE_TOP + 0.002),
            rot=(0, 0, a + math.pi / 2), mat=led)

    # Health bar: Heart_0 nearest the logo, Heart_4 nearest the rim
    box("Heart_Wire", (0.003, 0.13, 0.001), (0, 0.235, TILE_TOP + 0.0006), mat=black)
    for i in range(HEART_COUNT):
        y = 0.18 + i * 0.024
        prism(f"Heart_{i}_Frame", heart_outline(0.026), TILE_TOP, TILE_TOP + 0.0025,
              loc=(0, y, 0), mat=black)
        prism(f"Heart_{i}", heart_outline(0.019), TILE_TOP, TILE_TOP + 0.0035,
              loc=(0, y, 0), mat=led)

    # Glass plate on spacers; it is the walking surface
    for i in range(8):
        a = 2 * math.pi * (i + 0.5) / 8
        cylinder(f"Glass_Spacer_{i}", 0.006, GLASS_GAP,
                 (0.27 * math.cos(a), 0.27 * math.sin(a), TILE_TOP + GLASS_GAP / 2),
                 verts=12, mat=clear)
    glass_plate = cylinder("Glass_Plate", GLASS_R, 0.006, (0, 0, GLASS_TOP - 0.003),
                           verts=96, mat=glass)

    # Buttons = icons etched in the glass, lit by an RGB LED (no physical parts)
    etched_buttons(glass_plate, GLASS_TOP, BUTTON_R, 1.0, sym)

    # Status LED on the cable side and a collision shape for Godot
    cylinder("Status_LED", 0.004, 0.004, (0.05, TILE_R - 0.012, GLASS_TOP + 0.002),
             verts=12, mat=led)
    cylinder("Tile_Collider-convcolonly", TILE_R, GLASS_TOP, (0, 0, GLASS_TOP / 2), verts=24)

    save_and_export("tile")


# ---------------------------------------------------------------- robot

SKIRT_SIDES = 13        # one side per tile; side k faces tile k+1
SKIRT_Z0, SKIRT_Z1 = 0.10, 0.98
SKIRT_R0, SKIRT_R1 = 0.55, 0.37
BULB_COUNT = 5          # half spheres per side plate, row 0 at the bottom
BULB_R = 0.052
HEAD_Z = 1.295          # pivot of the rotating top (cylinder, eye, half-sphere head)


def keyframe_action(obj, name, keys, interpolation="LINEAR"):
    """keys: list of (frame, z_rotation_rad). Pushed to an NLA track -> glTF animation."""
    obj.animation_data_create()
    obj.animation_data.action = None
    for frame, rz in keys:
        obj.rotation_euler = (0, 0, rz)
        obj.keyframe_insert("rotation_euler", index=2, frame=frame)
    action = obj.animation_data.action
    action.name = name
    for fc in action.fcurves if hasattr(action, "fcurves") else []:
        for kp in fc.keyframe_points:
            kp.interpolation = interpolation
    track = obj.animation_data.nla_tracks.new()
    track.name = name
    track.strips.new(name, int(keys[0][0]), action)
    obj.animation_data.action = None
    obj.rotation_euler = (0, 0, 0)


def set_linear(action):
    """Blender 5 slotted actions: walk layers/strips/channelbags for f-curves."""
    for layer in getattr(action, "layers", []):
        for strip in layer.strips:
            for bag in strip.channelbags:
                for fc in bag.fcurves:
                    for kp in fc.keyframe_points:
                        kp.interpolation = "LINEAR"


def hemisphere(name, r, center, normal, mat=None, segs=20, rings=10):
    """Half sphere whose flat side lies on a plane with the given normal."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=r)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z < -1e-4], context="VERTS")
    obj = new_object(name, bm)
    obj.data.shade_smooth()
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = Vector(normal).to_track_quat("Z", "Y")
    obj.location = center
    return link(obj, mat)


def side_plate(name, corners, normal, thickness, mat=None):
    """Plate from 4 corners (CCW seen from outside), extruded along normal."""
    bm = bmesh.new()
    face = bm.faces.new([bm.verts.new(c) for c in corners])
    ret = bmesh.ops.extrude_face_region(bm, geom=[face])
    top = [e for e in ret["geom"] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, verts=top, vec=Vector(normal) * thickness)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return link(new_object(name, bm), mat)


def build_robot():
    reset_scene()
    gold = material("Gold", (0.62, 0.52, 0.30), metallic=0.6, roughness=0.45)
    black = material("Robot_Black", (0.02, 0.02, 0.02), roughness=0.7)
    gloss_black = material("Gloss_Black", (0.01, 0.01, 0.01), metallic=0.3, roughness=0.15)
    bulb = material("Bulb", (0.92, 0.92, 0.95), roughness=0.35, emission=(0, 0, 0), alpha=0.92)
    mesh_brown = material("Neck_Mesh", (0.35, 0.24, 0.14), roughness=0.9)
    dome = material("Dome", (0.95, 0.95, 1.0), roughness=0.3, emission=(0.6, 0.6, 0.8),
                    emission_strength=0.5, alpha=0.9)
    silver = material("Silver", (0.8, 0.8, 0.82), metallic=1.0, roughness=0.25)
    lens = material("Eye_Lens", (0.85, 0.9, 1.0), roughness=0.05, emission=(0.2, 0.4, 1.0),
                    emission_strength=0.0, alpha=0.6)

    # Stepped black base; side k is centred on angle 90 - k*360/13 deg
    # (side 0 faces +Y = robot front, counting clockwise seen from above)
    n = SKIRT_SIDES
    half = math.pi / n
    a0 = math.pi / 2 + half  # vertex angle so that side 0 is centred on +Y
    frustum("Plinth", n, 0.64, 0.63, 0.0, 0.05, mat=black, angle0=a0)
    frustum("Plinth_Step", n, 0.59, 0.58, 0.05, SKIRT_Z0, mat=black, angle0=a0)
    frustum("Skirt", n, SKIRT_R0 - 0.005, SKIRT_R1 - 0.005, SKIRT_Z0, SKIRT_Z1, mat=black,
            angle0=a0)

    # One gold plate per side with 5 half spheres: Side_k, Bulb_{k*5 + row}
    inset, thick = 0.012, 0.008
    for k in range(n):
        a = math.pi / 2 - 2 * math.pi * k / n
        al, ar = a + half, a - half  # left / right edge seen from outside
        bl = Vector((SKIRT_R0 * math.cos(al), SKIRT_R0 * math.sin(al), SKIRT_Z0))
        br = Vector((SKIRT_R0 * math.cos(ar), SKIRT_R0 * math.sin(ar), SKIRT_Z0))
        tr = Vector((SKIRT_R1 * math.cos(ar), SKIRT_R1 * math.sin(ar), SKIRT_Z1))
        tl = Vector((SKIRT_R1 * math.cos(al), SKIRT_R1 * math.sin(al), SKIRT_Z1))
        normal = (br - bl).cross(tl - bl).normalized()
        if normal.dot(Vector((math.cos(a), math.sin(a), 0))) < 0:
            normal = -normal
        centre = (bl + br + tr + tl) / 4

        def shrink(p, c=centre):
            return p + (c - p).normalized() * inset * 1.4
        side_plate(f"Side_{k:02d}", [shrink(bl), shrink(br), shrink(tr), shrink(tl)],
                   normal, thick, mat=gold)

        bottom_mid, top_mid = (bl + br) / 2, (tl + tr) / 2
        for row in range(BULB_COUNT):
            t = (row + 0.55) / (BULB_COUNT + 0.1)
            p = bottom_mid.lerp(top_mid, t) + normal * thick
            hemisphere(f"Bulb_{k * BULB_COUNT + row:02d}", BULB_R, p, normal, mat=bulb)

    # Glossy black collar on top of the skirt
    frustum("Collar", n, 0.375, 0.36, SKIRT_Z1, SKIRT_Z1 + 0.05, mat=gloss_black, angle0=a0)

    # Shoulder: sloped section, wide at the bottom and narrower at the top,
    # gold brackets around a dark core, gold plate on top
    sh0, sh1 = SKIRT_Z1 + 0.05, 1.27
    frustum("Shoulder_Core", 26, 0.35, 0.26, sh0, sh1, mat=mesh_brown)
    brackets = []
    tilt = math.atan2(0.09, sh1 - sh0)
    for k in range(2 * n):
        a = math.pi / 2 - 2 * math.pi * (k + 0.5) / (2 * n)
        r = 0.315
        brackets.append(box("b", (0.035, 0.05, (sh1 - sh0) / math.cos(tilt)),
                            (r * math.cos(a), r * math.sin(a), (sh0 + sh1) / 2),
                            rot=(tilt, 0, a - math.pi / 2)))
        brackets.append(box("b", (0.05, 0.03, 0.03),  # small step on each bracket
                            ((r + 0.065) * math.cos(a), (r + 0.065) * math.sin(a), sh0 + 0.03),
                            rot=(0, 0, a - math.pi / 2)))
    link(join(brackets, "Shoulder_Brackets"), gold)
    cylinder("Shoulder_Plate", 0.29, 0.025, (0, 0, sh1 + 0.0125), verts=64, mat=gold)

    # Rotating top: everything under the "Head" empty turns together around Z
    # (Godot Y): the cylinder (neck cage), the eye and the half-sphere head on top.
    head = bpy.data.objects.new("Head", None)
    head.empty_display_type = "ARROWS"
    head.empty_display_size = 0.3
    head.location = (0, 0, HEAD_Z)
    bpy.context.collection.objects.link(head)

    neck0, neck1 = sh1 + 0.025, 1.53
    cylinder("Neck", 0.22, neck1 - neck0, (0, 0, (neck0 + neck1) / 2), verts=40,
             mat=mesh_brown, parent=head)
    for j, z in enumerate(((neck0 + neck1) / 2, neck1)):
        cylinder(f"Neck_Ring_{j}", 0.265, 0.022, (0, 0, z), verts=64, mat=gold, parent=head)
    posts = [box("post", (0.025, 0.025, neck1 - neck0),
                 (0.25 * math.cos(2 * math.pi * k / 10), 0.25 * math.sin(2 * math.pi * k / 10),
                  (neck0 + neck1) / 2))
             for k in range(10)]
    link(join(posts, "Neck_Posts"), gold, parent=head)

    band0 = neck1 + 0.011  # top of the cylinder: the half-sphere head sits here
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=48, v_segments=24, radius=0.265)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z < -1e-4], context="VERTS")
    dome_obj = new_object("Dome", bm)
    dome_obj.location = (0, 0, band0)
    dome_obj.data.shade_smooth()
    link(dome_obj, dome, parent=head)

    # Party lamp inside the head (its rotating colours are a shader in Godot)
    cylinder("Party_Lamp_Base", 0.05, 0.04, (0, 0, band0 + 0.02), verts=24, mat=black,
             parent=head)
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=0.07,
                                          location=(0, 0, band0 + 0.1))
    ball = rename(bpy.context.active_object, "Party_Lamp_Ball")
    link(ball, lens, parent=head)

    # Eye stalk out of the base of the head: rod, cooling fins, black end with lens
    eye_z = band0 + 0.04
    rot = (math.pi / 2, 0, 0)
    cylinder("Eye_Base", 0.03, 0.04, (0, 0.27, eye_z), rot=rot, verts=20, mat=gold, parent=head)
    cylinder("Eye_Stalk", 0.011, 0.42, (0, 0.47, eye_z), rot=rot, verts=16, mat=silver,
             parent=head)
    fins = [cylinder("f", 0.034, 0.004, (0, 0.50 + 0.014 * i, eye_z), rot=rot, verts=20)
            for i in range(4)]
    link(join(fins, "Eye_Fins"), silver, parent=head)
    cylinder("Eye_Tip", 0.034, 0.085, (0, 0.70, eye_z), rot=rot, verts=24, mat=black,
             parent=head)
    cylinder("Eye_Lens", 0.022, 0.004, (0, 0.744, eye_z), rot=rot, verts=24, mat=lens,
             parent=head)

    cylinder("Robot_Collider-convcolonly", 0.55, 1.75, (0, 0, 0.875), verts=16)

    # Baked head animations (Godot can also drive "Head" directly via script)
    for name, keys in (("HeadSpin", [(1, 0.0), (241, -2 * math.pi)]),
                       ("HeadScan", [(1, 0.0), (49, math.radians(70)),
                                     (145, math.radians(-70)), (193, 0.0)])):
        keyframe_action(head, name, keys)
        set_linear(bpy.data.actions[name])

    save_and_export("robot")


# ---------------------------------------------------------------- arena floor

ARENA_R = 2.5           # robot centre -> tile centre (m); keep in sync with arena.tscn
TILE_COUNT = 13         # tile k+1 sits in front of robot side k
ROBOT_APOTHEM = 0.62    # where the spokes meet the robot base
DUCT_W, DUCT_TOP_W, DUCT_H = 0.10, 0.07, 0.025


def duct(name, pts, mat=None):
    """Cable protector (trapezoid profile) along a 2D polyline, mitred at kinks."""
    pts = [Vector((x, y)) for x, y in pts]
    profile = [(-DUCT_W / 2, 0.0), (-DUCT_TOP_W / 2, DUCT_H),
               (DUCT_TOP_W / 2, DUCT_H), (DUCT_W / 2, 0.0)]
    bm = bmesh.new()
    rings = []
    for i, p in enumerate(pts):
        d_in = (p - pts[i - 1]).normalized() if i > 0 else None
        d_out = (pts[i + 1] - p).normalized() if i < len(pts) - 1 else None
        d = (d_in + d_out).normalized() if d_in and d_out else (d_in or d_out)
        side = Vector((-d.y, d.x))
        scale = 1.0 / max(0.3, side.dot(Vector((-(d_out or d).y, (d_out or d).x))))
        rings.append([bm.verts.new((p.x + side.x * u * scale, p.y + side.y * u * scale, z))
                      for u, z in profile])
    for r0, r1 in zip(rings, rings[1:]):
        for j in range(3):
            bm.faces.new((r0[j], r1[j], r1[j + 1], r0[j + 1]))
        bm.faces.new((r0[3], r1[3], r1[0], r0[0]))  # bottom
    bm.faces.new(rings[0])
    bm.faces.new(list(reversed(rings[-1])))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return link(new_object(name, bm), mat)


def build_arena():
    reset_scene()
    rubber = material("Duct_Rubber", (0.012, 0.012, 0.012), roughness=0.85)
    cable_mat = material("Cable", (0.01, 0.01, 0.01), roughness=0.4)
    label_mat = material("Label", (0.9, 0.9, 0.9), roughness=0.6)
    strip_mat = material("Cable_Light", (0.05, 0.05, 0.06), roughness=0.4, emission=(0, 0, 0))

    # the visible floor is the room's deck (one colour); only a collider here
    box("Floor-colonly", (8.0, 8.0, 0.02), (0, 0, -0.01))

    step = 2 * math.pi / TILE_COUNT
    tile_r = TILE_R + 0.01
    for i in range(TILE_COUNT):
        a = math.pi / 2 - i * step                 # same angles as robot side i
        d = Vector((math.cos(a), math.sin(a)))
        t = Vector((math.sin(a), -math.cos(a)))    # clockwise tangent (towards tile i+2)
        c = d * ARENA_R

        # spoke: robot base -> tile (carries the tile cable)
        duct(f"Spoke_{i + 1:02d}", [d * ROBOT_APOTHEM, d * (ARENA_R - tile_r)], mat=rubber)
        # light strip on top of the spoke, UV x: 0 at the tile -> 1 at the robot
        p_tile, p_robot = d * (ARENA_R - tile_r - 0.15), d * (ROBOT_APOTHEM + 0.02)
        bm = bmesh.new()
        uv = bm.loops.layers.uv.new("UVMap")
        w = Vector((-d.y, d.x)) * 0.007
        z = DUCT_H + 0.0006
        corners = [(p_tile + w, (0, 1)), (p_robot + w, (1, 1)),   # CCW from above
                   (p_robot - w, (1, 0)), (p_tile - w, (0, 0))]
        face = bm.faces.new([bm.verts.new((q.x, q.y, z)) for q, _ in corners])
        for loop, (_, c_uv) in zip(face.loops, corners):
            loop[uv].uv = c_uv
        link(new_object(f"Spoke_Light_{i + 1:02d}", bm), strip_mat)

        lab = d * (ARENA_R - tile_r - 0.08)
        box(f"Label_{i + 1:02d}", (0.075, 0.022, 0.001), (lab.x, lab.y, DUCT_H + 0.0005),
            rot=(0, 0, a - math.pi / 2), mat=label_mat)

        # ring duct to the next tile: out of the tile's side, kink, into the neighbour
        a2 = a - step
        d2 = Vector((math.cos(a2), math.sin(a2)))
        t2 = Vector((math.sin(a2), -math.cos(a2)))
        c2 = d2 * ARENA_R
        p0, p3 = c + t * tile_r, c2 - t2 * tile_r
        duct(f"Ring_{i + 1:02d}", [p0, p0 + t * 0.12, p3 - t2 * 0.12, p3], mat=rubber)

        # loose cable: leaves the spoke near the tile and loops into the tile rim
        start = d * (ARENA_R - tile_r - 0.22) + t * (DUCT_W / 2)
        rim_a = a + math.pi - math.radians(35)     # tile rim, 35 deg right of the robot side
        end = c + Vector((math.cos(rim_a), math.sin(rim_a))) * (TILE_R - 0.01)
        mid = (start + end) / 2 + t * 0.18
        cu = bpy.data.curves.new(f"Cable_{i + 1:02d}", "CURVE")
        cu.dimensions = "3D"
        cu.bevel_depth = 0.0055
        cu.bevel_resolution = 2
        cu.resolution_u = 10
        sp = cu.splines.new("BEZIER")
        sp.bezier_points.add(2)
        for bp, (pt, z) in zip(sp.bezier_points, ((start, 0.008), (mid, 0.012), (end, 0.05))):
            bp.co = (pt.x, pt.y, z)
            bp.handle_left_type = bp.handle_right_type = "AUTO"
        obj = bpy.data.objects.new(f"Cable_{i + 1:02d}", cu)
        bpy.context.collection.objects.link(obj)
        for o in bpy.context.selected_objects:
            o.select_set(False)
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.convert(target="MESH")
        link(obj, cable_mat)

    save_and_export("arena_floor")


# ---------------------------------------------------------------- room

ROOM_SIDES = 16
ROOM_R = 6.6            # wall corner radius (m)
ROOM_H = 3.6            # wall height; the ceiling slopes up to the centre
DOOR_WALL = 12          # wall at -Y (Godot +Z): in view behind the robot
WINDOW_WALLS = (2, 6, 10, 14)
GIMMICK_WALL = 13       # the console with the 60s gimmick (console_gimmick) instead of a CRT
# each console's look, homages to 1960s / 70s TV sci-fi (console_style): the
# eye-catching ones on the walls the overview camera sees behind the robot
CONSOLE_COLORS = {               # desk body, panel, front stripe (linear RGB)
    "classic": ((0.82, 0.78, 0.66), (0.06, 0.06, 0.07), (0.85, 0.35, 0.06)),
    "trek": ((0.16, 0.17, 0.19), (0.03, 0.03, 0.035), (0.7, 0.04, 0.03)),
    "lis": ((0.80, 0.78, 0.72), (0.35, 0.36, 0.38), (0.75, 0.76, 0.8)),
    "alpha": ((0.92, 0.92, 0.90), (0.85, 0.85, 0.83), (0.95, 0.45, 0.08)),
    "ufo": ((0.55, 0.57, 0.60), (0.02, 0.02, 0.025), (0.35, 0.1, 0.55)),
    "dials": ((0.28, 0.14, 0.06), (0.12, 0.07, 0.03), (0.75, 0.55, 0.2)),
    "orion": ((0.62, 0.64, 0.66), (0.03, 0.03, 0.035), (0.2, 0.2, 0.22)),
}
WALL_STYLES = ("lis",)          # no desk: the computer is a wall element (in the console's section)
CONSOLE_STYLES = {0: "trek", 1: "lis", 3: "ufo", 4: "classic", 5: "alpha", 7: "dials",
                  8: "ufo", 9: "alpha", 11: "trek", 13: "orion", 15: "lis"}
DOME_H = 5.0            # dome height above the walls (top ~8.6 m)
OCULUS_R = 0.9          # opening at the top of the dome


def starfield_image(path, res=1024, seed=7):
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:res, 0:res] / res
    img = np.zeros((res, res, 3), dtype=np.float32)
    # faint nebula
    for cx, cy, r, col in ((0.3, 0.6, 0.35, (0.25, 0.05, 0.35)), (0.75, 0.3, 0.3, (0.0, 0.15, 0.3))):
        g = np.exp(-((x - cx) ** 2 + (y - cy) ** 2) / (r * r))
        img += g[..., None] * np.array(col, dtype=np.float32)
    img += np.array((0.005, 0.008, 0.02), dtype=np.float32)
    n = 1400
    sx, sy = rng.integers(0, res, n), rng.integers(0, res, n)
    b = rng.power(6, n)
    tint = rng.uniform(0.75, 1.0, (n, 3))
    for i in range(n):
        img[sy[i], sx[i]] = np.maximum(img[sy[i], sx[i]], b[i] * tint[i])
        if b[i] > 0.9:  # a few bigger stars
            img[max(sy[i] - 1, 0):sy[i] + 2, max(sx[i] - 1, 0):sx[i] + 2] = np.maximum(
                img[max(sy[i] - 1, 0):sy[i] + 2, max(sx[i] - 1, 0):sx[i] + 2], b[i] * 0.6)
    rgba = np.ones((res, res, 4), dtype=np.float32)
    rgba[..., :3] = np.clip(img, 0, 1)
    im = bpy.data.images.new("starfield", res, res, alpha=False)
    im.pixels.foreach_set(rgba.ravel())
    im.filepath_raw = path
    im.file_format = "PNG"
    im.save()
    im.pack()
    return im


def emissive_image_material(name, image, strength=1.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0, 0, 0, 1)
    bsdf.inputs["Emission Strength"].default_value = strength
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = image
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Emission Color"])
    return m


def build_room():
    reset_scene()
    cream = material("Retro_Cream", (0.82, 0.78, 0.66), roughness=0.5)
    orange = material("Retro_Orange", (0.85, 0.35, 0.06), roughness=0.4)
    teal = material("Retro_Teal", (0.05, 0.38, 0.40), roughness=0.4)
    chrome = material("Chrome", (0.85, 0.86, 0.9), metallic=1.0, roughness=0.15)
    deck = textured_material("Deck_Plates", *retro_textures.floor_deck(radius=ROOM_R, tile_r=ARENA_R),
                             roughness=0.55, bump=0.6, bump_distance=0.006)
    wall_mat = textured_material("Wall_Panels", *retro_textures.wall_panels(sx=2 * ROOM_R * math.sin(math.pi / ROOM_SIDES), sy=ROOM_H),
                                 roughness=0.5, bump=0.7, bump_distance=0.01)
    pillar_mat = textured_material("Pillar_Ribs", *retro_textures.pillar_ribs(sy=ROOM_H),
                                   roughness=0.4, bump=0.8, bump_distance=0.012)
    navy = textured_material("Dome_Quilt", *retro_textures.dome_quilt(), roughness=0.7, bump=0.8,
                             bump_distance=0.03)
    dark = material("Console_Dark", (0.06, 0.06, 0.07), roughness=0.4)
    cove = material("Cornice_Cove_Glow", (0.6, 0.95, 1.0), emission=(0.55, 0.9, 1.0), emission_strength=6.0)
    roundel = material("Roundel_Glow", (0.95, 0.86, 0.66), emission=(1.0, 0.78, 0.5),
                       emission_strength=0.55)
    lamp = material("Console_Lamp", (0.3, 0.3, 0.3), roughness=0.3, emission=(0, 0, 0))
    crt = material("Console_CRT", (0.02, 0.06, 0.03), roughness=0.1, emission=(0.1, 0.8, 0.3),
                   emission_strength=0.8)
    ring_glow = material("Ceiling_Ring_Glow", (1, 1, 1), emission=(0.7, 0.85, 1.0),
                         emission_strength=4.0)
    btn_mats = [material(f"Button_{n}", c, roughness=0.3) for n, c in (
        ("Red", (0.8, 0.08, 0.05)), ("Yellow", (0.95, 0.75, 0.1)),
        ("Green", (0.1, 0.6, 0.2)), ("White", (0.9, 0.9, 0.85)))]
    stars = emissive_image_material(
        "Starfield", starfield_image(os.path.join(GODOT_DIR, "textures", "starfield.png")), 1.2)

    n = ROOM_SIDES
    half = math.pi / n
    apothem = ROOM_R * math.cos(half)
    side_len = 2 * ROOM_R * math.sin(half)

    # Floor: one colour for the whole room (the play area has no separate cover)
    floor = frustum("Deck", n, ROOM_R, ROOM_R, -0.05, 0.0, mat=deck, angle0=half)
    set_uv(floor, lambda co, nrm: (co.x / (2 * ROOM_R) + 0.5, co.y / (2 * ROOM_R) + 0.5))   # one texture: the whole floor

    # Cathedral dome: pointed (Gothic) profile from the wall top to an oculus
    # at the peak that looks out to space, chrome ribs above every pillar.
    arc_r = 1.2 * ROOM_R                       # arc radius of the pointed arch
    arc_c = ROOM_R - arc_r                     # arc centre lies past the axis -> pointed top
    squash = DOME_H / math.sqrt(arc_r ** 2 - arc_c ** 2)

    def dome_z(x):
        return ROOM_H + squash * math.sqrt(max(arc_r ** 2 - (x - arc_c) ** 2, 0.0))

    def dome_normal(x):  # inward normal of the profile in (radial, z)
        e = 1e-3
        tx, tz = -e, dome_z(x - e) - dome_z(x)
        ln = math.hypot(tx, tz)
        return Vector((-tz / ln, tx / ln))

    steps, around = 28, n * 4
    xs = [OCULUS_R + (ROOM_R - OCULUS_R) * math.cos(t / steps * math.pi / 2) for t in range(steps + 1)]
    bm = bmesh.new()
    rings = [[bm.verts.new((x * math.cos(half + 2 * math.pi * j / around),
                            x * math.sin(half + 2 * math.pi * j / around), dome_z(x)))
              for j in range(around)] for x in xs]
    for r0, r1 in zip(rings, rings[1:]):
        for j in range(around):
            k = (j + 1) % around
            bm.faces.new((r0[j], r1[j], r1[k], r0[k]))  # wound to face into the room
    dome_obj = new_object("Dome", bm)
    dome_obj.data.shade_smooth()
    link(dome_obj, navy)

    # v along the dome's curve (arc length from the wall top), so the rows are
    # not stretched where the dome rises steeply above the walls
    prof_x = [ROOM_R - (ROOM_R - OCULUS_R) * k / 400 for k in range(401)]
    prof_s = [0.0]
    for a, b in zip(prof_x, prof_x[1:]):
        prof_s.append(prof_s[-1] + math.hypot(a - b, dome_z(a) - dome_z(b)))

    def arc_v(r):
        k = min(max((ROOM_R - r) / (ROOM_R - OCULUS_R) * 400, 0.0), 399.999)
        j = int(k)
        return (prof_s[j] + (prof_s[j + 1] - prof_s[j]) * (k - j)) / prof_s[-1]

    def dome_uv(co, nrm):              # u: one texture per bay between two ribs; v: wall top -> oculus
        ang = math.atan2(co.y, co.x) - half
        return (ang / (2 * math.pi) * n, arc_v(math.hypot(co.x, co.y)))
    dome_uv.wrap = n
    set_uv(dome_obj, dome_uv)

    top_z = dome_z(OCULUS_R)
    sky = disc("Oculus_Space", OCULUS_R + 0.05, top_z + 0.02, segs=48, mat=stars)
    sky.data.polygons[0].flip()  # face down into the room
    torus("Ceiling_Ring", OCULUS_R + 0.06, 0.07, (0, 0, top_z - 0.03), mat=ring_glow)

    for frac in (0.72, 0.42):  # horizontal chrome rings
        x = ROOM_R * frac
        nrm = dome_normal(x)
        torus(f"Dome_Ring_{frac:.2f}", x + nrm.x * 0.05, 0.04, (0, 0, dome_z(x) + nrm.y * 0.05),
              mat=chrome)

    # clerestory windows between the ribs, low on the dome
    wx = ROOM_R * 0.86
    wn = dome_normal(wx)
    for i in range(n):
        phi = 2 * math.pi * i / n
        radial = Vector((math.cos(phi), math.sin(phi), 0))
        normal3 = (radial * wn.x + Vector((0, 0, wn.y))).normalized()
        centre = radial * wx + Vector((0, 0, dome_z(wx))) + normal3 * 0.04
        oriented_disc(f"Dome_Window_{i:02d}", centre, normal3, 0.38, mat=stars)
        frame = torus(f"Dome_Window_{i:02d}_Frame", 0.40, 0.035, centre, mat=chrome)
        frame.rotation_mode = "QUATERNION"
        frame.rotation_quaternion = normal3.to_track_quat("Z", "Y")

    for k in range(n):
        a = 2 * math.pi * k / n + half  # wall corners
        radial = Vector((math.cos(a), math.sin(a), 0))
        side = Vector((-math.sin(a), math.cos(a), 0)) * 0.07
        bm = bmesh.new()
        prev = None
        for x in xs:
            nrm = dome_normal(x)
            p = radial * x + Vector((0, 0, dome_z(x)))
            inward = (radial * nrm.x + Vector((0, 0, nrm.y))) * 0.12
            ring = [bm.verts.new(v) for v in (p - side, p + side, p + side + inward, p - side + inward)]
            if prev:
                for j in range(4):
                    bm.faces.new((prev[j], prev[(j + 1) % 4], ring[(j + 1) % 4], ring[j]))
            prev = ring
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
        link(new_object(f"Dome_Rib_{k:02d}", bm), chrome)
        # wall pillar at the corner
        pillar = box(f"Pillar_{k:02d}", (0.22, 0.3, ROOM_H),
                     ((ROOM_R - 0.12) * math.cos(a), (ROOM_R - 0.12) * math.sin(a), ROOM_H / 2),
                     rot=(0, 0, a + math.pi / 2), mat=pillar_mat)
        set_uv(pillar, lambda co, nrm: ((co.x / 0.22 if abs(nrm.y) > abs(nrm.x) else co.y / 0.3) + 0.5,
                                        co.z / ROOM_H + 0.5))

    lamp_index = 0
    for i in range(n):
        phi = 2 * math.pi * i / n
        out = Vector((math.cos(phi), math.sin(phi), 0))
        tan = Vector((-math.sin(phi), math.cos(phi), 0))
        rot = (0, 0, phi + math.pi / 2)  # box local x = along the wall, y = into the room

        def at(x, depth, z):
            return out * (apothem - depth) + tan * x + Vector((0, 0, z))

        wall = box(f"Wall_{i:02d}", (side_len, 0.1, ROOM_H), at(0, -0.05, ROOM_H / 2), rot=rot, mat=wall_mat)
        set_uv(wall, lambda co, nrm: (co.x / side_len + 0.5, co.z / ROOM_H + 0.5))   # one panel set per wall
        box(f"Baseboard_{i:02d}", (side_len, 0.12, 0.18), at(0, 0.06, 0.09), rot=rot, mat=orange)
        box(f"Stripe_{i:02d}", (side_len, 0.04, 0.08), at(0, 0.02, ROOM_H - 0.35), rot=rot,
            mat=orange)
        # the cornice: an orange fascia with chrome edges where the wall meets the
        # dome, a ledge under it and a glowing cove strip lighting the wall below
        ext = side_len + 0.05                      # (a little past the corners: no gaps)
        box(f"Cornice_{i:02d}", (ext, 0.05, 0.2), at(0, 0.2, ROOM_H - 0.1), rot=rot, mat=orange)
        box(f"Cornice_Ledge_{i:02d}", (ext, 0.2, 0.035), at(0, 0.1, ROOM_H - 0.215), rot=rot, mat=cream)
        for z in (ROOM_H - 0.005, ROOM_H - 0.2):
            box(f"Cornice_Edge_{i:02d}_{int(z * 100)}", (ext, 0.06, 0.018), at(0, 0.205, z), rot=rot, mat=chrome)
        box(f"Cornice_Glow_{i:02d}", (side_len - 0.1, 0.02, 0.012), at(0, 0.04, ROOM_H - 0.24), rot=rot, mat=cove)

        if i == DOOR_WALL:
            box("Door_Frame", (1.7, 0.18, 2.5), at(0, 0.04, 1.25), rot=rot, mat=chrome)
            for side, sx in (("L", -0.38), ("R", 0.38)):
                box(f"Door_{side}", (0.74, 0.1, 2.3), at(sx, 0.12, 1.17), rot=rot, mat=orange)
                box(f"Door_{side}_Stripe", (0.74, 0.02, 0.1), at(sx, 0.18, 1.3), rot=rot,
                    mat=dark)
            box("Door_Light", (1.2, 0.05, 0.08), at(0, 0.14, 2.6), rot=rot, mat=lamp)
            continue

        if i in WINDOW_WALLS:
            centre = at(0, 0.02, 1.85)
            torus(f"Porthole_{i:02d}_Frame", 0.62, 0.07, centre, mat=chrome)
            ring = bpy.context.active_object
            ring.rotation_euler = (math.pi / 2, 0, phi + math.pi / 2)
            win = screen_window(f"Porthole_{i:02d}_Space", centre + out * 0.01, -out, 0.6,
                                mat=stars)
            for k in range(8):  # bolts around the frame
                b = 2 * math.pi * k / 8
                p = centre + tan * 0.75 * math.cos(b) + Vector((0, 0, 0.75 * math.sin(b)))
                sphere(f"Porthole_{i:02d}_Bolt_{k}", 0.03, p, segs=8, rings=4, mat=chrome)
            continue

        # Console bank: desk with sloped panel, buttons, lamps and a small CRT
        style = CONSOLE_STYLES.get(i, "classic")
        body, top, trim = CONSOLE_COLORS[style]          # each show its own desk
        base_mat = material(f"Console_Body_{style}", body, roughness=0.45, metallic=0.0)
        top_mat = material(f"Console_Top_{style}", top, roughness=0.4)
        panel_c = at(0, 0.42, 0.95)
        if style in WALL_STYLES or style == "orion":     # no desk: a wall computer / Orion's round drum
            pass
        else:
            box(f"Console_{i:02d}_Base", (2.1, 0.55, 0.85), at(0, 0.35, 0.425), rot=rot, mat=base_mat)
            box(f"Console_{i:02d}_Panel", (2.1, 0.6, 0.06), panel_c,
                rot=(math.radians(-30), 0, phi + math.pi / 2), mat=top_mat)
            box(f"Console_{i:02d}_Trim", (2.12, 0.03, 0.07), at(0, 0.63, 0.74), rot=rot,   # a stripe along the front
                mat=material(f"Console_Trim_{style}", trim, roughness=0.3))
        normal = (Matrix.Rotation(phi + math.pi / 2, 4, "Z") @ Matrix.Rotation(math.radians(-30), 4, "X")
                  @ Vector((0, 0, 1, 0))).to_3d()
        up_slope = (Matrix.Rotation(phi + math.pi / 2, 4, "Z") @ Matrix.Rotation(math.radians(-30), 4, "X")
                    @ Vector((0, 1, 0, 0))).to_3d()
        rows = {}
        for row in range(2 if style == "classic" else 0):
            for col in range(8):
                p = panel_c + tan * (-0.75 + col * 0.15) + up_slope * (-0.12 + row * 0.12) + normal * 0.04
                bpy.ops.mesh.primitive_cylinder_add(vertices=12, radius=0.035, depth=0.03,
                                                    location=p)
                o = bpy.context.active_object
                o.rotation_mode = "QUATERNION"
                o.rotation_quaternion = normal.to_track_quat("Z", "Y")
                rows.setdefault((row + col) % 4, []).append(o)
        for m_i, objs in rows.items():
            link(join(objs, f"Console_{i:02d}_Buttons_{m_i}"), btn_mats[m_i])
        for k in range(6):  # blinking lamps (driven by room.gd)
            p = panel_c + tan * (0.55 + (k % 3) * 0.12) + up_slope * (0.2 - (k // 3) * 0.1) + normal * 0.035
            if style in WALL_STYLES:                      # on the wall computer's lower panel
                p = at(0.62 + (k % 3) * 0.12, 0.08, 1.32 - (k // 3) * 0.1)
            elif style == "orion":                        # round the front of the drum's rim
                t = math.radians((28, 48, 68, 112, 132, 152)[k])
                p = at(-0.57 * math.cos(t), 0.05 + 0.57 * math.sin(t), 0.875)
            sphere(f"Console_Lamp_{lamp_index:03d}", 0.025, p, segs=10, rings=5, mat=lamp)
            lamp_index += 1
        console_style(style, i, panel_c, tan, up_slope, normal, out, at, rot, chrome, dark, cream)
        if style == "orion":
            console_gimmick(at, phi, chrome)
        elif style in ("classic", "dials"):
            crt_c = at(0, 0.18, 1.32)
            box(f"Console_{i:02d}_Monitor", (0.5, 0.35, 0.38), crt_c, rot=rot, mat=cream)
            screen_window(f"Console_Screen_{i:02d}", crt_c - out * 0.18, -out, 0.15, mat=crt,
                          square=True)

        # Retro roundels on the wall above the console (not where the tape drives are)
        if style == "lis":
            continue
        discs, bezels = [], []
        for row in range(2):
            for col in range(5):
                p = at(-0.9 + col * 0.45, 0.005, 2.05 + row * 0.5)
                bpy.ops.mesh.primitive_circle_add(vertices=24, radius=0.16, fill_type="NGON",
                                                  location=p)
                o = bpy.context.active_object
                o.rotation_euler = (math.pi / 2, 0, phi + math.pi / 2)
                discs.append(o)
                bezel = torus("g", 0.168, 0.014, p - out * 0.008, mat=chrome)   # a chrome bezel: a lamp, not a blob
                bezel.rotation_euler = (math.pi / 2, 0, phi + math.pi / 2)
                bezels.append(bezel)
        link(join(discs, f"Roundels_{i:02d}"), roundel)
        link(join(bezels, f"Roundel_Bezels_{i:02d}"), chrome)

    save_and_export("room")


def console_style(style, i, panel_c, tan, up_slope, normal, out, at, rot, chrome, dark, cream):
    """The controls and the screen of one console, in the style of a 60s / 70s
    TV show (original homages, all static: baked into the room, no cost at
    runtime). "classic" / "orion": the round buttons (and a CRT / the gimmick,
    made by the caller).
      trek   rows of rectangular jewel buttons, lit; a viewer with coloured bands
      alpha  long rows of small square keys, white and orange; a slanted white monitor
      lis    toggle switches and a big red button; a 60s computer cabinet with two
             tape reels and a grid of indicator lights
      dials  three big round gauges with needles, a row of toggle switches
      ufo    a grid of flat square light tiles; a big framed wall display with a
             glowing grid and radar rings
    The panel's right end (the blinking lamps) stays free, and everything stays
    in the console's own block: within its width, under the roundels on the
    wall above (below ~1.85 m)."""
    panel = Matrix((tan, up_slope, normal)).transposed().to_4x4()        # x along, y up the slope, z out of it
    wall = Matrix((tan, -out, Vector((0, 0, 1)))).transposed().to_4x4()  # x along, y into the room, z up

    def mat(name, color, glow=0.0, rough=0.4):
        return material(name, color, roughness=rough, emission=color if glow else None, emission_strength=glow)

    def on(frame, obj, p):                       # place an object built at the origin
        obj.matrix_world = Matrix.Translation(p) @ frame @ obj.matrix_world
        return obj

    def joined(objs, name, m):
        if objs:
            link(join(objs, name), m)

    def facing_room(r, depth, centre, verts=32):  # a disc on the wall's face, its axis into the room
        o = cylinder("g", r, depth, (0, 0, 0), rot=(math.pi / 2, 0, 0), verts=verts)
        return on(wall, o, centre)

    def p_at(x, y, h=0.035):
        return panel_c + tan * x + up_slope * y + normal * h

    def toggles(x0, n, y, step=0.09):
        bases, levers = [], []
        for k in range(n):
            bases.append(on(panel, cylinder("g", 0.018, 0.02, (0, 0, 0), verts=12), p_at(x0 + k * step, y, 0.04)))
            lev = cylinder("g", 0.006, 0.07, (0, 0, 0.035), rot=(math.radians(25 if k % 3 else -25), 0, 0), verts=8)
            levers.append(on(panel, lev, p_at(x0 + k * step, y, 0.04)))
        return bases, levers

    n = f"Console_{i:02d}"
    if style == "trek":
        cols = [mat("Jewel_Red", (1.0, 0.12, 0.08), 1.6), mat("Jewel_Yellow", (1.0, 0.8, 0.1), 1.6),
                mat("Jewel_Green", (0.15, 1.0, 0.3), 1.6), mat("Jewel_Blue", (0.2, 0.5, 1.0), 1.6)]
        groups = [[] for _ in cols]
        for row in range(3):
            for col in range(9):
                k = (col * 7 + row * 3) % 4
                groups[k].append(on(panel, box("g", (0.1, 0.05, 0.022), (0, 0, 0)),
                                    p_at(-0.9 + col * 0.14, -0.17 + row * 0.11)))
        for k, g in enumerate(groups):
            joined(g, f"{n}_Jewels_{k}", cols[k])
        # the viewer: a black housing, bands of light
        c = at(0, 0.16, 1.3)
        joined([on(wall, box("g", (0.62, 0.1, 0.34), (0, 0, 0)), c)], f"{n}_Viewer", dark)
        for k, (z, m) in enumerate(((0.09, cols[3]), (0.0, cols[0]), (-0.09, cols[1]))):
            joined([on(wall, box("g", (0.54, 0.01, 0.05), (0, 0, 0)), c - out * 0.055 + Vector((0, 0, z)))],
                   f"{n}_Viewer_Band_{k}", m)
    elif style == "alpha":
        white = mat("Key_White", (0.92, 0.92, 0.88), rough=0.5)
        orange = mat("Key_Orange", (0.95, 0.45, 0.08), rough=0.5)
        keys = {0: [], 1: []}
        for row in range(4):
            for col in range(16):
                keys[1 if (col in (3, 11) or (row == 0 and col % 5 == 0)) else 0].append(
                    on(panel, box("g", (0.048, 0.048, 0.02), (0, 0, 0)), p_at(-0.92 + col * 0.082, -0.2 + row * 0.075, 0.03)))
        joined(keys[0], f"{n}_Keys", white)
        joined(keys[1], f"{n}_Keys_Orange", orange)
        # a slanted white monitor (tilted back), its screen
        tilt = Matrix.Rotation(math.radians(-14), 4, "X")
        c = at(-0.25, 0.13, 1.38)                       # (behind the keys)
        joined([on(wall @ tilt, box("g", (0.56, 0.36, 0.4), (0, 0, 0)), c)], f"{n}_Monitor", white)
        scr = on(wall @ tilt, box("g", (0.44, 0.01, 0.3), (0, 0, 0)), c - out * 0.181)
        joined([scr], f"{n}_Monitor_Screen", mat("Console_CRT_Alpha", (0.1, 0.55, 0.85), 0.9))
    elif style == "lis":
        # no desk: a wall computer from 0.75 m up. Below: a control panel with
        # light grids, toggle switches and a big red button (and the blinking lamps)
        lower = at(0, 0.03, 1.25)
        joined([on(wall, box("g", (2.0, 0.06, 0.95), (0, 0, 0)), lower)], f"{n}_Control_Wall", cream)
        joined([on(wall, box("g", (2.04, 0.12, 0.04), (0, 0, 0)), at(0, 0.06, 0.76))], f"{n}_Control_Shelf", chrome)
        front = lower - out * 0.031
        bases, levers = [], []
        for k in range(10):
            pos = front + tan * (-0.85 + k * 0.1) + Vector((0, 0, -0.3))
            bases.append(facing_room(0.018, 0.02, pos, 12))
            lev = facing_room(0.006, 0.07, pos - out * 0.035 + Vector((0, 0, 0.012 if k % 3 else -0.012)), 8)
            levers.append(lev)
        joined(bases, f"{n}_Toggle_Bases", chrome)
        joined(levers, f"{n}_Toggles", chrome)
        joined([facing_room(0.07, 0.04, front + tan * 0.3 + Vector((0, 0, -0.27)), 24)],
               f"{n}_Big_Button", mat("Big_Red", (0.9, 0.05, 0.03), 0.6, 0.3))
        grid = [[] for _ in range(3)]
        glit = [mat("Lamp_Grid_Red", (1.0, 0.15, 0.1), 2.0), mat("Lamp_Grid_Amber", (1.0, 0.6, 0.1), 2.0),
                mat("Lamp_Grid_White", (1.0, 0.95, 0.85), 1.5)]
        for row in range(4):
            for col in range(18):
                k = (row * 7 + col * 5) % 3
                grid[k].append(facing_room(0.016, 0.012, front + tan * (-0.9 + col * 0.075) + Vector((0, 0, 0.32 - row * 0.08)), 10))
        for k, g in enumerate(grid):
            joined(g, f"{n}_Panel_Lights_{k}", glit[k])
        # the 60s computer in the wall above the desk (instead of the roundels):
        # three tape units, each two reels one above the other, light grids between
        c = at(0, 0.0, 2.3)
        joined([on(wall, box("g", (2.0, 0.05, 0.86), (0, 0, 0)), c)], f"{n}_Tape_Wall", cream)
        joined([on(wall, box("g", (2.04, 0.07, 0.03), (0, 0, 0)), c + Vector((0, 0, z)))
                for z in (0.44, -0.44)], f"{n}_Tape_Wall_Trim", chrome)
        face = c - out * 0.026
        reels, hubs, windows = [], [], []
        for x in (-0.62, 0.0, 0.62):
            windows.append(on(wall, box("g", (0.38, 0.006, 0.78), (0, 0, 0)), face + tan * x))
            for z in (0.19, -0.19):
                reels.append(facing_room(0.15, 0.012, face - out * 0.006 + tan * x + Vector((0, 0, z))))
                hubs.append(facing_room(0.04, 0.03, face - out * 0.006 + tan * x + Vector((0, 0, z)), verts=12))
        joined(windows, f"{n}_Tape_Windows", mat("Tape_Window", (0.25, 0.27, 0.3), rough=0.2))
        joined(reels, f"{n}_Reels", mat("Reel_Dark", (0.05, 0.05, 0.06), rough=0.3))
        joined(hubs, f"{n}_Reel_Hubs", chrome)
        lights = [[] for _ in range(3)]
        lit = [mat("Lamp_Grid_Red", (1.0, 0.15, 0.1), 2.0), mat("Lamp_Grid_Amber", (1.0, 0.6, 0.1), 2.0),
               mat("Lamp_Grid_White", (1.0, 0.95, 0.85), 1.5)]
        for gx in (-0.31, 0.31):
            for row in range(8):
                for col in range(3):
                    k = (row * 5 + col * 3 + (gx > 0)) % 3
                    lights[k].append(facing_room(0.016, 0.012, face + tan * (gx + (col - 1) * 0.055) + Vector((0, 0, 0.3 - row * 0.085)), 10))
        for k, g in enumerate(lights):
            joined(g, f"{n}_Light_Grid_{k}", lit[k])
    elif style == "ufo":
        tiles = [[] for _ in range(3)]
        lit = [mat("Tile_Light_Blue", (0.45, 0.75, 1.0), 1.4), mat("Tile_Light_White", (0.95, 0.95, 1.0), 1.2),
               mat("Tile_Light_Amber", (1.0, 0.65, 0.15), 1.4)]
        for row in range(3):
            for col in range(13):
                k = 1 if (row + col) % 4 else (2 if col % 3 == 0 else 0)
                tiles[k].append(on(panel, box("g", (0.085, 0.085, 0.008), (0, 0, 0)), p_at(-0.92 + col * 0.105, -0.16 + row * 0.11, 0.032)))
        for k, g in enumerate(tiles):
            joined(g, f"{n}_Light_Tiles_{k}", lit[k])
        # the big wall display: a frame, a dark green screen, a grid and radar rings of light
        c = at(0, 0.1, 1.5)
        joined([on(wall, box("g", (1.1, 0.08, 0.62), (0, 0, 0)), c)], f"{n}_Display_Frame",
               mat("Display_Frame", (0.75, 0.76, 0.78), rough=0.3))
        face = c - out * 0.041
        joined([on(wall, box("g", (1.0, 0.004, 0.52), (0, 0, 0)), face)], f"{n}_Display",
               mat("Display_Screen", (0.01, 0.12, 0.08), 0.6))
        grid = []
        for k in range(-4, 5):
            grid.append(on(wall, box("g", (0.006, 0.004, 0.5), (0, 0, 0)), face - out * 0.003 + tan * (k * 0.11)))
        for k in range(-2, 3):
            grid.append(on(wall, box("g", (0.98, 0.004, 0.006), (0, 0, 0)), face - out * 0.003 + Vector((0, 0, k * 0.1))))
        for r in (0.08, 0.16, 0.23):                    # radar rings, standing in the screen's plane
            ring = torus("g", r, 0.004, (0, 0, 0))
            ring.matrix_world = (Matrix.Translation(face - out * 0.004 + tan * 0.22) @ wall
                                 @ Matrix.Rotation(math.pi / 2, 4, "X"))
            grid.append(ring)
        joined(grid, f"{n}_Display_Grid", mat("Display_Grid", (0.3, 1.0, 0.55), 2.0))
    elif style == "dials":
        faces, rims, needles = [], [], []
        for k in range(3):
            pc = p_at(-0.75 + k * 0.33, 0.04, 0.04)
            faces.append(on(panel, cylinder("g", 0.11, 0.02, (0, 0, 0), verts=32), pc))
            rims.append(on(panel, torus("g", 0.112, 0.012, (0, 0, 0.012)), pc))
            nd = box("g", (0.006, 0.09, 0.006), (0, 0.035, 0.024))
            nd.rotation_euler = (0, 0, math.radians((-50, 20, 65)[k]))
            bpy.context.view_layer.update()
            nd.data.transform(nd.matrix_basis)
            nd.matrix_basis = Matrix.Identity(4)
            needles.append(on(panel, nd, pc))
        joined(faces, f"{n}_Gauges", mat("Gauge_Face", (0.95, 0.93, 0.85), rough=0.6))
        joined(rims, f"{n}_Gauge_Rims", chrome)
        joined(needles, f"{n}_Gauge_Needles", mat("Gauge_Needle", (0.85, 0.1, 0.05)))
        bases, levers = toggles(-0.85, 12, -0.2, 0.1)
        joined(bases, f"{n}_Toggle_Bases", chrome)
        joined(levers, f"{n}_Toggles", chrome)


def boat_outline(length, width, n=24):
    """A 60s clothes iron's sole seen from above: pointed at the front (+X),
    round at the heel (CCW points)."""
    pts = []
    for k in range(n):
        t = 2 * math.pi * k / n
        x, y = math.cos(t), math.sin(t)
        x = x if x < 0 else x ** 1.6                   # long, narrowing nose
        y *= (1 - max(x, 0) * 0.75)                    # pointed tip
        pts.append((x * length / 2, y * width / 2))
    return pts


def console_gimmick(at, phi, chrome):
    """Orion: a homage to 1960s TV sci-fi bridges built from household things.
    A half-round drum against the wall (instead of a desk) - brushed aluminium,
    a black top with a chrome band, chrome dome studs round its edge - with, set
    into the top, a tilted pale "acrylic" disc studded with dome nuts and
    grooved rings, a clothes iron lying on it as the control lever, a finned
    rod rising behind it and a small disc standing on its edge at the side.
    Static and baked into the room like the rest (no cost at runtime); the six
    blinking lamps on the rim are made by the caller. 1.24 m wide, 0.62 m deep,
    under the roundels."""
    acrylic = material("Gimmick_Acrylic", (0.55, 0.66, 0.74), roughness=0.08)
    black = material("Gimmick_Black", (0.02, 0.02, 0.025), roughness=0.25)
    alu = material("Gimmick_Alu", (0.62, 0.64, 0.67), roughness=0.35)
    # the wall's frame at the floor: x along the wall, y into the room, z up
    tan = Vector((-math.sin(phi), math.cos(phi), 0))
    inward = Vector((-math.cos(phi), -math.sin(phi), 0))
    frame = Matrix((tan, inward, Vector((0, 0, 1)))).transposed().to_4x4()
    origin = at(0, 0.05, 0)                     # the drum's centre, against the wall

    def place(obj, m=None):
        obj.matrix_world = Matrix.Translation(origin) @ frame @ (m or Matrix.Identity(4)) @ obj.matrix_world
        return obj

    def half_round(r, n=32):                    # a half disc, its flat side on the wall (CCW)
        return [(r * math.cos(math.pi * k / n), r * math.sin(math.pi * k / n)) for k in range(n + 1)]

    place(prism("Gimmick_Drum", half_round(0.6), 0.0, 0.82, mat=alu))
    place(prism("Gimmick_Drum_Band", half_round(0.612), 0.80, 0.83, mat=chrome))
    place(prism("Gimmick_Drum_Top", half_round(0.62), 0.83, 0.86, mat=black))
    studs = []
    for k in range(1, 18):                      # dome studs round the top's edge
        t = math.pi * k / 18
        stud = sphere("g", 0.014, (0.585 * math.cos(t), 0.585 * math.sin(t), 0.862), segs=10, rings=5, mat=chrome)
        stud.scale.z = 0.6
        studs.append(stud)
    bpy.context.view_layer.update()
    place(join(studs, "Gimmick_Drum_Studs"))

    # the studded disc, set into the top and tilted to the room
    tilt = Matrix.Translation((0, 0.27, 0.9)) @ Matrix.Rotation(math.radians(-14), 4, "X")
    R = 0.27
    place(cylinder("Gimmick_Disc", R, 0.012, (0, 0, 0), verts=64, mat=acrylic), tilt)
    parts = [cylinder("g", R + 0.012, 0.03, (0, 0, -0.02), verts=48, mat=chrome)]    # its chrome collar
    for k in range(16):
        a = 2 * math.pi * k / 16
        stud = sphere("g", 0.012, (math.cos(a) * (R - 0.025), math.sin(a) * (R - 0.025), 0.006), segs=10, rings=5, mat=chrome)
        stud.scale.z = 0.6
        parts.append(stud)
    rng = (0.11, 0.17, 0.62, 0.81, 0.24, 0.47, 0.93, 0.36)  # (fixed: the same every build)
    for k in range(8):
        a, r = 2 * math.pi * rng[k], 0.07 + 0.13 * rng[(k + 3) % 8]
        stud = sphere("g", 0.01, (math.cos(a) * r, math.sin(a) * r, 0.006), segs=10, rings=5, mat=chrome)
        stud.scale.z = 0.6
        parts.append(stud)
    for r in (0.12, 0.17, 0.21):                # grooved rings
        parts.append(torus("g", r, 0.0018, (0, 0, 0.0065), mat=chrome))
    bpy.context.view_layer.update()
    place(join(parts, "Gimmick_Studs"), tilt)

    # the iron: chrome sole, black body, a handle on two posts, lying on the disc
    iron = [prism("Gimmick_Iron", boat_outline(0.21, 0.115), 0.006, 0.018, mat=chrome),
            prism("g", boat_outline(0.18, 0.09), 0.018, 0.058, mat=black),
            box("g", (0.13, 0.024, 0.024), (-0.01, 0, 0.105), mat=black),
            box("g", (0.022, 0.02, 0.05), (0.04, 0, 0.078), rot=(0, math.radians(-20), 0), mat=black),
            box("g", (0.022, 0.02, 0.05), (-0.065, 0, 0.078), mat=black)]
    iron_obj = join(iron, "Gimmick_Iron")
    iron_obj.rotation_euler = (0, 0, math.radians(25))
    place(iron_obj, tilt)

    # the finned rod: from the top behind the disc, up and to the left (under the roundels)
    d = Vector((-0.45, -0.2, 0.87)).normalized()
    base = Vector((-0.3, 0.12, 0.86))
    rod = cylinder("Gimmick_Fins", 0.009, 0.5, base + d * 0.25, verts=12, mat=chrome)
    rod.rotation_mode = "QUATERNION"
    rod.rotation_quaternion = d.to_track_quat("Z", "Y")
    fins = [rod]
    for k in range(9):
        fin = cylinder("g", 0.05 - k * 0.002, 0.004, base + d * (0.26 + k * 0.025), verts=24, mat=chrome)
        fin.rotation_mode = "QUATERNION"
        fin.rotation_quaternion = d.to_track_quat("Z", "Y")
        fins.append(fin)
    bpy.context.view_layer.update()
    place(join(fins, "Gimmick_Fins"))

    # a small pale disc on its edge at the right, with a chrome hub and stand
    spin = cylinder("Gimmick_Spinner", 0.13, 0.006, (0.42, 0.2, 1.02), rot=(math.pi / 2, 0, 0), verts=48, mat=acrylic)
    hub = cylinder("g", 0.02, 0.03, (0.42, 0.2, 1.02), rot=(math.pi / 2, 0, 0), verts=16, mat=chrome)
    stand = cylinder("g", 0.012, 0.04, (0.42, 0.2, 0.875), verts=10, mat=chrome)
    place(join([spin, hub, stand], "Gimmick_Spinner"))


def oriented_disc(name, centre, normal, r, segs=40, mat=None):
    """Round disc facing `normal`, UVs 0..1 across it."""
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    pts = [(math.cos(2 * math.pi * k / segs), math.sin(2 * math.pi * k / segs)) for k in range(segs)]
    face = bm.faces.new([bm.verts.new((u * r, v * r, 0)) for u, v in pts])
    for loop, (u, v) in zip(face.loops, pts):
        loop[uv].uv = (u * 0.5 + 0.5, v * 0.5 + 0.5)
    obj = new_object(name, bm)
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = Vector(normal).to_track_quat("Z", "Y")
    obj.location = centre
    return link(obj, mat)


def screen_window(name, centre, facing, r, mat=None, square=False):
    """Round (or square) window facing `facing`, UVs 0..1 across it."""
    d = Vector(facing).normalized()
    right = Vector((-d.y, d.x, 0))
    up = Vector((0, 0, 1))
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    if square:
        pts = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
    else:
        pts = [(math.cos(2 * math.pi * k / 40), math.sin(2 * math.pi * k / 40)) for k in range(40)]
    face = bm.faces.new([bm.verts.new(Vector(centre) + right * (u * r) + up * (v * r * (0.75 if square else 1)))
                         for u, v in pts])
    for loop, (u, v) in zip(face.loops, pts):
        loop[uv].uv = (u * 0.5 + 0.5, v * 0.5 + 0.5)
    if face.normal.dot(d) < 0:
        face.normal_flip()
    return link(new_object(name, bm), mat)


# ---------------------------------------------------------------- drone

DRONE_R = 0.20         # body radius: a flying mini tile for a mobile player
DRONE_TOP = 0.030      # top plate (LEDs, hearts)
DRONE_GLASS_TOP = 0.044
DRONE_LED_R = 0.172
DRONE_K = DRONE_LED_R / LED_RING_R   # the tile's top layout scaled to the drone (~0.57)
DRONE_BUTTON_R = BUTTON_R * DRONE_K
DRONE_ARM_R = 0.31     # body centre -> rotor centre
DRONE_ROTOR_R = 0.10


def build_drone():
    """Mobile player's drone: the tile's API (LED_00..47, Heart_0..4,
    Button_<name>[_Symbol], Status_LED) on a small round body with 4 ducted
    rotors (Rotor_0..3 spin in Godot), a glow underneath (Thruster) and a light
    band around the rim (Drone_Band), both in the player's colour. +Y = forward (to the robot), like the tile."""
    reset_scene()
    white = material("Tile_White", (0.86, 0.86, 0.84), roughness=0.7)
    alu = material("Tile_Aluminium", (0.75, 0.76, 0.78), metallic=0.8, roughness=0.35)
    black = material("Tile_Black", (0.02, 0.02, 0.02), roughness=0.8)
    led = material("LED", (0.15, 0.15, 0.15), roughness=0.3, emission=(0, 0, 0))
    sym = material("Button_Symbol", (0.95, 0.95, 0.95), roughness=0.9, emission=(0, 0, 0),
                   alpha=0.8)
    glass = material("Glass", (0.9, 0.97, 0.97), roughness=0.0, alpha=0.06)
    blade = material("Rotor_Blade", (0.08, 0.08, 0.09), metallic=0.3, roughness=0.4)
    glow = material("Thruster", (0.1, 0.1, 0.1), roughness=0.3, emission=(0, 0, 0))

    # body: a flat disc, rounded underside, aluminium rim
    cylinder("Drone_Body", DRONE_R, 0.026, (0, 0, 0.013), verts=64, mat=black)
    # only the lower half: a whole sphere pokes its black top through the top plate and the glass
    hull = hemisphere("Drone_Hull", DRONE_R * 0.92, (0, 0, 0.0), (0, 0, -1), mat=black, segs=48, rings=16)
    hull.scale.z = 0.28
    tube("Drone_Rim", DRONE_R - 0.008, DRONE_R + 0.006, 0.0, DRONE_GLASS_TOP + 0.002, segs=64, mat=alu)
    band = material("Drone_Band", (0.1, 0.1, 0.1), roughness=0.3, emission=(0, 0, 0))
    tube("Drone_Band", DRONE_R + 0.006, DRONE_R + 0.011, 0.008, 0.026, segs=64, mat=band)   # player's colour
    cylinder("Drone_Top", DRONE_R - 0.01, 0.004, (0, 0, DRONE_TOP - 0.002), verts=64, mat=white)
    annulus("Drone_LED_Channel", DRONE_LED_R - 0.007, DRONE_LED_R + 0.007, DRONE_TOP + 0.0008,
            segs=64, mat=black)
    for i in range(LED_COUNT):     # LED_00 at the front (+Y), clockwise from above
        a = math.pi / 2 - 2 * math.pi * i / LED_COUNT
        box(f"LED_{i:02d}", (0.009, 0.006, 0.003),
            (DRONE_LED_R * math.cos(a), DRONE_LED_R * math.sin(a), DRONE_TOP + 0.002),
            rot=(0, 0, a + math.pi / 2), mat=led)
    # the same top as a floor tile, scaled: the logo in the middle, the hearts
    # between the logo and the LED ring towards the front, screws in the rim
    tex_path = os.path.join(GODOT_DIR, "textures", "yin_yang_01.png")
    if os.path.exists(tex_path):
        img = bpy.data.images.load(tex_path)
        img.pack()
    else:
        img = yin_yang_image(tex_path)
    disc("Logo", 0.16 * DRONE_K, DRONE_TOP + 0.0012, mat=image_material("Logo_YinYang", img))
    box("Heart_Wire", (0.002, 0.13 * DRONE_K, 0.001), (0, 0.235 * DRONE_K, DRONE_TOP + 0.0006), mat=black)
    for i in range(HEART_COUNT):   # Heart_0 nearest the logo, Heart_4 nearest the rim
        y = (0.18 + i * 0.024) * DRONE_K
        prism(f"Heart_{i}_Frame", heart_outline(0.026 * DRONE_K), DRONE_TOP, DRONE_TOP + 0.0025,
              loc=(0, y, 0), mat=black)
        prism(f"Heart_{i}", heart_outline(0.019 * DRONE_K), DRONE_TOP, DRONE_TOP + 0.0035,
              loc=(0, y, 0), mat=led)
    for i in range(12):            # rim screws
        a = 2 * math.pi * (i + 0.5) / 12
        cylinder(f"Screw_{i:02d}", 0.0045, 0.003,
                 ((DRONE_R - 0.001) * math.cos(a), (DRONE_R - 0.001) * math.sin(a), DRONE_GLASS_TOP + 0.003),
                 verts=12, mat=alu)
    glass_plate = cylinder("Glass_Plate", DRONE_R - 0.012, 0.004,
                           (0, 0, DRONE_GLASS_TOP - 0.002), verts=64, mat=glass)
    etched_buttons(glass_plate, DRONE_GLASS_TOP, DRONE_BUTTON_R, DRONE_K, sym)

    # 4 arms with ducted rotors (diagonals, clear of the front)
    for k in range(4):
        a = math.radians(45 + 90 * k)
        cx, cy = DRONE_ARM_R * math.cos(a), DRONE_ARM_R * math.sin(a)
        mid = (DRONE_R + DRONE_ARM_R - DRONE_ROTOR_R) / 2
        box(f"Arm_{k}", (DRONE_ARM_R - DRONE_ROTOR_R - DRONE_R + 0.03, 0.03, 0.016),
            (mid * math.cos(a), mid * math.sin(a), 0.012), rot=(0, 0, a), mat=alu)
        tube(f"Duct_{k}", DRONE_ROTOR_R, DRONE_ROTOR_R + 0.012, -0.012, 0.03, segs=48, mat=black)
        duct = bpy.data.objects[f"Duct_{k}"]
        duct.location = (cx, cy, 0)
        torus(f"Duct_Lip_{k}", DRONE_ROTOR_R + 0.006, 0.006, (cx, cy, 0.03), mat=alu)
        hub = cylinder(f"Rotor_{k}", 0.014, 0.012, (cx, cy, 0.016), verts=16, mat=alu)
        for b in range(2):
            blade_obj = box(f"Rotor_{k}_Blade_{b}", (DRONE_ROTOR_R * 1.8, 0.018, 0.003),
                            (cx, cy, 0.016), rot=(0.25 if b == 0 else -0.25, 0, math.pi / 2 * b), mat=blade)
            set_parent(blade_obj, hub)

    # glow underneath (the player's colour) and the antenna with the status LED
    disc("Thruster", DRONE_R * 0.55, 0.058, segs=48, mat=glow)
    bpy.data.objects["Thruster"].rotation_euler = (math.pi, 0, 0)  # flipped: 5.8 cm below, facing down
    cylinder("Antenna", 0.003, 0.09, (0, -DRONE_R + 0.03, DRONE_GLASS_TOP + 0.045), verts=8, mat=alu)
    sphere("Status_LED", 0.009, (0, -DRONE_R + 0.03, DRONE_GLASS_TOP + 0.092), segs=12, rings=6, mat=led)

    save_and_export("drone")


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else ["all"]
    what = argv[0] if argv else "all"
    if what in ("tile", "all"):
        build_tile()
    if what in ("robot", "all"):
        build_robot()
    if what in ("arena", "all"):
        build_arena()
    if what in ("room", "all"):
        build_room()
    if what in ("drone", "all"):
        build_drone()
