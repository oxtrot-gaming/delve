extends SceneTree

## Water-skin sanity probe: builds the field for the default settle
## tile, runs WaterView.install, and reports top/skirt instance counts
## plus the bed-to-surface gap distribution.
##
##     godot --headless --path . --script res://scripts/tests/water_probe.gd

func _initialize() -> void:
	var globe := WorldGlobe.new(1337)
	await globe.generate()
	var tile := globe.nearest_land_tile(WorldGlobe.default_settle_dir())
	var meso := MesoMap.generate(globe, tile)
	var vg: Dictionary = meso.voxel_grid(Vector2i.ZERO, 32)
	var gen := WorldGenerator.new()
	gen.install_regional_grid(vg["grid"], vg["origin"], vg["step"], vg["size"])
	var field := await SiteField.generate(meso, gen, Vector2i.ZERO)
	gen.install_site_field(field)

	var view := WaterView.new()
	root.add_child(view)
	view.install(field, gen)
	var tris := 0
	for tile: Vector2i in view._tiles:
		var inst: MeshInstance3D = view._tiles[tile]
		var arrays := inst.mesh.surface_get_arrays(0)
		tris += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	print("water tiles: %d, tris: %d" % [view._tiles.size(), tris])

	# Gap histogram: surface minus bed top per submerged column.
	var gaps := {}
	var flagged := 0
	for i in field.flags.size():
		if field.flags[i] & SiteField.FLAG_WATER == 0:
			continue
		flagged += 1
		var cx := i % field.side
		var cz := i / field.side
		var base_x: int = field.origin.x + cx * field.cell_m
		var base_z: int = field.origin.y + cz * field.cell_m
		for dz in field.cell_m:
			for dx in field.cell_m:
				var vx := base_x + dx
				var vz := base_z + dz
				var depth := gen.water_depth_at(vx, vz)
				if depth > 0:
					gaps[depth] = int(gaps.get(depth, 0)) + 1
	var keys := gaps.keys()
	keys.sort()
	var line := "depth → columns: "
	for k in keys.slice(0, 12):
		line += "%dm:%d " % [k, gaps[k]]
	print(line)
	print("flagged cells: %d" % flagged)

	# Boundary invariant: a dry neighbour's sampled ground must sit at
	# or above the water's level — anything lower would render as land
	# under the waterline (the standing-column artifact).
	var h := PackedInt32Array()
	h.resize(field.flags.size())
	for cz in field.side:
		for cx in field.side:
			var vx := field.origin.x + cx * field.cell_m + field.cell_m / 2
			var vz := field.origin.y + cz * field.cell_m + field.cell_m / 2
			h[cz * field.side + cx] = gen.raw_height(vx, vz)
	var violations := 0
	for cz in field.side:
		for cx in field.side:
			var i := cz * field.side + cx
			if field.flags[i] & SiteField.FLAG_WATER == 0:
				continue
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var jx := cx + dx
					var jz := cz + dz
					if jx < 0 or jx >= field.side or jz < 0 or jz >= field.side:
						continue
					var j := jz * field.side + jx
					if (
						field.flags[j] & SiteField.FLAG_WATER == 0
						and h[j] < field.water[i]
					):
						violations += 1
	print("dry-below-water boundary violations: %d" % violations)
	quit(0)
