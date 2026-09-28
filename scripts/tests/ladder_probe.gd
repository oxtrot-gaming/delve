extends SceneTree

## Diagnostic: does a unit climbing a ladder to clear a roof pile stand
## in elevated cells that _standing_voxel reports?

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

	# Flat patch: 5 columns at one ground height, clear 5 up.
	var base := Vector3i(unit.global_position.floor())
	var site := Vector3i.MAX
	for dx in range(-40, 41):
		for dz in range(-40, 41):
			var y := _ground(world, base.x + dx, base.z + dz, base.y + 32)
			if y < 0 or abs(dx) < 2:
				continue
			var flat := true
			for ox in range(5):
				for dy in range(5):
					var c := Vector3i(base.x + dx + ox, y + 1 + dy, base.z + dz)
					if (
						_ground(world, c.x, c.z, base.y + 32) != y
						or world.get_block(c) != BlockRegistry.Block.AIR
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

	# Two ladder rungs in the shaft column, deck at +2, roof pile at +3.
	world.sim.set_ladder(site, true)
	world.sim.set_ladder(site + Vector3i.UP, true)
	world.place(site + Vector3i(1, 2, 0), BlockRegistry.Block.DIRT)
	var roof := site + Vector3i(1, 3, 0)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, DropItem.BOULDER_CM3
		),
		roof
	)
	# A plank pile beside the shaft, like the smoke test's.
	var plank_pile := site + Vector3i(2, 0, 0)
	for i in 4:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK, DropItem.PLANK_CM3
			),
			plank_pile
		)
	await _wait(func() -> bool: return colony._in_flight.is_empty())

	var job := colony.designate_clear(roof)
	print("job=%s roof=%s" % [job != null, roof])
	unit.global_position = Vector3(site) + Vector3(-0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	if job != null:
		job.state = ColonyJob.State.ASSIGNED
		job.assignee = unit
		unit.job = job
		unit._fetching = false
		unit._goal_voxel = job.voxel_position
		unit._clear_budget = 0.0
		unit.state = Unit.State.MOVING

	# What spots does the roof pile offer?
	print("cell map (y row / fill in k / standable):")
	for dy in range(-4, 4):
		var row := "  y=%+d: " % dy
		for dx in range(-2, 5):
			for dz in range(-1, 2):
				var c: Vector3i = roof + Vector3i(dx, dy, dz)
				var fill := colony.voxel_fill(c)
				if fill > 0 or world.is_solid(c) or unit._is_standable(c):
					row += "[%d,%d,%s%s] " % [
						dx, dz,
						"S" if world.is_solid(c) else str(fill / 1000),
						"st" if unit._is_standable(c) else "",
					]
		print(row)
	var spots := unit._work_spots(roof, false, false)
	print("roof work spots: %s" % [spots])
	for spot in spots:
		var p := world.find_path(unit._standing_voxel(), spot)
		print("  spot %s: path %d pts clear=%s" % [spot, p.size(), unit._path_is_clear(p)])

	var seen := {}
	for i in 300:
		await _frames(5)
		var sv := unit._standing_voxel()
		seen[sv] = true
		if i % 10 == 0 or unit.state != Unit.State.MOVING:
			print(
				"t=%.1f state=%d pos=%s sv=%s act='%s'" % [
					_elapsed, unit.state, unit.global_position, sv,
					unit.current_activity(),
				]
			)
		if job != null and job.state == ColonyJob.State.DONE:
			break
	print("seen: %s" % [seen.keys()])
	quit()


func _wait(pred: Callable) -> bool:
	for i in 6000:
		if pred.call():
			return true
		await process_frame
	return false


func _frames(n: int) -> void:
	for i in n:
		await process_frame
		_elapsed += 1.0 / 60.0


func _ground(world: VoxelWorld, x: int, z: int, from_y: int) -> int:
	for y in range(from_y, -8, -1):
		var c := Vector3i(x, y, z)
		if not world.is_editable(c):
			continue
		if world.is_solid(c):
			return y
	return -1
