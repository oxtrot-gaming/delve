extends SceneTree

## Diagnostic: watch a hungry unit's food-seek end to end.

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
	for u in colony.units:
		u._job_search_cooldown = 120.0

	# Flat spot near the unit.
	var base := Vector3i(unit.global_position.floor())
	var site := Vector3i.MAX
	for dx in range(4, 30):
		for dz in range(-10, 11):
			var y := _ground(world, base.x + dx, base.z + dz, base.y + 32)
			var v := Vector3i(base.x + dx, y + 1, base.z + dz)
			if (
				world.get_block(v) == BlockRegistry.Block.AIR
				and world.is_solid(v + Vector3i.DOWN)
				and colony.voxel_fill(v) <= 0
			):
				site = v
				break
		if site != Vector3i.MAX:
			break
	print("site=%s" % site)
	var food_v := site + Vector3i(2, 0, 0)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.BERRY, DropItem.Form.LOOSE, 300_000),
		food_v
	)
	await _wait(func() -> bool: return colony._in_flight.is_empty())
	print("food pile at %s: %s" % [food_v, colony.item_pile_at(food_v) != null])
	print(
		"nearest food: %s" % colony.nearest_food_pile(
			Vector3i(unit.global_position.floor())
		)
	)

	unit.global_position = Vector3(site) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	colony.needs_enabled = true
	unit.hunger = unit.food_seek * 0.5
	unit._job_search_cooldown = 0.0

	# Instrument the path internals on the same query _start_eat runs.
	var spots := unit._work_spots(food_v, false, false)
	print("spots for %s: %s" % [food_v, spots])
	var start := unit._standing_voxel()
	print("standing: %s" % start)
	for spot in spots:
		var path := world.find_path(start, spot)
		print("path to %s: %d pts clear=%s" % [spot, path.size(), unit._path_is_clear(path)])

	# Drive _start_eat by hand and inspect.
	unit._start_eat()
	print(
		"after _start_eat: state=%d job=%s goal=%s" % [
			unit.state,
			unit.job.voxel_position if unit.job != null else "null",
			unit._goal_voxel,
		]
	)

	for i in 30:
		await _frames(10)
		print(
			"t=%.1f state=%d job=%s hunger=%.2f goal=%s act='%s'" % [
				_elapsed, unit.state,
				unit.job.voxel_position if unit.job != null else "null",
				unit.hunger,
				unit._goal_voxel,
				unit.current_activity(),
			]
		)
		if unit.hunger > 0.9:
			break
	quit()


func _ground(world: VoxelWorld, x: int, z: int, from_y: int) -> int:
	for y in range(from_y, -32, -1):
		var v := Vector3i(x, y, z)
		if world.get_block(v) != BlockRegistry.Block.AIR:
			return y
	return -32


func _wait(predicate: Callable, step: float = 0.1) -> bool:
	var t := 0.0
	while not predicate.call() and t < 60.0:
		await process_frame
		t += step
		_elapsed += step
	return predicate.call()


func _frames(n: int) -> void:
	for i in n:
		await process_frame
		_elapsed += 1.0 / 60.0
