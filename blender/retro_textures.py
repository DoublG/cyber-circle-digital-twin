"""Procedural 70s sci-fi textures for the room (numpy only, deterministic).

Each generator returns (albedo, height): float arrays, albedo (h, w, 3) and
height (h, w), row 0 = the bottom of the image (Blender's pixel order). The
room is baked (bake_models.py), so these end up inside the two baked atlases:
no extra texture or draw call at runtime. The height goes into a Bump node,
so the bake also bakes the light and shadow of the seams and grooves.

The baked atlas has ~5-6 mm per pixel on the walls and floor: keep the
features bold (panels, seams, ribs, rings), nothing finer than ~1 cm.

    wall_panels()    cream wall: 2 x 3 padded panels, orange waist stripe, screws
    pillar_ribs()    teal pillar: vertical ribs, chrome joint bands with bolts
    floor_deck()     the whole round floor: concentric deck plates, an orange
                     dashed circle round the play area, a vent band at the wall
    dome_quilt()     navy dome, one bay between two ribs: tufted (quilted) panels
"""

import math

import numpy as np


# ---------------------------------------------------------------- helpers

def grid(w, h, sx, sy):
    """Coordinates in metres: x 0..sx across, y 0..sy up (pixel centres)."""
    x = (np.arange(w) + 0.5) / w * sx
    y = (np.arange(h) + 0.5) / h * sy
    return np.meshgrid(x, y)


def rrect_sd(x, y, x0, y0, x1, y1, r):
    """Signed distance to a rounded rectangle (negative inside)."""
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    hx, hy = (x1 - x0) / 2 - r, (y1 - y0) / 2 - r
    qx, qy = np.abs(x - cx) - hx, np.abs(y - cy) - hy
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r


def value_noise(w, h, cells_x, cells_y, seed):
    """Smooth tileable noise 0..1 (bilinear on a random grid, wraps)."""
    rng = np.random.default_rng(seed)
    g = rng.random((cells_y, cells_x))
    fx = np.arange(w) / w * cells_x
    fy = np.arange(h) / h * cells_y
    x0, y0 = np.floor(fx).astype(int), np.floor(fy).astype(int)
    tx, ty = fx - x0, fy - y0
    tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)        # smoothstep
    x1, y1 = (x0 + 1) % cells_x, (y0 + 1) % cells_y
    a = g[np.ix_(y0, x0)] * (1 - tx) + g[np.ix_(y0, x1)] * tx
    b = g[np.ix_(y1, x0)] * (1 - tx) + g[np.ix_(y1, x1)] * tx
    return a * (1 - ty)[:, None] + b * ty[:, None]


def mix(a, b, t):
    t = np.clip(t, 0, 1)[..., None]
    return a * (1 - t) + b * t


def color(c, shape):
    return np.broadcast_to(np.array(c, dtype=np.float32), (*shape, 3)).copy()


def bevel(sd, width):
    """Height across a seam: 0 in the groove, rising to 1 over `width` inside."""
    return np.clip(-sd / width, 0, 1) ** 0.7


# ---------------------------------------------------------------- textures

