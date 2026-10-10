shader_type spatial;
// shadows_disabled: the cap is a cross-section floor plan — it should
// read flat and diagrammatic, and a giant plane receiving sun shadows
// at grazing angles otherwise grows shadow-acne speckle.
render_mode specular_disabled, shadows_disabled;

// The layer-view cut — a world-space height every fragment above is
// discarded for. Registered in project.godot [shader_globals]; the
// SliceView node moves it, far past terrain top means "slicing off".
global uniform float delve_slice_y;
varying float _slice_wy;

void vertex() {
	_slice_wy = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
}

void fragment() {
	if (_slice_wy >= delve_slice_y) discard;
	ALBEDO = COLOR.rgb;
}
