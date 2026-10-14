extends SceneTree

## Generator parity check: the native DelveGenerator (delve_native
## extension) must emit voxel-for-voxel identical terrain to the GDScript
## WorldGenerator oracle, for every seed and block origin.
##
##     godot --headless --path . --script res://scripts/tests/gen_parity.gd

var _failures: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	_run()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok: ", message)
	else:
		_failures.append(message)


func _run() -> void:
	if not ClassDB.class_exists(&"DelveGenerator"):
		printerr("DelveGenerator class not registered — is delve_native built?")
		quit(2)
		return

	var oracle := WorldGenerator.new()
	# Force the pure-GDScript path — with the extension loaded the oracle
	# would forward to the same native generator and compare it to itself.
	oracle._native = null
	var native: VoxelGeneratorScript = ClassDB.instantiate(&"DelveGenerator")

	for seed in [1337, 7]:
		oracle.world_seed = seed
		native.set("world_seed", seed)
		print("seed ", seed)
		_check_parity(oracle, native)

	# Regional grid installed — the mesoscale pinning must be
	# voxel-identical across both implementations too.
	var slope := PackedInt32Array()
	slope.resize(36)
	for i in 6:
		for j in 6:
			slope[i * 6 + j] = 28 + i * 3 - j * 5
	oracle.install_regional_grid(slope, Vector2i(-140, -90), 37, 6)
	native.set("regional_origin", Vector2i(-140, -90))
	native.set("regional_step", 37)
	native.set("regional_size", 6)
	native.set("regional_grid", slope)
	print("seed 1337 + regional grid")
	_check_parity(oracle, native)

	# Site field installed — the soil/water rasters must stay
	# voxel-identical too. A synthetic field exercises every code path:
	# a carved channel diagonal, water cells, mixed spec picks, and
	# per-cell depth (SiteField.generate itself only ever runs in
	# GDScript — what parity covers is the sampling).
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
	f.spill.fill(200) ## generous bound — parity doesn't exercise hydraulics
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
	oracle.install_site_field(f)
	# The oracle mirrors into its own _native — null here, so the test's
	# native instance takes the same rasters by hand.
	native.call(
		"install_field", f.carve, f.water, f.soil, f.depth_q, f.rock,
		oracle._pack_specs(f.specs), f.flood, f.origin, f.cell_m, f.side
	)
	print("seed 1337 + regional grid + site field")
	_check_parity(oracle, native)

	if _failures.is_empty():
		print("PARITY TEST PASSED")
		quit(0)
	else:
		for failure in _failures:
			printerr("FAILED: ", failure)
		quit(1)


func _check_parity(oracle: WorldGenerator, native: VoxelGeneratorScript) -> void:
	var a := VoxelBuffer.new()
	a.create(16, 16, 16)
	var b := VoxelBuffer.new()
	b.create(16, 16, 16)

	var surface := oracle.surface_height(0, 0)
	var band := floori(float(surface) / 16.0) * 16
	var ys := [band - 32, band - 16, band, band + 16, 512]
	var checked := 0
	var first_diff := ""
	for ox in [-80, -32, 0, 48, 96]:
		for oz in [-80, -16, 24, 96]:
			for oy in ys:
				var origin := Vector3i(ox, oy, oz)
				oracle._generate_block(a, origin, 0)
				# The native _generate_block is an engine-dispatched virtual,
				# not a script method — the test hook calls the same code.
				native.generate_block_test(b, origin, 0)
				for x in 16:
					for y in 16:
						for z in 16:
							var va := a.get_voxel(x, y, z, VoxelBuffer.CHANNEL_TYPE)
							var vb := b.get_voxel(x, y, z, VoxelBuffer.CHANNEL_TYPE)
							if va != vb and first_diff.is_empty():
								first_diff = "%s at %s rel(%d,%d,%d): oracle=%d native=%d" % [
									origin, Vector3i(ox + x, oy + y, oz + z), x, y, z, va, vb
								]
				checked += 1
	_check(first_diff.is_empty(), "identical blocks across %d sampled chunks%s" % [
		checked, "" if first_diff.is_empty() else " — first diff: " + first_diff
	])
