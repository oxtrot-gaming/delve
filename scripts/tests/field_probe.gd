extends SceneTree

## Prints an ASCII rendering of the site field's water/soil flags over
## the whole 1.5 km window — a tuning aid for the hydrology constants
## (SiteField.*). ~ river, W open water, w wetland, . shore, @ anchor.
##
##     godot --headless --path . --script res://scripts/tests/field_probe.gd

func _initialize() -> void:
	var globe := WorldGlobe.new(1337)
	await globe.generate()
	var tile := globe.nearest_land_tile(WorldGlobe.default_settle_dir())
	var meso := MesoMap.generate(globe, tile)
	var vg: Dictionary = meso.voxel_grid(Vector2i.ZERO, 32)
	var gen := WorldGenerator.new()
	gen.install_regional_grid(vg["grid"], vg["origin"], vg["step"], vg["size"])
	var field := await SiteField.generate(meso, gen, Vector2i.ZERO)
	var water := 0
	var wet := 0
	var rivers := 0
	for i in field.flags.size():
		if field.flags[i] & SiteField.FLAG_RIVER:
			rivers += 1
		elif field.flags[i] & SiteField.FLAG_WATER:
			water += 1
		elif field.flags[i] & SiteField.FLAG_WET:
			wet += 1
	print(
		"field: %d open water, %d river, %d wetland, %d basins" % [
			water, rivers, wet, field.basins.size()
		]
	)
	for vz in range(0, SiteField.FIELD_SIDE, 4):
		var line := ""
		for vx in range(0, SiteField.FIELD_SIDE, 4):
			var i := vz * SiteField.FIELD_SIDE + vx
			if vx == SiteField.FIELD_SIDE / 2 and vz == SiteField.FIELD_SIDE / 2:
				line += "@"
			elif field.flags[i] & SiteField.FLAG_RIVER:
				line += "~"
			elif field.flags[i] & SiteField.FLAG_WATER:
				line += "W"
			elif field.flags[i] & SiteField.FLAG_WET:
				line += "w"
			elif field.flags[i] & SiteField.FLAG_SHORE:
				line += "."
			else:
				line += " "
		print(line)
	quit(0)
