extends SceneTree

## Focused repro for the metals-line pour stalls: boots the real world,
## builds a firebrick refractory, and runs the alloy_bronze bill while
## dumping worker/job state each second.
##
##     godot --headless --path . --script res://scripts/tests/alloy_probe.gd

const TIMEOUT_SECONDS := 60.0


func _initialize() -> void:
	_run()


func _wait_until(predicate: Callable, seconds: float = TIMEOUT_SECONDS) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return false


func _ground(world: VoxelWorld, x: int, z: int, from_y: int, min_y: int = -32) -> int:
	for y in range(from_y, min_y - 1, -1):
		if world.is_solid(Vector3i(x, y, z)):
			return y
	return min_y


func _flat_voxel_row(world: VoxelWorld, mined: Vector3i, z_off: int) -> Vector3i:
	var z: int = mined.z + z_off
	for x in range(mined.x + 4, mined.x + 40):
		var g := _ground(world, x, z, mined.y + 32)
		var spot := Vector3i(x + 1, g + 1, z)
		if (
			_ground(world, x + 1, z, mined.y + 32) == g
			and _ground(world, x + 2, z, mined.y + 32) == g
			and _ground(world, x + 3, z, mined.y + 32) == g
			and _ground(world, x + 4, z, mined.y + 32) == g
			and _ground(world, x + 5, z, mined.y + 32) == g
			and _ground(world, x + 6, z, mined.y + 32) == g
			and _ground(world, x + 7, z, mined.y + 32) == g
			and world.is_editable(Vector3i(x + 1, g, z))
			and world.is_editable(spot)
			and world.get_block(spot) == BlockRegistry.Block.AIR
			and world.is_solid(Vector3i(x + 1, g, z))
			and world.generator_script.water_depth_at(x + 1, z) == 0
		):
			return spot
	return Vector3i.MAX


func _park_beside(colony: Colony, world: VoxelWorld, voxel: Vector3i, toward: Vector3i) -> Vector3i:
	var first := Vector3i(toward - voxel).sign()
	var sides: Array[Vector3i] = []
	if first != Vector3i.ZERO:
		sides.append(first)
	for side in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]:
		if not sides.has(side):
			sides.append(side)
	for side in sides:
		var candidate := voxel + side
		if candidate == toward:
			continue
		if (
			world.get_block(candidate) == BlockRegistry.Block.AIR
			and world.is_solid(candidate + Vector3i.DOWN)
			and colony.voxel_fill(candidate) <= 0
		):
			return candidate
	return voxel


func _drive_craft(colony: Colony, world: VoxelWorld, job: ColonyJob, pile_v: Vector3i, site: Vector3i) -> void:
	var worker: Unit = colony.units[0]
	var away_x: int = site.x - 20
	var away := Vector3i(
		away_x, _ground(world, away_x, site.z, site.y + 32) + 1, site.z
	)
	for u in colony.units:
		if u != worker:
			u._job_search_cooldown = 120.0
		u.global_position = Vector3(away) + Vector3(0.5, 0.9, 0.5)
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()
	worker.global_position = Vector3(_park_beside(colony, world, pile_v, site)) + Vector3(0.5, 0.9, 0.5)
	worker.velocity = Vector3.ZERO
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = worker
	worker.job = job
	worker._fetching = true
	worker._goal_voxel = pile_v
	worker._clear_budget = 0.0
	worker.state = Unit.State.MOVING


func _dump(label: String, colony: Colony, job: ColonyJob, stock: Vector3i) -> void:
	print("--- ", label)
	var worker: Unit = colony.units[0]
	print("  worker state=%s fetching=%s goal=%s pos=%s carried=%d job=%s" % [
		Unit.State.keys()[worker.state],
		worker._fetching,
		worker._goal_voxel,
		worker._standing_voxel(),
		worker._carried.size(),
		job.recipe if worker.job != null else &"none",
	])
	print("  job state=%s assignee=%s progress=%s delivered=%s" % [
		ColonyJob.State.keys()[job.state],
		worker == job.assignee,
		job.progress,
		job.delivered,
	])
	var pile: ItemPile = colony.item_pile_at(stock)
	print("  stock pile: %s" % [
		"NONE" if pile == null else str(pile.items.map(
			func(i): return "%s:%s" % [BlockRegistry.resource_name_of(i.material), i.volume]
		))
	])


