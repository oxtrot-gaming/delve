extends SceneTree

## Finds where the lake's deep pit connects to the underground void —
## flood-fills from the pit water column through cells the generator
## reports open (caves included), then reports the breach level and an
## ASCII solidity slice so the layer view can be aimed at the mouth.
##
##     godot --headless --path . --script res://scripts/tests/pit_throat.gd

const DIRS6 := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

var _sim: RefCounted
var _bounds: Rect2i

func _initialize() -> void:
	_run()

func _open(p: Vector3i) -> bool:
	return int(_sim.probe_block(p)) == 0

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
	_sim = main.world.sim
	_bounds = main.site.bounds
	for i in 60:
		_sim.tick(0.2)

	# Deepest wet column = the pit mouth the water dips over.
	var best := Vector3i.ZERO
	var best_bed := 1 << 30
	for z in range(_bounds.position.y, _bounds.end.y):
		for x in range(_bounds.position.x, _bounds.end.x):
			if _sim.water_depth_at(x, z) <= 0:
				continue
			for y in range(64, -16, -1):
				if _open(Vector3i(x, y, z)):
					continue
				if y < best_bed:
					best_bed = y
					best = Vector3i(x, y, z)
				break
	print("pit bed at %s (top open y=%d)" % [best, best_bed + 1])

	# Flood from just above the pit bed through open cells, bounded —
	# the void reaches past the site and the generator answers every
	# cell, so an unbounded fill never finishes.
	var box := AABB(Vector3(-64, -48, -96), Vector3(192, 112, 160))
	var seen := {}
	var stack: Array[Vector3i] = [best + Vector3i(0, 1, 0)]
	while not stack.is_empty():
		var c: Vector3i = stack.pop_back()
		if seen.has(c) or not box.has_point(Vector3(c)) or not _open(c):
			continue
		seen[c] = true
		for d in DIRS6:
			stack.append(c + d)
	print("connected void cells (in box): %d" % seen.size())

	# Breach: the shallowest seen cell that sits OUTSIDE the pit's
	# footprint — that's the height the water column widens into void.
	var min_x: int = best.x - 6
	var max_x: int = best.x + 6
	var min_z: int = best.z - 6
	var max_z: int = best.z + 6
	var breach_y := -(1 << 30)
	var breach := Vector3i.ZERO
	for c: Vector3i in seen:
		if c.x < min_x or c.x > max_x or c.z < min_z or c.z > max_z:
			if c.y > breach_y:
				breach_y = c.y
				breach = c
	print("breach out of the bowl: %s at y=%d" % [breach, breach_y])
	# And the shallowest void cells anywhere — the cave ceiling level
	# the slice view should aim at.
	var top_void := -(1 << 30)
	for c: Vector3i in seen:
		top_void = maxi(top_void, c.y)
	print("shallowest connected void cell: y=%d" % top_void)

	# ASCII solidity slice at the breach level around the pit.
	for y in [breach_y, breach_y - 2]:
		print("--- solidity at y=%d (x -20..80, z -60..-4), #=solid" % y)
		for z in range(-60, -3):
			var row := ""
			for x in range(-20, 81):
				var p := Vector3i(x, y, z)
				row += "#" if not _open(p) else ("O" if seen.has(p) else ".")
			print(row)
	quit(0)
