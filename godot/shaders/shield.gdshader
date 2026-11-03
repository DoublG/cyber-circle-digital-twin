shader_type spatial;
// Energy shield dome over a tile: hexagon grid, bright rim, shimmer bands
// moving up, and a ripple from the robot side (local -Z) when it blocks a hit.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec3 color : source_color = vec3(0.3, 0.75, 1.0);
uniform float strength = 0.0;     // 0 = off, 1 = fully on
uniform float flash = 0.0;        // 1 right after a block, fades to 0
uniform float ripple = -1.0;      // 0..1 ripple travelling over the dome, < 0 = none
uniform vec3 impact = vec3(0.0, 0.9, -0.45);   // where the shot hits (mesh space): the robot side
uniform float heat = 0.0;         // 1 at a block, cools to 0: the hit spot glows, spreads out red and cools

varying vec3 local;

void vertex() {
	local = VERTEX;
}

// distance to the nearest hexagon edge (0 on the edge)
float hex_edge(vec2 p) {
	vec2 r = vec2(1.0, 1.732);
	vec2 h = r * 0.5;
	vec2 a = mod(p, r) - h;
	vec2 b = mod(p - h, r) - h;
	vec2 g = dot(a, a) < dot(b, b) ? a : b;
	g = abs(g);
	return 0.5 - max(dot(g, normalize(vec2(1.0, 1.732))), g.x);
}

void fragment() {
	float ang = atan(local.x, local.z);
	vec2 hp = vec2(ang * 3.0, local.y * 6.0);
	float edge = 1.0 - smoothstep(0.0, 0.06, hex_edge(hp));
	float fres = pow(1.0 - abs(dot(NORMAL, VIEW)), 2.5);
	float band = smoothstep(0.92, 1.0, sin(local.y * 6.0 - TIME * 2.5));
	float base = smoothstep(0.0, 0.08, local.y) * (1.0 - smoothstep(0.0, 0.25, local.y)) ; // glow at the foot
	float a = (edge * 0.22 + fres * 0.45 + band * 0.15 + base * 0.6 + 0.03) * strength;
	a += flash * (0.1 + edge * 0.45);
	float d = distance(local, impact);
	a += exp(-d * d * 14.0) * flash * 2.0;                     // the hot spot where the shot hit
	if (ripple >= 0.0) {
		float front = d - ripple * 2.2;
		a += exp(-front * front * 40.0) * (1.0 - ripple) * 1.5;
	}
	vec3 col = color * (1.0 + flash * 0.6);                    // brighter on a block (the hot spot: below)
	// heat: the spot where it hit glows white-yellow, spreads outwards turning red and cools down
	float t = 1.0 - heat;
	float spread = 0.12 + t * 0.85;                            // the heated area grows ...
	float hz = exp(-(d * d) / (spread * spread) * 2.0) * heat; // ... while it cools
	float rim = d - t * 1.1;                                   // a red ring running out ahead of it
	float ring = exp(-rim * rim * 60.0) * heat * 0.8;
	vec3 hot = mix(vec3(1.0, 0.02, 0.0), vec3(1.0, 0.5, 0.05), smoothstep(0.35, 0.7, hz));
	hot = mix(hot, vec3(1.0, 0.95, 0.8), smoothstep(0.75, 0.95, hz));
	float h = clamp(hz * 1.6 + ring, 0.0, 1.0);
	col = mix(col, hot * 1.6, h);
	a += hz * 1.2 + ring;
	ALBEDO = col;
	ALPHA = clamp(a, 0.0, 1.0);
}
