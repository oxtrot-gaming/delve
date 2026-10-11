extends SceneTree

## Water-skin sanity probe against the real playtest boot: reports
## tile/triangle counts, a depth histogram, and the boundary invariant
## (a dry neighbour's sampled ground must sit at or above the waterline
## — anything lower renders land under water).
##
##     godot --headless --path . --script res://scripts/tests/water_probe.gd

func _initialize() -> void:
	_run()

func _run() -> void:
	Main.pending_world = {
		&"seed": 158916680, &"ocean_pct": 60, &"temp_bias_c": 0.0,
		&"moist_bias": 0.0, &"axial_tilt_deg": 23.0, &"world_tile": 99285,
		&"package": &"vanilla", &"scenario": &"lost_tribe",
	}
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	while not main._units_spawned:
		await process_frame
	var sim: RefCounted = main.world.sim
	for i in 150:
		sim.tick(0.2)
	print("=== settled ===")

	var view: WaterView = main.water_view
	var tris := 0
	var skirt_tiles := 0
	for tile: Vector2i in view._tiles:
		var inst: MeshInstance3D = view._tiles[tile]
		if inst.mesh.get_surface_count() == 0:
			continue
		var arrays := inst.mesh.surface_get_arrays(0)
		tris += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	print("water tiles: %d, tris: %d" % [view._tiles.size(), tris])

	# Depth histogram over wet columns inside the site bounds.
	var b: Rect2i = main.site.bounds
	var gaps := {}
	var wet := 0
	for z in b.position.y + 1:
		for x in b.position.x + 1:
			pass
	for z in range(b.position.y, b.end.y):
		for x in range(b.position.x, b.end.x):
			var d: int = sim.water_depth_at(x, z)
			if d > 0:
				wet += 1
				gaps[d] = int(gaps.get(d, 0)) + 1
	var keys := gaps.keys()
	keys.sort()
	var line := "depth → columns: "
	for k in keys.slice(0, 12):
		line += "%dm:%d " % [k, gaps[k]]
	print(line)
	print("wet columns: %d" % wet)

	# Boundary invariant: a dry neighbour's sampled surface must sit at
	# or above the water's level — anything lower renders land under
	# the waterline (the standing-column artifact).
	var violations := 0
	for z in range(b.position.y, b.end.y):
		for x in range(b.position.x, b.end.x):
			var s: float = sim.water_surface_at(x, z)
			if s < -9000:
				continue
			for d in [Vector2i(1,0),Vector2i(-1,0),Vector2i(0,1),Vector2i(0,-1)]:
				var ns: float = sim.water_surface_at(x + d.x, z + d.y)
				if ns > -9000:
					continue
				var gtop := float(
					main.world.predicted_surface_height(x + d.x, z + d.y))
				if gtop < s - 0.51:
					violations += 1
	print("dry-below-water boundary violations: %d" % violations)
	quit(0)
