extends SceneTree

## Boot-timing probe: stages a worldgen embark like worldgen.gd does,
## instances the real main scene, and reports how long each loading
## stage takes until the site is interactable.
##
##     godot --headless --path . --script res://scripts/tests/boot_probe.gd

var _t0 := 0
var _last := ""


func _initialize() -> void:
	Main.pending_world = {
		&"seed": 1337,
		&"ocean_pct": 60,
		&"temp_bias_c": 0.0,
		&"moist_bias": 0.0,
		&"axial_tilt_deg": 23.0,
		&"world_tile": -1,
		&"package": &"vanilla",
		&"scenario": &"lost_tribe",
	}
	_t0 = Time.get_ticks_msec()
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_mark("scene instanced")
	while not main._units_spawned:
		await process_frame
		if main._stage_text != _last:
			_last = main._stage_text
			_mark(_last)
	_mark("READY — units spawned")
	quit()


func _mark(what: String) -> void:
	print("%8d ms  %s" % [Time.get_ticks_msec() - _t0, what])
