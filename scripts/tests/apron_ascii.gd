extends SceneTree

## Coarse map of the settled site field's waterline — '#' flagged
## water cells, '+' apron cells flooded only at voxel granularity,
## 'w' wetland flag, '.' dry. Downsampled 4×: one char per 16 m².
## 'A' marks the field centre (the landing anchor).

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
	var step := 4
	for cz in range(0, field.side, step):
		var line := ""
		for cx in range(0, field.side, step):
			var i := cz * field.side + cx
			if field.water[i] != SiteField.DRY:
				line += "#"
			elif field.flood_cells[i] != 0:
				line += "+"
			elif field.flags[i] & SiteField.FLAG_WET:
				line += "w"
			else:
				line += "."
		print(line)
	quit(0)
