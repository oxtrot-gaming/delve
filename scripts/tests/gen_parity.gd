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
	var native: VoxelGeneratorScript = ClassDB.instantiate(&"DelveGenerator")

	for seed in [1337, 7]:
		oracle.world_seed = seed
		native.set("world_seed", seed)
		print("seed ", seed)
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
