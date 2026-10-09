extends SceneTree

## Focused repro for the smoke suite's "the unit picks up the second
## log" failure: boots the real world, runs the exact two-order craft
## sequence, and dumps worker/job/pile state when the second pickup
## stalls.
##
##     godot --headless --path . --script res://scripts/tests/craft_repro.gd

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


func _clear_jobs(colony: Colony) -> void:
	for job in colony.jobs:
		if job.state != ColonyJob.State.DONE:
			job.state = ColonyJob.State.CANCELLED
	colony._prune_jobs()


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


func _assign_craft(colony: Colony, world: VoxelWorld, site: Vector3i, pile_v: Vector3i) -> ColonyJob:
	_clear_jobs(colony)
	var job := colony.designate_craft(site, &"planks")
	if job == null:
		return null
	_drive_craft(colony, world, job, pile_v, site)
	return job


func _dump(label: String, colony: Colony, worker: Unit, job: ColonyJob, log_v: Vector3i) -> void:
	print("--- ", label)
	print("  worker state=%s fetching=%s goal=%s pos=%s" % [
		Unit.State.keys()[worker.state] if worker != null else "?",
		worker._fetching if worker != null else "?",
		worker._goal_voxel if worker != null else "?",
		worker._standing_voxel() if worker != null else "?",
	])
	print("  carried=%s" % [worker._carried.map(func(i): return "%s:%s" % [DropItem.Form.keys()[i.form], i.volume]) if worker != null else "?"])
	print("  job state=%s assignee=%s progress=%s" % [
		ColonyJob.State.keys()[job.state] if job != null else "?",
		job.assignee if job != null else "?",
		job.progress if job != null else "?",
	])
	var pile: ItemPile = colony.item_pile_at(log_v)
	if pile == null:
		print("  pile at log_v: NONE")
	else:
		print("  pile at log_v: %s" % [pile.items.map(func(i): return "%s:%s" % [DropItem.Form.keys()[i.form], i.volume])])
	for v: Vector3i in colony.item_piles:
		if (v - log_v).length() <= 2 and v != log_v:
			print("  nearby pile %s: %s" % [v, colony.item_piles[v].items.map(func(i): return "%s:%s" % [DropItem.Form.keys()[i.form], i.volume])])


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
	# Same anchor the suite uses: the solid voxel two cells east of the
	# spawn unit, actually mined open before the subtests run.
	var mined := Vector3i.MAX
	var origin := Vector3i(unit.global_position.floor())
	for offset in [Vector3i(2,0,0), Vector3i(-2,0,0), Vector3i(0,0,2), Vector3i(0,0,-2)]:
		var column: Vector3i = origin + offset
		var gy := _ground(world, column.x, column.z, origin.y + 16, origin.y - 16)
		var candidate := Vector3i(column.x, gy, column.z)
		if world.is_solid(candidate):
			mined = candidate
			break
	if mined == Vector3i.MAX:
		print("REPRO: no mine target")
		quit(1)
		return
	# Units need picks to mine — arm them like the suite preamble does.
	for u in colony.units:
		var tool := DropItem.new(
			int(DropItem.tool_spec(&"stone_pick").get(&"head", BlockRegistry.Resource_.STONE)),
			DropItem.Form.TOOL, DropItem.TOOL_CM3
		)
		tool.spec = &"stone_pick"
		tool.wear = 1.0
		u.hold_tool(tool)
	var mine_job := colony.designate_mine(mined)
	if mine_job != null:
		var mdone := await _wait_until(func() -> bool:
			return not world.is_solid(mined), 30.0)
		print("mined target: ", mdone)
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	# The suite disarms after the mine — carried tools halve carry
	# capacity and poison later fetches.
	for u in colony.units:
		u.hands.clear()
		u.abandon_job()

	var spot := Vector3i.MAX
	for z_off in [168, 176, 184, 192]:
		var candidate := _flat_voxel_row(world, mined, z_off)
		if candidate != Vector3i.MAX:
			spot = candidate
			break
	if spot == Vector3i.MAX:
		print("REPRO: no flat spot")
		quit(1)
		return
	var log_v := spot + Vector3i(2, 0, 0)
	print("spot=%s log_v=%s mined=%s" % [spot, log_v, mined])

	# Suite-faithful environment: a stockpile zone exists (zone tests run
	# before craft in the suite), so self-issued hauls can actually find a
	# destination — without one, `_try_start_haul` early-returns and the
	# idle-haul behaviour the suite exercises never appears.
	var sp_v := spot + Vector3i(0, 0, -6)
	var sp_g := _ground(world, sp_v.x, sp_v.z, spot.y + 16)
	sp_v.y = sp_g + 1
	for dx in range(4):
		var cell := sp_v + Vector3i(dx, 0, 0)
		var g := _ground(world, cell.x, cell.z, spot.y + 16)
		cell.y = g + 1
		colony.designate_stockpile(cell)
	print("stockpile row at %s" % sp_v)

	# _test_spilling's leftovers — the suite contaminant that makes the
	# second-log fetch fail: scattered piles around `mined` shift every
	# later fixture's position and leave haulable debris near the band.
	var shelf := Vector3i(mined.x - 6, 0, mined.z - 6)
	shelf.y = _ground(world, shelf.x, shelf.z, mined.y + 32) + 5
	var packed := shelf + Vector3i.UP
	world.place(shelf, BlockRegistry.Block.STONE)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1500000), packed)
	colony._drop_item(
		DropItem.new(BlockRegistry.Resource_.STONE, DropItem.Form.COBBLE, DropItem.COBBLE_CM3), packed)
	world.mine(shelf)
	var lower_spot := Vector3i(mined.x + 6, 0, mined.z - 6)
	lower_spot.y = _ground(world, lower_spot.x, lower_spot.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1000000), lower_spot)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 300000), lower_spot + Vector3i.UP)
	colony._drop_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 400000), mined + Vector3i(0, 3, 0))
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	colony.designate_craft_spot(spot)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	var job := _assign_craft(colony, world, spot, log_v)
	if job == null:
		print("REPRO: first order didn't post")
		quit(1)
		return
	var done := await _wait_until(func() -> bool: return job.state == ColonyJob.State.DONE)
	print("first order done: ", done)
	if not done:
		_dump("first order stalled", colony, job.assignee, job, log_v)
		quit(1)
		return
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	# Second order — the failure path.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3),
		log_v
	)
	var job2 := _assign_craft(colony, world, spot, log_v)
	if job2 == null:
		print("REPRO: second order didn't post")
		quit(1)
		return
	var carrying := await _wait_until(
		func() -> bool: return job2.assignee._carried_form(DropItem.Form.LOG) != null,
		30.0
	)
	print("second log carried: ", carrying)
	if not carrying:
		_dump("second pickup stalled", colony, job2.assignee, job2, log_v)
		quit(1)
		return
	print("CRAFT REPRO PASSED")
	quit(0)
