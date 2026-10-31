shader_type spatial;
// LEDs drawn as one MultiMesh: the instance colour is the LED colour,
// alpha 1 = on (glows), alpha 0 = off (the dull off colour). Unshaded.
render_mode unshaded;

uniform vec3 off_color : source_color = vec3(0.15);
uniform float energy = 2.5;      // > 1: picked up by the glow

void fragment() {
	ALBEDO = mix(off_color, COLOR.rgb * energy, COLOR.a);
}