def wall_panels(w=1024, h=1024, sx=2.58, sy=3.6):
    """One wall section (sx m wide, sy m high): two columns of padded panels in
    three rows, a seam between them, screws in the panel corners, an orange
    pinstripe at waist height and a little grime towards the floor."""
    x, y = grid(w, h, sx, sy)
    rng = np.random.default_rng(3)
    cream = np.array((0.80, 0.76, 0.64))
    alb = color(cream * 0.93, x.shape)                                # the frame between the panels
    height = np.full(x.shape, 0.6)
    seam_d = np.full(x.shape, 9.0)                                    # distance to the nearest panel edge
    rows = ((0.20, 1.00), (1.06, 2.36), (2.42, 3.22))
    seam, rad = 0.012, 0.07
    for r0, r1 in rows:
        for c in range(2):
            x0, x1 = c * sx / 2 + seam, (c + 1) * sx / 2 - seam
            sd = rrect_sd(x, y, x0, r0, x1, r1, rad)
            inside = sd < 0
            tone = 1.0 + rng.uniform(-0.035, 0.035)                    # panels never quite match
            alb[inside] = cream * tone
            seam_d = np.minimum(seam_d, np.abs(sd))
            height = np.where(inside, 0.6 + 0.4 * bevel(sd, 0.03), height)
            # a padded panel: lighter in the middle, shaded towards its edge
            pad = np.clip(-sd / 0.25, 0, 1)
            alb *= (1.0 + 0.05 * pad * inside)[..., None]
            for sx_, sy_ in ((x0 + 0.05, r0 + 0.05), (x1 - 0.05, r0 + 0.05), (x0 + 0.05, r1 - 0.05), (x1 - 0.05, r1 - 0.05)):
                d = np.hypot(x - sx_, y - sy_)
                screw = d < 0.011
                alb[screw] = (0.45, 0.43, 0.40)
                height = np.where(d < 0.013, np.minimum(height, 0.55 + 0.3 * (d / 0.013)), height)
    groove = seam_d < 0.009                                           # a thin dark seam round each panel
    alb[groove] = (0.30, 0.28, 0.25)
    height = np.where(seam_d < 0.012, np.minimum(height, seam_d / 0.012 * 0.6), height)
    # orange pinstripe in the gap between the bottom and middle row (waist height)
    stripe = np.abs(y - 1.03) < 0.012
    alb[stripe] = (0.85, 0.35, 0.06)
    height[stripe] = 0.4
    # grime: a little darker towards the floor, in soft blotches
    n = value_noise(w, h, 6, 8, 11)
    alb *= (1.0 - 0.10 * np.clip(1.0 - y / 1.2, 0, 1) * (0.5 + n))[..., None]
    alb *= (0.97 + 0.03 * value_noise(w, h, 24, 32, 12))[..., None]
    return alb.astype(np.float32), height.astype(np.float32)


def pillar_ribs(w=256, h=1024, sx=0.3, sy=3.6):
    """Teal pillar face: three vertical ribs, chrome joint bands every 0.6 m
    with a bolt each side, darker at the foot."""
    x, y = grid(w, h, sx, sy)
    teal = np.array((0.05, 0.38, 0.40))
    ribs = 0.5 + 0.5 * np.cos(x / sx * 3 * 2 * math.pi)
    height = np.clip(ribs * 1.4 - 0.2, 0, 1)                       # flat-topped ribs, rounded grooves
    alb = color(teal, x.shape) * (0.75 + 0.35 * height)[..., None]
    alb *= (1.0 + 0.12 * np.exp(-((x - sx * 0.35) / (sx * 0.2)) ** 2))[..., None]   # a soft sheen
    for j in range(1, 6):
        band = np.abs(y - j * 0.6) < 0.025
        alb[band] = (0.62, 0.64, 0.68)
        height[band] = 0.9
        edge = np.abs(np.abs(y - j * 0.6) - 0.025) < 0.004
        height[edge] = 0.3
        for bx in (sx * 0.2, sx * 0.8):
            bolt = np.hypot(x - bx, y - j * 0.6) < 0.012
            alb[bolt] = (0.35, 0.36, 0.38)
            height[bolt] = 1.0
    foot = y < 0.2
    alb[foot] *= 0.6
    return alb.astype(np.float32), height.astype(np.float32)


