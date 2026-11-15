"""The tile's top as SVG (tile_top.svg) - the same measurements as the 3D model
(assets/blender/build_models.py: build_tile), 1 px = 1 mm, seen from above with the
robot at the top. Every part the firmware lights has an id the emulator's web
view colours live:  led_0 .. led_47 (the outer ring: LED_00 = towards the robot,
then clockwise), inled_0 .. inled_47 (the inner ring around the logo, counted
the same way), glow_0 .. glow_47 (the plate the rings light up, a sector per
LED: the real tile's lighting effect), heart_0 .. heart_4 (heart 1 nearest the
logo), icon_Square, icon_Triangle, icon_Cross, icon_Circle (the icons on their
dark pucks, lit from below; click = press). No status LED (the built tiles have none).
    python3 make_tile_svg.py      (writes tile_top.svg and tile_top_svg.h, the emulator's copy)
"""
import os
import math

TILE_R, GLASS_R, LED_RING_R, INNER_RING_R = 350, 322, 304, 168
BUTTON_R = (INNER_RING_R + 7 + LED_RING_R - 9) / 2   # halfway between the rings (235), as in the model
PUCK_R, ICON_K = 50, 0.95
BUTTONS = {"Triangle": 45, "Square": 135, "Cross": 225, "Circle": 315}   # deg CCW from +X; +Y = the robot
LEDS, HEARTS = 48, 5
HEART_Y0, HEART_STEP, HEART_SIZE = 188, 23.5, 23


def xy(r, deg):                                    # model (x right, y to the robot) -> SVG (y down)
    a = math.radians(deg)
    return r * math.cos(a), -r * math.sin(a)


def heart(cx, cy, size):                           # the heart outline of the model (heart_outline)
    pts = []
    for i in range(40):
        t = 2 * math.pi * i / 40
        hx = 16 * math.sin(t) ** 3
        hy = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        s = size / 32
        pts.append(f"{cx + hx * s:.1f},{cy - (hy + 2.5) * s:.1f}")
    return "M" + " L".join(pts) + " Z"


out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="-380 -400 760 800" font-family="DejaVu Sans Mono, monospace">',
       '<defs>',
       '<radialGradient id="glass" cx="35%" cy="30%" r="80%"><stop offset="0" stop-color="#ffffff" stop-opacity=".18"/>'
       '<stop offset=".6" stop-color="#cfe9ec" stop-opacity=".05"/><stop offset="1" stop-color="#ffffff" stop-opacity=".12"/></radialGradient>',
       '<radialGradient id="rim" cx="50%" cy="50%" r="50%"><stop offset=".9" stop-color="#9aa0a6"/><stop offset="1" stop-color="#5d6268"/></radialGradient>',
       '<filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="4" result="b"/>'
       '<feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>',
       '</defs>',
       '<text x="0" y="-372" text-anchor="middle" font-size="18" fill="#8c7a66">▲ ROBOT</text>',
       # body: aluminium rim, white top plate, the LED channel
       f'<circle r="{TILE_R}" fill="url(#rim)"/>',
       f'<circle r="{TILE_R - 4}" fill="#dcdcd6"/>']
# the plate the two rings light up: a sector per LED, coloured live (transparent while dark)
for i in range(LEDS):
    a0, a1 = 90 - 360 * (i - 0.5) / LEDS, 90 - 360 * (i + 0.5) / LEDS
    (x0, y0), (x1, y1) = xy(INNER_RING_R + 7, a0), xy(INNER_RING_R + 7, a1)
    (x2, y2), (x3, y3) = xy(GLASS_R - 2, a1), xy(GLASS_R - 2, a0)
    out.append(f'<path id="glow_{i}" d="M{x0:.1f},{y0:.1f} A{INNER_RING_R + 7},{INNER_RING_R + 7} 0 0 1 {x1:.1f},{y1:.1f} '
               f'L{x2:.1f},{y2:.1f} A{GLASS_R - 2},{GLASS_R - 2} 0 0 0 {x3:.1f},{y3:.1f} Z" fill="none" stroke="none" stroke-width="1.2"/>')
# the LED channels on top of the glow (dark, as on the tile)
out.append(f'<circle r="{LED_RING_R}" fill="none" stroke="#111" stroke-width="18"/>')
out.append(f'<circle r="{INNER_RING_R}" fill="none" stroke="#111" stroke-width="14"/>')
# the 4 floor plates' seams (left, right, bottom)
out.append('<g stroke="#222" stroke-width="4"><line x1="-310" y1="0" x2="-160" y2="0"/><line x1="160" y1="0" x2="310" y2="0"/>'
           '<line x1="0" y1="160" x2="0" y2="310"/></g>')
