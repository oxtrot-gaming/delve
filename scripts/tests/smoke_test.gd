extends SceneTree

## Headless smoke test for the framework.
##
##     godot --headless --path . --script res://scripts/tests/smoke_test.gd
##
## Checks that the generator produces layered terrain, that the blocky library
## bakes, and that a designated mining job actually gets done by a colonist and
## lands in the stockpile.

const TIMEOUT_SECONDS := 120.0

var _failures: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	_run()


func _run() -> void:
	_test_block_registry()
	_test_generator()
	await _test_mining_loop()

	if _failures.is_empty():
		print("SMOKE TEST PASSED")
		quit(0)
	else:
		for failure in _failures:
			printerr("FAILED: ", failure)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok: ", message)
	else:
		_failures.append(message)


func _test_block_registry() -> void:
	print("block registry")
	var library := BlockRegistry.build_library()
	_check(library.models.size() == BlockRegistry.BLOCKS.size(), "library has a model per block type")
	_check(not BlockRegistry.is_solid(BlockRegistry.Block.AIR), "air is not solid")
	_check(BlockRegistry.is_solid(BlockRegistry.Block.STONE), "stone is solid")
	_check(
		BlockRegistry.drop_of(BlockRegistry.Block.IRON_ORE) == BlockRegistry.Resource_.IRON,
		"iron ore drops iron"
	)


func _test_generator() -> void:
	print("terrain generator")
	var generator := WorldGenerator.new()
	var surface_y := generator.surface_height(0, 0)

	var buffer := VoxelBuffer.new()
	buffer.create(16, 16, 16)
	var origin := Vector3i(0, surface_y - 8, 0)
	generator._generate_block(buffer, origin, 0)

	var found: Dictionary[int, int] = {}
	for x in 16:
		for y in 16:
			for z in 16:
				var block := buffer.get_voxel(x, y, z, VoxelBuffer.CHANNEL_TYPE)
				found[block] = found.get(block, 0) + 1

	_check(found.has(BlockRegistry.Block.AIR), "generates air above the surface")
	_check(found.has(BlockRegistry.Block.STONE), "generates stone underground")
	_check(
		found.has(BlockRegistry.Block.GRASS) or found.has(BlockRegistry.Block.DIRT),
		"generates a soil layer"
	)

	var sky := VoxelBuffer.new()
	sky.create(16, 16, 16)
	generator._generate_block(sky, Vector3i(0, 512, 0), 0)
	_check(sky.is_uniform(VoxelBuffer.CHANNEL_TYPE), "blocks far above the surface are empty")


func _test_mining_loop() -> void:
	print("colony mining loop")
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)

	var world: VoxelWorld = main.get_node("VoxelWorld")
	var colony: Colony = main.get_node("Colony")

	var spawned := await _wait_until(func() -> bool: return colony.colonists.size() > 0)
	_check(spawned, "colonists spawn once the terrain is loaded")
	if not spawned:
		return

	var colonist: Colonist = colony.colonists[0]
	var target := _pick_mining_target(world, colonist)
	_check(target != Vector3i.MAX, "found a designatable voxel near a colonist")
	if target == Vector3i.MAX:
		return

	var job := colony.designate_mine(target)
	_check(job != null, "designation creates a job")

	var mined := await _wait_until(func() -> bool: return not world.is_solid(target))
	_check(mined, "a colonist mines the designated voxel")
	_check(not colony.stockpile.is_empty(), "mined block lands in the stockpile")

	main.queue_free()


## Topmost solid voxel in a column a couple of voxels away from the colonist.
func _pick_mining_target(world: VoxelWorld, colonist: Colonist) -> Vector3i:
	var origin := Vector3i(colonist.global_position.floor())
	var offsets: Array[Vector3i] = [Vector3i(2, 0, 0), Vector3i(-2, 0, 0), Vector3i(0, 0, 2), Vector3i(0, 0, -2)]
	for offset in offsets:
		var column := origin + offset
		var ground_y := world.ground_height(column.x, column.z, origin.y + 16, origin.y - 16)
		var candidate := Vector3i(column.x, ground_y, column.z)
		if world.is_solid(candidate):
			return candidate
	return Vector3i.MAX


func _wait_until(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return false
