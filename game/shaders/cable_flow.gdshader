shader_type spatial;
// Light strip on a cable duct. UV.x runs from the tile (0) to the robot (1).
// Soft dashes flow towards the robot all the time; up to 4 bright "packets"
// (positions set from arena.gd) travel along the cable: towards the robot
// (direction +1, e.g. a player's attack) or towards the tile (-1, the robot's).
render_mode specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.05, 0.05, 0.06, 1.0);
uniform vec4 flow_color : source_color = vec4(0.15, 0.5, 1.0, 1.0);
uniform float idle_speed = 0.35;        // cable lengths per second
uniform float idle_dashes = 8.0;        // dashes along the cable
uniform float idle_strength : hint_range(0.0, 2.0) = 0.5;
uniform vec4 packets = vec4(-1.0);      // packet positions 0..1, < 0 = unused
uniform vec4 packet_dirs = vec4(1.0);   // +1 = moving to the robot, -1 = to the tile
uniform vec4 packet_color : source_color = vec4(1.0);
uniform float packet_length = 0.05;
uniform float energy = 4.0;

void fragment() {
	float x = UV.x;
	float dash = fract(x * idle_dashes - TIME * idle_speed * idle_dashes);
	float idle = smoothstep(0.0, 0.2, dash) * (1.0 - smoothstep(0.2, 0.6, dash)) * idle_strength;
	float pk = 0.0;
	for (int i = 0; i < 4; i++) {
		float p = packets[i];
		if (p >= 0.0) {
			float d = (x - p) / packet_length * packet_dirs[i];
			// bright head with a short tail behind it (where the packet came from)
			pk = max(pk, d > 0.0 ? exp(-d * d * 4.0) : exp(d * 1.5));
		}
	}
	vec3 light = flow_color.rgb * idle + packet_color.rgb * pk;
	ALBEDO = base_color.rgb + light * 0.2;
	EMISSION = light * energy;
	ROUGHNESS = 0.4;
}