func _run() -> void:
	DataPackage.install(&"vanilla", &"dev")
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var world: VoxelWorld = main.get_node("VoxelWorld")
	var colony: Colony = main.get_node("Colony")
	var spawned := await _wait_until(func() -> bool: return colony.units.size() > 0)
	if not spawned:
		print("REPRO: no units")
		quit(1)
		return
	if world.sim != null:
		world.sim.water_set_paused(true)
	colony.forest.set_process(false)
	colony.needs_enabled = false
	colony.auto_home = false
	var unit: Unit = colony.units[0]
	unit.skills[ColonyJob.Skill.PIT_SMELTING] = Unit.SKILL_XP_BASE
	unit.skills[ColonyJob.Skill.BLOOMERY_SMELTING] = Unit.SKILL_XP_BASE

	var origin := Vector3i(unit.global_position.floor())
	# Suite-faithful: a second, free-roaming unit plus a stockpile zone
	# it can haul the fixture piles into — the interference the suite's
	# shared colony exposes.
	var other := colony.spawn_unit(origin + Vector3i(4, 0, 4))
	var sp_v := origin + Vector3i(0, 0, 10)
	sp_v.y = _ground(world, sp_v.x, sp_v.z, origin.y + 16) + 1
	for dx in range(4):
		var cell := sp_v + Vector3i(dx, 0, 0)
		var g := _ground(world, cell.x, cell.z, origin.y + 16)
		cell.y = g + 1
		colony.designate_stockpile(cell)
	other._job_search_cooldown = 0.0
	var row := Vector3i.MAX
	for z_off in [40, 60, 80, 168, 184]:
		row = _flat_voxel_row(world, origin, z_off)
		if row != Vector3i.MAX:
			break
	if row == Vector3i.MAX:
		print("REPRO: no flat row")
		quit(1)
		return
	print("row=%s" % row)

	# Stock: firebrick for the build, copper+tin+charcoal for the pour.
	# Suite-faithful: the fixture piles sit on designated stockpile
	# cells — a bare pile is a haul target the free unit would empty
	# mid-fetch.
	var brick_stock := row
	var cells: Array[Vector3i] = [brick_stock]
	colony.designate_stockpile_cells(cells, brick_stock, true)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.FIREBRICK, DropItem.Form.LOOSE, 260_000),
		brick_stock
	)
	var metals_stock := row + Vector3i(2, 0, 0)
	var mcells: Array[Vector3i] = [metals_stock]
	colony.designate_stockpile_cells(mcells, metals_stock, true)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.COPPER, DropItem.Form.LOOSE, 90_000),
		metals_stock
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.TIN, DropItem.Form.LOOSE, 10_000),
		metals_stock
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.CHARCOAL, DropItem.Form.LOOSE, 480_000),
		metals_stock
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	var site := row + Vector3i(4, 0, 0)
	var build := colony.designate_production(site, &"refractory")
	print("build job: %s" % (build != null))
	if build == null:
		quit(1)
		return
	_drive_craft(colony, world, build, brick_stock, site)
	var built := await _wait_until(func() -> bool: return build.state == ColonyJob.State.DONE)
	print("refractory built: ", built)
	if not built:
		_dump("build stalled", colony, build, brick_stock)
		quit(1)
		return

	var order := colony.queue_order(site, &"alloy_bronze")
	print("order: %s" % (order != null))
	var job := colony.craft_job_at(site)
	print("job dispatched: %s" % (job != null))
	if job == null:
		quit(1)
		return
	_drive_craft(colony, world, job, metals_stock, site)
	var poured := await _wait_until(func() -> bool: return job.state == ColonyJob.State.DONE, 20.0)
	print("bronze poured: ", poured)
	if not poured:
		_dump("pour stalled", colony, job, metals_stock)
		quit(1)
		return
	print("ALLOY PROBE PASSED")
	quit(0)
