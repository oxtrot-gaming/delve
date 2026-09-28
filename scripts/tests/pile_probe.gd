extends SceneTree

## Diagnostic: a hungry/tired unit standing on a partial pile among
## partial piles — does it path out and eat/rest, or stall?

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
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()

	# A real flat patch: 7×7 columns all sharing one ground height, cells
	# free of solid blocks too.
	var base := Vector3i(unit.global_position.floor())
	var site := Vector3i.MAX
	for dx in range(-40, 41):
		for dz in range(-40, 41):
			var y := _ground(world, base.x + dx, base.z + dz, base.y + 32)
			if y < 0 or abs(dx) < 2:
				continue
			var flat := true
			for ox in range(7):
				for oz in range(7):
					var c := Vector3i(base.x + dx + ox, 0, base.z + dz + oz)
					if (
						_ground(world, c.x, c.z, base.y + 32) != y
						or world.get_block(Vector3i(c.x, y + 1, c.z)) != BlockRegistry.Block.AIR
					):
						flat = false
			if flat:
				site = Vector3i(base.x + dx, y + 1, base.z + dz)
				break
		if site != Vector3i.MAX:
			break
	print("site=%s" % site)
	if site == Vector3i.MAX:
		quit()
		return

	# A stockpile field: a 3×3 of partial piles (~65% each — above the
	# 0.55 step limit, below packed) inside the flat patch, the unit
	# parked on the centre pile, a food pile on the far side.
	for dx in range(3):
		for dz in range(3):
			var cell := site + Vector3i(dx + 1, 0, dz + 1)
			colony._deposit_item(
				DropItem.new(
					BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 650_000
				),
				cell
			)
	var food_v := site + Vector3i(2, 0, 4)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.BERRY, DropItem.Form.LOOSE, 300_000),
		food_v
	)
	await _wait(func() -> bool: return colony._in_flight.is_empty())

	# Park the unit on the centre pile.
	var pile_cell := site + Vector3i(2, 0, 2)
	unit.global_position = Vector3(pile_cell) + Vector3(0.5, 1.55, 0.5)
	unit.velocity = Vector3.ZERO
	# Let the sim settle the body onto the pile surface.
	await _frames(30)
	print(
		"unit pos=%s standing_voxel=%s fill=%d" % [
			unit.global_position, unit._standing_voxel(),
			colony.voxel_fill(pile_cell),
		]
	)
	print(
		"standing cell standable=%s  start-fill=%d" % [
			unit._is_standable(unit._standing_voxel()),
			colony.voxel_fill(unit._standing_voxel()),
		]
	)

	colony.needs_enabled = true
	unit.energy = 1.0
	unit.hunger = 0.1
	unit._job_search_cooldown = 0.0

	# Instrument what _start_eat sees.
	print("fill map around food pile %s:" % food_v)
	for dz in range(-3, 4):
		var row := "  z=%+d: " % dz
		for dx in range(-3, 4):
			var c: Vector3i = food_v + Vector3i(dx, 0, dz)
			row += "%d%s " % [
				colony.voxel_fill(c) / 1000,
				"S" if unit._is_standable(c) else "-",
			]
		print(row)
	var raw: Array[Vector3i] = []
	for spot in world.sim.work_spots(
		food_v, unit.global_position, false, false, unit.mine_reach
	):
		raw.append(Vector3i(spot))
	print("native spots (unfiltered): %s" % [raw])
	var spots := unit._work_spots(food_v, false, false)
	print("filtered spots: %s" % [spots])
	var start := unit._standing_voxel()
	for spot in spots:
		var path := world.find_path(start, spot)
		print(
			"  path to %s: %d pts clear=%s standable=%s" % [
				spot, path.size(), unit._path_is_clear(path),
				unit._is_standable(spot),
			]
		)
	unit._start_eat()
	print(
		"after _start_eat: state=%d job=%s goal=%s path=%d" % [
			unit.state,
			unit.job.voxel_position if unit.job != null else "null",
			unit._goal_voxel,
			unit._path.size(),
		]
	)

	for i in 60:
		await _frames(10)
		print(
			"t=%.1f state=%d job=%s pos=%s sv=%s hunger=%.2f act='%s'" % [
				_elapsed, unit.state,
				unit.job.voxel_position if unit.job != null else "null",
				unit.global_position, unit._standing_voxel(),
				unit.hunger,
				unit.current_activity(),
			]
		)
		if unit.hunger > 0.9:
			break

	# Now the bed: place one 4 cells away and drop energy to the floor.
	var bed_site := site + Vector3i(5, 0, 2)
	var bed := Building.new(Building.Kind.BED, bed_site)
	bed.footprint = [bed_site, bed_site + Vector3i.RIGHT]
	colony.register_building(bed)
	unit.abandon_job()
	unit.hunger = 1.0
	unit.energy = 0.05
	unit._job_search_cooldown = 0.0
	unit._start_rest()
	print(
		"after _start_rest: state=%d job=%s quality=%s path=%d" % [
			unit.state,
			unit.job.voxel_position if unit.job != null else "null",
			unit._rest_quality,
			unit._path.size(),
		]
	)
	for i in 40:
		await _frames(10)
		print(
			"t=%.1f state=%d pos=%s sv=%s quality=%s act='%s'" % [
				_elapsed, unit.state,
				unit.global_position, unit._standing_voxel(),
				unit._rest_quality,
				unit.current_activity(),
			]
		)
		if unit.state == Unit.State.SLEEPING:
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
