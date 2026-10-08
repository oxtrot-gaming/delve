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
	print("top quads:  %d" % view._tops.multimesh.instance_count)
	print("skirt quads: %d" % view._sides.multimesh.instance_count)

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
	quit(0)
