shader_type spatial;
render_mode specular_disabled;

// The layer-view cut — a world-space height every fragment above is
// discarded for. Registered in project.godot [shader_globals]; the
// SliceView node moves it, far past terrain top means "slicing off".
global uniform float delve_slice_y;
// Colony boundary on the xz plane: min.xy, max.xy. Fragments past the
// edge mix toward delve_fog so the out-of-bounds reads as veiled.
global uniform vec4 delve_bounds;
global uniform vec4 delve_fog;
uniform vec4 albedo : source_color = vec4(1.0);
varying float _slice_wy;
varying vec2 _site_xz;

void vertex() {
	vec4 _wp = MODEL_MATRIX * vec4(VERTEX, 1.0);
	_slice_wy = _wp.y;
	_site_xz = _wp.xz;
}

void fragment() {
	if (_slice_wy > delve_slice_y) discard;
	vec2 _ob = max(
		max(delve_bounds.xy - _site_xz, _site_xz - delve_bounds.zw),
		vec2(0.0));
	float _fog = 0.0;
	if (_ob.x + _ob.y > 0.0) {
		_fog = min(0.125 + length(_ob) / 96.0, delve_fog.a);
	}
	ALBEDO = mix(albedo.rgb, delve_fog.rgb, _fog);
}
