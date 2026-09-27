extends SceneTree

## Focused probe: reproduce the bed-craft stall and bed_cells veto.

func _initialize() -> void:
	_run()

func _run() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var world: VoxelWorld = main.get_node("VoxelWorld")
	var colony: Colony = main.get_node("Colony")
	var spawned := await _wait_until(func() -> bool: return colony.units.size() > 0)
	print("spawned: ", spawned)
	colony.forest.set_process(false)
	colony.needs_enabled = false
	var unit: Unit = colony.units[0]
	for u in colony.units:
		u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()

	# Find a flat spot anywhere: scan a grid for 4 columns of equal ground.
	var ground := func(x: int, z: int) -> int:
		for y in range(96, -32, -1):
			var cell := Vector3i(x, y, z)
			if world.is_editable(cell) and BlockRegistry.is_solid(world.get_block(cell)):
				return y
		return -32
	var spot := Vector3i.MAX
	for z in range(0, 400, 8):
		for x in range(0, 200, 4):
			var g: int = ground.call(x, z)
			if (
				g > -32
				and ground.call(x + 1, z) == g
				and ground.call(x + 2, z) == g
				and ground.call(x + 3, z) == g
				and world.is_solid(Vector3i(x + 1, g, z))
				and world.get_block(Vector3i(x + 1, g + 1, z)) == BlockRegistry.Block.AIR
			):
				spot = Vector3i(x + 1, g + 1, z)
				break
		if spot != Vector3i.MAX:
			break
	print("spot: ", spot)

	# Mirror the smoke test's scan: how many columns per row yield a bed site?
	for z in range(spot.z, spot.z + 420, 16):
		var found := Vector3i.MAX
		for x in range(spot.x, spot.x + 96):
			var g: int = ground.call(x, z)
			var candidate := Vector3i(x, g + 1, z)
			if colony.bed_cells(candidate).size() == 2:
				found = candidate
				break
		print("row z=", z, " -> ", found)

	# Why would bed_cells veto the spot and its neighbors?
	print("bed_cells: ", colony.bed_cells(spot))
	for c in [spot, spot + Vector3i.RIGHT, spot + Vector3i.LEFT,
			spot + Vector3i.FORWARD, spot + Vector3i.BACK]:
		print(
			"  cell ", c, " block=", world.get_block(c),
			" fill=", colony.voxel_fill(c),
			" solid_below=", world.is_solid(c + Vector3i.DOWN),
			" marker=", colony._designation_markers.has(c),
			" building=", colony.buildings.has(c),
			" tree=", colony.forest.tree_root_at(c)
		)

	# Craft a bed kit: spot, six planks, assigned directly.
	print("craft spot ok: ", colony.designate_craft_spot(spot))
	var plank_v := spot + Vector3i(2, 0, 0)
	for i in 6:
		colony._deposit_item(
			DropItem.new(BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK, DropItem.PLANK_CM3),
			plank_v
		)
	var job := colony.designate_craft(spot, &"bed")
	print("craft job: ", job != null, " recipe=", job.recipe if job != null else &"")
	unit.global_position = Vector3(plank_v) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = unit
	unit.job = job
	unit._fetching = true
	unit._goal_voxel = plank_v
	unit._clear_budget = 0.0
	unit.state = Unit.State.MOVING

	for i in 30:
		await create_timer(1.0).timeout
		var pile := colony.item_pile_at(plank_v)
		print(
			"t=", i,
			" state=", unit.state,
			" pos=", unit.global_position,
			" goal=", unit._goal_voxel,
			" fetching=", unit._fetching,
			" carried=", unit._carried_volume(),
			" delivered=", job.delivered,
			" progress=", job.progress,
			" jobstate=", job.state,
			" pilevol=", pile.total_volume() if pile != null else -1,
			" path=", unit._path_index, "/", unit._path.size(),
			" pathpts=", unit._path.slice(0, 4),
			" standing=", unit._standing_voxel(),
			" stuck=", unit._stuck_elapsed,
			" grounded=", unit._grounded
		)
		if job.state == ColonyJob.State.DONE:
			break

	# Furnish a bed and watch the rest-claim path.
	var bed_site := Vector3i.MAX
	for dz in range(3, 30):
		for dx in range(-4, 20):
			var candidate := spot + Vector3i(dx, 0, dz)
			if colony.bed_cells(candidate).size() == 2:
				bed_site = candidate
				break
		if bed_site != Vector3i.MAX:
			break
	print("bed_site: ", bed_site, " cells: ", colony.bed_cells(bed_site))
	if bed_site == Vector3i.MAX:
		quit(1)
	var second: Vector3i = colony.bed_cells(bed_site)[1]
	var plan := colony.designate_bed(bed_site)
	print("plan: ", plan != null)
	var kit_v := bed_site + Vector3i(0, 0, 2)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.WOOD, DropItem.Form.BED, DropItem.BED_KIT_CM3),
		kit_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var park := kit_v
	for side in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]:
		var c: Vector3i = kit_v + side
		if (
			world.get_block(c) == BlockRegistry.Block.AIR
			and world.is_solid(c + Vector3i.DOWN)
			and colony.voxel_fill(c) <= 0
		):
			park = c
			break
	unit.global_position = Vector3(park) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	plan.state = ColonyJob.State.ASSIGNED
	plan.assignee = unit
	unit.job = plan
	unit._fetching = true
	unit._goal_voxel = kit_v
	unit._clear_budget = 0.0
	unit.state = Unit.State.MOVING
	var built := await _wait_until(func() -> bool:
		return colony.building_at(bed_site) != null)
	print("built: ", built)
	var bed: Building = colony.building_at(bed_site)
	print("bed: ", bed != null, " occupant=", bed.occupant if bed != null else -1)
	print("nearest_free_bed: ", colony.nearest_free_bed(unit._standing_voxel()))
	colony.needs_enabled = true
	unit.energy = 0.1
	unit._job_search_cooldown = 0.0
	for i in 10:
		await create_timer(0.5).timeout
		print(
			"r", i, " state=", unit.state, " pos=", unit.global_position,
			" restbed=", unit._rest_bed, " quality=", unit._rest_quality,
			" job=", unit.job, " energy=", unit.energy,
			" path=", unit._path_index, "/", unit._path.size()
		)
		if unit.state == Unit.State.SLEEPING:
			break
	quit(0)


func _wait_until(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 120_000
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return false
