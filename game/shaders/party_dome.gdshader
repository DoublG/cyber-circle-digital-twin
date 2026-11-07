shader_type spatial;
// Dome of the robot with a party lamp inside: coloured light spots projected
// on the inside of the dome, rotating and slowly changing colour.
render_mode blend_mix, cull_back, specular_schlick_ggx;

uniform vec4 shell_color : source_color = vec4(0.92, 0.93, 0.97, 0.85);
uniform bool enabled = true;
uniform float spin_speed = 0.6;          // radians per second around the vertical axis
uniform float spot_density = 6.0;        // more = more, smaller spots
uniform float spot_size : hint_range(0.05, 0.6) = 0.3;
uniform float spot_fill : hint_range(0.0, 1.0) = 0.65;  // fraction of cells with a spot
uniform float brightness = 3.0;
uniform float color_cycle = 0.1;         // hue shift per second

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

vec3 hash3(vec3 p) {
	p = vec3(dot(p, vec3(127.1, 311.7, 74.7)),
			 dot(p, vec3(269.5, 183.3, 246.1)),
			 dot(p, vec3(113.5, 271.9, 124.6)));
	return fract(sin(p) * 43758.5453);
}

vec3 hsv2rgb(vec3 c) {
	vec3 p = abs(fract(c.xxx + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

void fragment() {
	vec3 col = vec3(0.0);
	float spot = 0.0;
	if (enabled) {
		float a = TIME * spin_speed;
		mat3 rot = mat3(vec3(cos(a), 0.0, -sin(a)), vec3(0.0, 1.0, 0.0), vec3(sin(a), 0.0, cos(a)));
		vec3 p = rot * normalize(local_pos) * spot_density;
		vec3 cell = floor(p);
		float best = 10.0;
		vec3 best_id = cell;
		for (int x = -1; x <= 1; x++) {
			for (int y = -1; y <= 1; y++) {
				for (int z = -1; z <= 1; z++) {
					vec3 c = cell + vec3(float(x), float(y), float(z));
					float d = length(c + 0.2 + 0.6 * hash3(c) - p);
					if (d < best) {
						best = d;
						best_id = c;
					}
				}
			}
		}
		vec3 h = hash3(best_id + 17.0);
		spot = (1.0 - smoothstep(spot_size * 0.6, spot_size, best)) * step(1.0 - spot_fill, h.y);
		col = hsv2rgb(vec3(fract(h.x + TIME * color_cycle), 0.85, 1.0));
	}
	ALBEDO = mix(shell_color.rgb, col, spot * 0.6);
	EMISSION = col * spot * brightness;
	ALPHA = mix(shell_color.a, 1.0, spot);
	ROUGHNESS = 0.3;
}
