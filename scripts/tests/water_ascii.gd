extends SceneTree

## ASCII map of the water footprint around the parity fixture's
## diagonal river — verifies the blended datum produces contoured
## shorelines, not 4 m raster edges.

func _initialize() -> void:
	var gen := WorldGenerator.new()
	gen.world_seed = 1337
	gen._native = null

	# Same synthetic field as gen_parity: diagonal carved channel with
	# stepping levels (fx==fz), flanking flat water cells (|fx-fz|==1).
	var f := SiteField.new()
	f.origin = Vector2i(-96, -96)
	f.side = 48
	f.cell_m = 4
	var nf := f.side * f.side
	f.carve.resize(nf)
	f.water.resize(nf)
	f.flags.resize(nf)
	f.soil.resize(nf)
	f.depth_q.resize(nf)
	f.spill.resize(nf)
	f.water.fill(SiteField.DRY)
	f.spill.fill(26) ## dry cells can hold water only up to their spill
	f.specs = [
		{
			&"topsoil": {&"poor": 2, &"soil": 3, &"rich": 1, &"clay": 1, &"sand": 1},
			&"subsoil": {&"clay": 2, &"sand": 1, &"none": 3},
			&"depth_m": 3.0,
		},
		{
			&"topsoil": {&"peat": 3, &"poor": 1},
			&"subsoil": {&"frozen": 2, &"none": 1},
			&"depth_m": 1.5,
		},
	]
	for i in nf:
		var fx: int = i % f.side
		var fz: int = i / f.side
		f.depth_q[i] = 5 + (i * 7) % 40
		f.soil[i] = i % 2
		if fx == fz:
			f.carve[i] = SiteField.RIVER_CUT
			f.water[i] = 24 + fz / 8
			f.flags[i] = SiteField.FLAG_WATER | SiteField.FLAG_RIVER
		elif absi(fx - fz) == 1:
			f.water[i] = 30
			f.flags[i] = SiteField.FLAG_WATER
		elif absi(fx - fz) == 2:
			f.flags[i] = SiteField.FLAG_WET
	gen.install_site_field(f)

	# The diagonal runs through the field centre — render a 64x64
	# window over it. '#' depth>=3, '+' shallow, '.' dry.
	for vz in range(-20, 40):
		var line := ""
		for vx in range(-32, 32):
			var d := gen.water_depth_at(vx, vz)
			if d >= 3:
				line += "#"
			elif d > 0:
				line += "+"
			else:
				line += "."
		print("%4d %s" % [vz, line])
	quit(0)
