shader_type canvas_item;
// CRT look over a whole screen: scanlines, a slow rolling bright band,
// vignette and a slight flicker. Only darkens / tints, never hides content.

uniform float line_count = 360.0;
uniform float scanline_strength = 0.22;
uniform float vignette_strength = 0.6;

void fragment() {
	vec2 uv = UV;
	float scan = 0.5 + 0.5 * sin(uv.y * line_count * TAU);
	float roll = smoothstep(0.0, 0.08, abs(fract(uv.y - TIME * 0.07) - 0.5));
	float d = length((uv - 0.5) * vec2(1.0, 0.8));
	float vignette = smoothstep(0.35, 0.85, d) * vignette_strength;
	float flicker = 0.015 * sin(TIME * 53.0);
	float a = scanline_strength * scan * (0.6 + 0.4 * roll) + vignette + flicker;
	COLOR = vec4(0.0, 0.0, 0.0, clamp(a, 0.0, 0.9));
}