# the logo: yin-yang
out.append('<g transform="scale(1)"><circle r="160" fill="#f2f2ee" stroke="#111" stroke-width="3"/>'
           '<path d="M0,-160 A160,160 0 0 0 0,160 A80,80 0 0 0 0,0 A80,80 0 0 1 0,-160 Z" fill="#111"/>'
           '<circle cy="-80" r="22" fill="#f2f2ee"/><circle cy="80" r="22" fill="#111"/></g>')
# the hearts, from the logo towards the robot, on a dark strip with a light outline (as in the model)
h = HEART_STEP * (HEARTS - 1) + HEART_SIZE + 8
out.append(f'<rect x="{-(HEART_SIZE + 12) / 2:.1f}" y="{-(HEART_Y0 + HEART_STEP * (HEARTS - 1) / 2) - h / 2:.1f}" '
           f'width="{HEART_SIZE + 12}" height="{h:.1f}" fill="#111"/>')
for i in range(HEARTS):
    y = -(HEART_Y0 + i * HEART_STEP)
    out.append(f'<path d="{heart(0, y, HEART_SIZE + 5)}" fill="#dcdcd6"/>')
    out.append(f'<path id="heart_{i}" d="{heart(0, y, HEART_SIZE)}" fill="#260006"/>')
# the LED ring: LED_00 at the robot, clockwise seen from above
for i in range(LEDS):
    deg = 90 - 360 * i / LEDS
    x, y = xy(LED_RING_R, deg)
    rot = -deg + 90
    out.append(f'<rect id="led_{i}" x="{x - 6:.1f}" y="{y - 3.5:.1f}" width="12" height="7" rx="1.5" '
               f'transform="rotate({rot:.1f} {x:.1f} {y:.1f})" fill="#262626"/>')
    x, y = xy(INNER_RING_R, deg)
    out.append(f'<rect id="inled_{i}" x="{x - 4:.1f}" y="{y - 3:.1f}" width="8" height="6" rx="1.2" '
               f'transform="rotate({rot:.1f} {x:.1f} {y:.1f})" fill="#262626"/>')
# the glass plate on spacers
for k in range(8):
    x, y = xy(270, 22.5 + 45 * k)
    out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="6" fill="#cfe3e6" opacity=".6"/>')
out.append(f'<circle r="{GLASS_R}" fill="url(#glass)" stroke="#e8f6f8" stroke-opacity=".5" stroke-width="2"/>')
# the etched icons (lit from below), with a big invisible target to click
for name, deg in BUTTONS.items():
    cx, cy = xy(BUTTON_R, deg)
    k, sw = ICON_K, 9 * ICON_K
    out.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{PUCK_R}" fill="#151515"/>')   # the dark puck
    if name == "Square":
        shape = f'<rect x="{cx - 31 * k:.1f}" y="{cy - 31 * k:.1f}" width="{62 * k:.1f}" height="{62 * k:.1f}" fill="none" stroke-width="{sw:.1f}"/>'
    elif name == "Triangle":
        p = [xy(42 * k, 90 + 120 * j) for j in range(3)]
        pts = " ".join(f"{cx + px:.1f},{cy + py:.1f}" for px, py in p)
        shape = f'<polygon points="{pts}" fill="none" stroke-width="{sw:.1f}" stroke-linejoin="round"/>'
    elif name == "Cross":
        d = 29 * k
        shape = (f'<path d="M{cx - d:.1f},{cy - d:.1f} L{cx + d:.1f},{cy + d:.1f} M{cx + d:.1f},{cy - d:.1f} '
                 f'L{cx - d:.1f},{cy + d:.1f}" fill="none" stroke-width="{sw:.1f}" stroke-linecap="round"/>')
    else:
        shape = f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{33 * k:.1f}" fill="none" stroke-width="{sw:.1f}"/>'
    out.append(f'<g id="icon_{name}" class="icon" data-icon="{name}" stroke="#8f8f8a" filter="url(#glow)" style="cursor:pointer">'
               f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{PUCK_R}" fill="#000" fill-opacity="0" stroke="none"/>{shape}</g>')
# glass screws (no status LED: the built tiles have none)
for i in range(12):
    x, y = xy(335, 360 * (i + 0.5) / 12)
    out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="7" fill="#b7bcc2" stroke="#7a7f85"/>')
out.append('</svg>')
svg = "\n".join(out) + "\n"
here = os.path.dirname(os.path.abspath(__file__))
open(os.path.join(here, "tile_top.svg"), "w").write(svg)
with open(os.path.join(here, "tile_top_svg.h"), "w") as f:
    f.write("// generated by make_tile_svg.py from the same drawing as tile_top.svg - do not edit\n#pragma once\n")
    f.write('static const char TILE_TOP_SVG[] = R"SVG(' + svg + ')SVG";\n')
