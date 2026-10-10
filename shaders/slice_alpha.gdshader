shader_type spatial;
render_mode cull_disabled;

// The layer-view cut — a world-space height every fragment above is
// discarded for. Registered in project.godot [shader_globals]; the
// SliceView node moves it, far past terrain top means "slicing off".
global uniform float delve_slice_y;
uniform vec4 albedo : source_color = vec4(0.16, 0.34, 0.52, 0.6);
varying float _slice_wy;

void vertex() {
	_slice_wy = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
}

void fragment() {
	if (_slice_wy >= delve_slice_y) discard;
	ALBEDO = albedo.rgb;
	ALPHA = albedo.a;
}