def floor_deck(size=2048, radius=6.6, tile_r=2.5):
    """The whole floor seen from above (x, y from -radius to radius): deck
    plates in concentric rings with staggered radial seams, each plate a
    slightly different shade, an orange dashed circle round the play area and
    a band of vent slots along the wall."""
    x, y = grid(size, size, 2 * radius, 2 * radius)
    x, y = x - radius, y - radius
    r = np.hypot(x, y)
    a = np.arctan2(y, x)
    base = np.array((0.042, 0.042, 0.048))
    alb = color(base, x.shape)
    height = np.ones(x.shape)
    ring_w = 0.8
    ring = np.floor(r / ring_w).astype(int)
    d_ring = np.abs(r - np.round(r / ring_w) * ring_w)               # to the nearest ring seam
    n_seg = np.maximum(8, np.round(2 * np.pi * (ring + 0.5) * ring_w / 1.3 / 4) * 4).astype(int)
    seg_f = (a / (2 * np.pi) + 0.5) * n_seg + (ring % 2) * 0.5      # staggered like brickwork
    seg = np.floor(seg_f).astype(int)
    d_seg = np.abs(seg_f - np.round(seg_f)) / n_seg * 2 * np.pi * np.maximum(r, 0.01)
    d = np.minimum(d_ring, np.where(ring >= 1, d_seg, 9.0))         # (no radial seams under the robot)
    height = bevel(-(d - 0.008), 0.02)
    # each plate its own shade
    h_ = (ring * 7919 + seg * 104729) % 1000 / 1000.0
    alb *= (0.88 + 0.24 * h_)[..., None]
    groove = d < 0.008
    alb[groove] = (0.018, 0.018, 0.02)
    # orange dashed circle round the play area (outside the tiles)
    rc = tile_r + 0.75
    dash = (np.floor((a / (2 * np.pi) + 0.5) * 48) % 2) == 0
    line = (np.abs(r - rc) < 0.03) & dash
    alb[line] = (0.85, 0.35, 0.06)
    height[line] = 1.0
    # vent band along the wall: radial slots
    vent = (r > radius - 0.75) & (r < radius - 0.2)
    slot = (np.abs(((a / (2 * np.pi) + 0.5) * 400) % 1.0 - 0.5) < 0.18) & vent
    alb[slot] = (0.012, 0.012, 0.014)
    height[slot] = 0.0
    frame = vent & ~slot
    alb[frame] = (0.10, 0.10, 0.11)
    # scuffs where people walk (the ring round the tiles)
    n = value_noise(size, size, 40, 40, 21)
    walk = np.exp(-((r - rc) / 0.6) ** 2)
    alb *= (1.0 + 0.10 * walk * (n - 0.5))[..., None]
    return alb.astype(np.float32), height.astype(np.float32)


def dome_quilt(w=1024, h=1024, rows=8):
    """One bay of the dome (u across the bay, v along the dome from the wall
    top to the oculus): tufted panels - each a cushion, lighter in the middle,
    a dark button dimple in the centre, dark seams between them and thin
    light piping. Two panels across the bay low down, one higher up (where
    the bay narrows). Strong contrast: the baked atlas softens it."""
    u = (np.arange(w) + 0.5) / w
    v = (np.arange(h) + 0.5) / h
    u, v = np.meshgrid(u, v)
    seam = np.array((0.008, 0.01, 0.022))
    alb = color(seam, u.shape)                     # the seams: deep, almost black navy
    height = np.zeros(u.shape)
    piping = np.zeros(u.shape)
    for row in range(rows):
        v0, v1 = row / rows, (row + 1) / rows
        cols = 2 if row < rows // 2 else 1
        for c in range(cols):
            u0, u1 = c / cols, (c + 1) / cols
            sd = rrect_sd(u * 2, v * 2, u0 * 2 + 0.03, v0 * 2 + 0.03, u1 * 2 - 0.03, v1 * 2 - 0.03, 0.07)
            inside = sd < 0
            cx, cy = (u0 + u1), (v0 + v1)
            dc = np.hypot(u * 2 - cx, v * 2 - cy)
            cushion = np.clip(-sd / 0.1, 0, 1) ** 0.55
            dimple = np.exp(-(dc / 0.045) ** 2)
            height = np.where(inside, np.maximum(height, cushion * (1.0 - 0.8 * dimple)), height)
            shade = (0.025 + 0.075 * cushion) * (1.0 - 0.75 * dimple)        # dark at the edge, light in the middle
            panel = np.stack([shade * 0.62, shade * 0.75, shade * 1.45], axis=-1)
            alb = np.where(inside[..., None], panel, alb)
            alb[dc < 0.014] = (0.01, 0.012, 0.03)
            piping = np.maximum(piping, np.exp(-((sd + 0.012) / 0.0035) ** 2) * inside)   # just inside the edge
    alb = mix(alb, np.array((0.22, 0.27, 0.40)), piping * 0.7)
    height = np.maximum(height, piping * 0.4)
    return alb.astype(np.float32), height.astype(np.float32)
