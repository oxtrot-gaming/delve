extends SceneTree

## Vegetation-vs-waterline sweep over the settled site field: every
## flooded voxel column must report grass_column() with seed < 0 and
## _grows_at() false, and every seeded sapling/bush slot the block
## streamers would plant must sit on dry ground. Exits 1 on any
## underwater placement.

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
	var field: SiteField = main.site_field
	var gen: WorldGenerator = main.world.generator_script
	var m := field.cell_m
	var vs := field.side * m
	var bad := 0
	var wet := 0
	for cz in field.side:
		for cx in field.side:
			if field.flood_cells[cz * field.side + cx] == 0:
				continue
			var base := cz * m * vs + cx * m
			for dz in m:
				var row := base + dz * vs
				for dx in m:
					if field.flood[row + dx] == SiteField.DRY:
						continue
					wet += 1
					var wx: int = field.origin.x + cx * m + dx
					var wz: int = field.origin.y + cz * m + dz
					if gen.grass_column(wx, wz).y >= 0.0:
						bad += 1
						if bad <= 5:
							print("grass seeded on wet column ", wx, ",", wz)
					if gen._grows_at(wx, wz):
						bad += 1
						if bad <= 5:
							print("_grows_at true on wet column ", wx, ",", wz)
	var saplings := 0
	var bushes := 0
	for bz in range(0, vs, 16):
		for bx in range(0, vs, 16):
			var block := Vector3i(field.origin.x + bx, 0, field.origin.y + bz)
			for pos: Vector2i in gen.saplings_in(block, 16):
				saplings += 1
				if gen.water_depth_at(pos.x, pos.y) > 0:
					bad += 1
					print("sapling seeded under water at ", pos)
			for pos: Vector2i in gen.bushes_in(block, 16):
				bushes += 1
				if gen.water_depth_at(pos.x, pos.y) > 0:
					bad += 1
					print("bush seeded under water at ", pos)
	print(
		"wet columns: ", wet, "  saplings: ", saplings,
		"  bushes: ", bushes, "  violations: ", bad
	)
	if bad == 0:
		print("WATER/VEG SWEEP PASSED")
	quit(0 if bad == 0 else 1)
