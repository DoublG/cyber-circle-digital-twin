shader_type canvas_item;
// Background plate of the shared screens: dark brown-black with a faint amber
// grid and the orange / teal stripes of the room walls at the top and bottom.

uniform vec3 base_color : source_color = vec3(0.035, 0.03, 0.028);
uniform vec3 grid_color : source_color = vec3(1.0, 0.55, 0.15);
uniform vec3 orange : source_color = vec3(1.0, 0.45, 0.08);
uniform vec3 teal : source_color = vec3(0.2, 0.8, 0.75);
uniform vec2 screen_size = vec2(1920.0, 1080.0);

void fragment() {
	vec2 px = UV * screen_size;
	vec3 col = base_color;
	vec2 g = abs(fract(px / 60.0 + 0.5) - 0.5) * 60.0;
	float grid = 1.0 - smoothstep(0.0, 1.2, min(g.x, g.y));
	col += grid_color * grid * 0.05;
	// wall stripes: teal then orange, mirrored at the bottom
	float y = min(px.y, screen_size.y - px.y);
	if (y < 8.0) col = teal * 0.8;
	else if (y > 14.0 && y < 22.0) col = orange * 0.9;
	// soft glow in the middle like a lit console
	col += vec3(0.05, 0.03, 0.01) * (1.0 - length(UV - 0.5) * 1.6);
	COLOR = vec4(col, 1.0);
}
