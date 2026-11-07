"""The tile's top as SVG (tile_top.svg) - the same measurements as the 3D model
(assets/blender/build_models.py: build_tile), 1 px = 1 mm, seen from above with the
robot at the top. Every part the firmware lights has an id the emulator's web
view colours live:  led_0 .. led_47 (LED_00 = towards the robot, then
clockwise), heart_0 .. heart_4 (heart 1 nearest the logo), icon_Square,
icon_Triangle, icon_Cross, icon_Circle (the etched symbols, lit from below;
click = press), status.
    python3 make_tile_svg.py      (writes tile_top.svg and tile_top_svg.h, the emulator's copy)
"""
import os
import math

TILE_R, GLASS_R, LED_RING_R, BUTTON_R = 350, 322, 304, 215
BUTTONS = {"Triangle": 45, "Square": 135, "Cross": 225, "Circle": 315}   # deg CCW from +X; +Y = the robot
LEDS, HEARTS = 48, 5


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
       f'<circle r="{TILE_R - 4}" fill="#dcdcd6"/>',
       f'<circle r="{LED_RING_R}" fill="none" stroke="#111" stroke-width="18"/>']
# the 4 floor plates' seams (left, right, bottom)
out.append('<g stroke="#222" stroke-width="4"><line x1="-310" y1="0" x2="-160" y2="0"/><line x1="160" y1="0" x2="310" y2="0"/>'
           '<line x1="0" y1="160" x2="0" y2="310"/></g>')
# the logo: yin-yang
out.append('<g transform="scale(1)"><circle r="160" fill="#f2f2ee" stroke="#111" stroke-width="3"/>'
           '<path d="M0,-160 A160,160 0 0 0 0,160 A80,80 0 0 0 0,0 A80,80 0 0 1 0,-160 Z" fill="#111"/>'
           '<circle cy="-80" r="22" fill="#f2f2ee"/><circle cy="80" r="22" fill="#111"/></g>')
# the hearts, from the logo towards the robot
out.append('<rect x="-1.5" y="-245" width="3" height="130" fill="#111"/>')
for i in range(HEARTS):
    y = -(180 + i * 24)
    out.append(f'<path d="{heart(0, y, 26)}" fill="#111"/>')
    out.append(f'<path id="heart_{i}" d="{heart(0, y, 19)}" fill="#260006"/>')
# the LED ring: LED_00 at the robot, clockwise seen from above
for i in range(LEDS):
    deg = 90 - 360 * i / LEDS
    x, y = xy(LED_RING_R, deg)
    rot = -deg + 90
    out.append(f'<rect id="led_{i}" x="{x - 6:.1f}" y="{y - 3.5:.1f}" width="12" height="7" rx="1.5" '
               f'transform="rotate({rot:.1f} {x:.1f} {y:.1f})" fill="#262626"/>')
# the glass plate on spacers
for k in range(8):
    x, y = xy(270, 22.5 + 45 * k)
    out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="6" fill="#cfe3e6" opacity=".6"/>')
out.append(f'<circle r="{GLASS_R}" fill="url(#glass)" stroke="#e8f6f8" stroke-opacity=".5" stroke-width="2"/>')
# the etched icons (lit from below), with a big invisible target to click
for name, deg in BUTTONS.items():
    cx, cy = xy(BUTTON_R, deg)
    sw = 9
    if name == "Square":
        shape = f'<rect x="{cx - 31:.1f}" y="{cy - 31:.1f}" width="62" height="62" fill="none" stroke-width="{sw}"/>'
    elif name == "Triangle":
        p = [xy(42, 90 + 120 * j) for j in range(3)]
        pts = " ".join(f"{cx + px:.1f},{cy + py:.1f}" for px, py in p)
        shape = f'<polygon points="{pts}" fill="none" stroke-width="{sw}" stroke-linejoin="round"/>'
    elif name == "Cross":
        shape = (f'<path d="M{cx - 29:.1f},{cy - 29:.1f} L{cx + 29:.1f},{cy + 29:.1f} M{cx + 29:.1f},{cy - 29:.1f} '
                 f'L{cx - 29:.1f},{cy + 29:.1f}" fill="none" stroke-width="{sw}" stroke-linecap="round"/>')
    else:
        shape = f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="33" fill="none" stroke-width="{sw}"/>'
    out.append(f'<g id="icon_{name}" class="icon" data-icon="{name}" stroke="#8f8f8a" filter="url(#glow)" style="cursor:pointer">'
               f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="58" fill="#000" fill-opacity="0" stroke="none"/>{shape}</g>')
# glass screws and the status LED on the cable side (towards the robot)
for i in range(12):
    x, y = xy(335, 360 * (i + 0.5) / 12)
    out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="7" fill="#b7bcc2" stroke="#7a7f85"/>')
sx, sy = xy(338, 90)
out.append(f'<circle id="status" cx="50" cy="{sy:.1f}" r="5" fill="#262626" filter="url(#glow)"/>')
out.append('</svg>')
svg = "\n".join(out) + "\n"
here = os.path.dirname(os.path.abspath(__file__))
open(os.path.join(here, "tile_top.svg"), "w").write(svg)
with open(os.path.join(here, "tile_top_svg.h"), "w") as f:
    f.write("// generated by make_tile_svg.py from the same drawing as tile_top.svg - do not edit\n#pragma once\n")
    f.write('static const char TILE_TOP_SVG[] = R"SVG(' + svg + ')SVG";\n')
