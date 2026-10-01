extends SceneTree

## Diagnostic: replicate the smoke test's _floating_flat scan (editable-
## bounded, trees count as solid) and confirm the found cell is
## genuinely unsupported + designate-able.

var _elapsed := 0.0


func _init() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var world: VoxelWorld = main.get_node("VoxelWorld")
	var colony: Colony = main.get_node("Colony")

	await _wait(func() -> bool: return colony.units.size() > 0)
	colony.forest.set_process(false)
	colony.plants.set_process(false)
	var unit: Unit = colony.units[0]
	var mined := Vector3i(unit.global_position.floor())

	var tries := 0
	var ledge := Vector3i.MAX
	for off in range(-300, 300):
		var v := _flat_voxel(world, mined, off)
		if v == Vector3i.MAX:
			continue
		tries += 1
		var g: int = v.y - 1
		var flat := true
		for ox in range(-2, 3):
			for oz in range(-2, 3):
				if _solid_top(world, v.x + ox, v.z + oz, mined.y + 32) != g:
					flat = false
		if not flat:
			continue
		var target := v + Vector3i.UP
		var upper := target + Vector3i.UP
		if (
			world.is_editable(target)
			and world.is_editable(upper)
			and world.get_block(target) == BlockRegistry.Block.AIR
			and world.get_block(upper) == BlockRegistry.Block.AIR
			and colony.item_pile_at(v) == null
			and not colony.is_designated(target)
			and not colony.is_designated(upper)
			and colony.forest.tree_root_at(target) == Vector3i.MAX
			and colony.forest.tree_root_at(upper) == Vector3i.MAX
		):
			ledge = v
			break
	print("tries=%d ledge=%s" % [tries, ledge])
	if ledge != Vector3i.MAX:
		var target := ledge + Vector3i.UP
		print(
			"target=%s supported=%s designate=%s" % [
				target,
				colony.would_be_supported(target),
				colony.designate_build(target, &"dirt_wall") != null,
			]
		)
	quit()


func _ground(world: VoxelWorld, x: int, z: int, from_y: int, min_y: int = -32) -> int:
	for y in range(from_y, min_y, -1):
		var cell := Vector3i(x, y, z)
		if not world.is_editable(cell):
			continue
		var block := world.get_block(cell)
		if BlockRegistry.is_tree_block(block):
			continue
		if BlockRegistry.is_solid(block):
			return y
	return min_y


func _solid_top(world: VoxelWorld, x: int, z: int, from_y: int) -> int:
	for y in range(from_y, -32, -1):
		var cell := Vector3i(x, y, z)
		if not world.is_editable(cell):
			continue
		if BlockRegistry.is_solid(world.get_block(cell)):
			return y
	return -32


func _flat_voxel(world: VoxelWorld, mined: Vector3i, z_off: int) -> Vector3i:
	var z: int = mined.z + z_off
	for x in range(mined.x + 4, mined.x + 28):
		var g := _ground(world, x, z, mined.y + 32)
		var spot := Vector3i(x + 1, g + 1, z)
		if (
			_ground(world, x + 1, z, mined.y + 32) == g
			and _ground(world, x + 2, z, mined.y + 32) == g
			and _ground(world, x + 3, z, mined.y + 32) == g
			and world.is_editable(Vector3i(x + 1, g, z))
			and world.is_editable(spot)
			and world.get_block(spot) == BlockRegistry.Block.AIR
			and world.is_solid(Vector3i(x + 1, g, z))
		):
			return spot
	return Vector3i.MAX


func _wait(predicate: Callable, step: float = 0.1) -> bool:
	var t := 0.0
	while not predicate.call() and t < 60.0:
		await process_frame
		t += step
		_elapsed += step
	return predicate.call()
