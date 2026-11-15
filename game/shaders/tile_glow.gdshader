shader_type spatial;
// The frosted plates of a tile, lit from below by its two LED rings (TileRing):
// every point takes the colour of the ring LEDs at its angle, blurred over the
// neighbours as the frosted glass does, brightest next to the rings. Dark LEDs:
// the plain white plate. The mesh is Ring_Glow in tile.glb (an annulus, LED 0
// at Blender +Y = Godot -Z, counting clockwise seen from above).

uniform vec3 leds[48];
uniform vec3 plate : source_color = vec3(0.86, 0.86, 0.84);
uniform float energy = 1.4;
uniform float r_inner = 0.168;     // where the rings are (TileRing measures them: tile or drone)
uniform float r_outer = 0.304;

varying vec2 pos;

void vertex() {
	pos = vec2(VERTEX.x, -VERTEX.z);     // back to Blender's top view (x right, y to the robot)
}

vec3 led(int i) {
	return leds[(i % 48 + 48) % 48];
}

void fragment() {
	float f = mod((PI * 0.5 - atan(pos.y, pos.x)) * 48.0 / TAU, 48.0);
	int i0 = int(floor(f));
	float t = fract(f);
	vec3 c = mix(led(i0), led(i0 + 1), t) * 0.6
		+ (led(i0 - 1) * (1.0 - t) + led(i0 + 2) * t) * 0.4;
	float r = length(pos);
	float near = max(exp(-abs(r - r_inner) * 40.0), exp(-abs(r - r_outer) * 40.0));
	float lit = clamp(max(c.r, max(c.g, c.b)), 0.0, 1.0);
	ALBEDO = mix(plate, c, lit * 0.8);
	EMISSION = c * energy * (0.5 + 0.5 * near);
	ROUGHNESS = 0.75;
}
