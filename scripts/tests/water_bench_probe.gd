extends SceneTree

## Water-step cost bench: boots the real site, then times sim.tick
## over the seeded lake to quantify per-step cost.

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
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	while not main._units_spawned:
		await process_frame
	var sim = main.world.sim
	if sim == null:
		printerr("no DelveSim")
		quit(2)
		return
	# Warm-up: settle the seeded lake's post-seed frontier.
	for i in 300:
		var t0 := Time.get_ticks_msec()
		sim.tick(0.2)
		var st: Dictionary = sim.debug_stats()
		if i % 10 == 0 or i == 299:
			print(
				"step %d: %dms active=%d cells=%d cols=%d cm3=%.0f"
				% [
					i, Time.get_ticks_msec() - t0,
					st["water_active"], st["water_cells"],
					st["water_cols"], st["water_cm3"] / 1.0e6,
				]
			)
	quit(0)
