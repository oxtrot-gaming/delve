extends SceneTree

## Focused probe: the charcoal mound construct stall seen in smoke_test's
## _test_metals — one log + branch loose → sealed mound.

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

	var ground := func(x: int, z: int) -> int:
		for y in range(96, -32, -1):
			var cell := Vector3i(x, y, z)
			if world.is_editable(cell) and BlockRegistry.is_solid(world.get_block(cell)):
				return y
		return -32
	# A flat run of 8 same-height standable cells.
	var bench := Vector3i.MAX
	for z in range(0, 600, 8):
		var run := 0
		var run_g := -1
		var start := Vector3i.MAX
		for x in range(0, 300):
			var g: int = ground.call(x, z)
			var cell := Vector3i(x, g + 1, z)
			var flat := (
				world.is_editable(cell)
				and g > -32
				and world.get_block(cell) == BlockRegistry.Block.AIR
				and world.is_solid(Vector3i(x, g, z))
				and colony.item_pile_at(cell) == null
			)
			if flat and run > 0 and g == run_g:
				run += 1
			elif flat:
				run = 1
				run_g = g
				start = cell
			else:
				run = 0
			if run >= 8:
				bench = start
				break
		if bench != Vector3i.MAX:
			break
	print("bench: ", bench)
	if bench == Vector3i.MAX:
		quit(1)
		return

	var log_cell := bench
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3),
		log_cell
	)
	var branch_cell := bench + Vector3i(1, 0, 0)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.BRANCH, DropItem.Form.LOOSE, 120_000),
		branch_cell
	)
	var mound_cell := bench + Vector3i(2, 0, 0)
	var job := colony.designate_production(mound_cell, &"charcoal_mound")
	print("mound job: ", job != null)
	# Mirror the suite's post-fix _park_beside: beside the branch pile,
	# toward the site, skipping the site cell itself.
	var park := branch_cell
	var first := Vector3i(mound_cell - branch_cell).sign()
	var sides: Array[Vector3i] = []
	if first != Vector3i.ZERO:
		sides.append(first)
	for side in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]:
		if not sides.has(side):
			sides.append(side)
	for side in sides:
		var c: Vector3i = branch_cell + side
		if c == mound_cell:
			continue
		if (
			world.get_block(c) == BlockRegistry.Block.AIR
			and world.is_solid(c + Vector3i.DOWN)
			and colony.voxel_fill(c) <= 0
		):
			park = c
			break
	print("park: ", park)
	unit.global_position = Vector3(park) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = unit
	unit.job = job
	unit._fetching = true
	unit._goal_voxel = branch_cell
	unit._clear_budget = 0.0
	unit.state = Unit.State.MOVING

	for i in 40:
		await create_timer(0.25).timeout
		print(
			"t=", i,
			" state=", unit.state,
			" pos=", unit.global_position.floor(),
			" goal=", unit._goal_voxel,
			" fetching=", unit._fetching,
			" carried=", unit._carried_volume(),
			" delivered=", job.delivered,
			" progress=", snappedf(job.progress, 0.1),
			" jobstate=", job.state,
			" standing=", unit._standing_voxel(),
			" path=", unit._path_index, "/", unit._path.size(),
			" trail=", unit.decision_trail().split("\n")[-1] if unit.job != null else "nojob"
		)
		if unit.job == null:
			print("TRAIL:\n", unit.decision_trail())
			break
		if job.state == ColonyJob.State.DONE:
			break
	print("building: ", colony.building_at(mound_cell))
	print("burn job: ", colony.burn_job_at(mound_cell))
	var bj := colony.burn_job_at(mound_cell)
	if bj != null:
		colony.complete_burn(bj)
		for dx in range(-3, 4):
			for dy in range(-2, 3):
				for dz in range(-3, 4):
					var p := colony.item_pile_at(mound_cell + Vector3i(dx, dy, dz))
					if p != null:
						var s := ""
						for it in p.items:
							s += "%s:%d " % [BlockRegistry.Resource_.keys()[it.material], it.volume]
						print("pile ", mound_cell + Vector3i(dx, dy, dz), " -> ", s)

	# Smelter + smelt bill — exercises input_loose fetch (two LOOSE mats).
	var cobble_cell := bench + Vector3i(3, 0, 0)
	for i in 8:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE, DropItem.Form.COBBLE,
				DropItem.COBBLE_CM3
			),
			cobble_cell
		)
	var smelter_cell := bench + Vector3i(4, 0, 0)
	var sjob := colony.designate_production(smelter_cell, &"pit_smelter")
	print("smelter job: ", sjob != null)
	unit.global_position = Vector3(log_cell + Vector3i.LEFT) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	sjob.state = ColonyJob.State.ASSIGNED
	sjob.assignee = unit
	unit.job = sjob
	unit._fetching = true
	unit._goal_voxel = cobble_cell
	unit._clear_budget = 0.0
	unit.state = Unit.State.MOVING
	var sbuilt := await _wait_until(
		func() -> bool: return sjob.state == ColonyJob.State.DONE
	)
	if not sbuilt:
		print("TRAIL:\n", unit.decision_trail())
	print("smelter built: ", sbuilt)

	var ore_cell := bench + Vector3i(5, 0, 0)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.MALACHITE, DropItem.Form.LOOSE,
			Colony.SMELT_BATCH_CM3
		),
		ore_cell
	)
	var fuel_cell := bench + Vector3i(6, 0, 0)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.CHARCOAL, DropItem.Form.LOOSE,
			Colony.SMELT_BATCH_CM3
		),
		fuel_cell
	)
	# A red-herring loose pile the fetch must NOT count.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 400_000
		),
		bench + Vector3i(7, 0, 0)
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var order := colony.queue_order(smelter_cell, &"smelt_copper")
	print("smelt order: ", order != null)
	var smelt := colony.craft_job_at(smelter_cell)
	print("smelt dispatched: ", smelt != null)
	if smelt == null:
		quit(2)
		return
	unit.skills[ColonyJob.Skill.PIT_SMELTING] = Unit.SKILL_XP_BASE
	unit.global_position = Vector3(log_cell + Vector3i.LEFT) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	smelt.state = ColonyJob.State.ASSIGNED
	smelt.assignee = unit
	unit.job = smelt
	unit._fetching = true
	unit._goal_voxel = ore_cell
	unit._clear_budget = 0.0
	unit.state = Unit.State.MOVING
	for i in 40:
		await create_timer(0.5).timeout
		print(
			"s", i, " state=", unit.state, " pos=", unit.global_position.floor(),
			" goal=", unit._goal_voxel, " fetching=", unit._fetching,
			" carried=", unit._carried_volume(),
			" delivered=", smelt.delivered,
			" progress=", snappedf(smelt.progress, 0.1),
			" jobstate=", smelt.state
		)
		if smelt.state == ColonyJob.State.DONE:
			break
	var copper := 0
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var p := colony.item_pile_at(smelter_cell + Vector3i(dx, dy, dz))
				if p == null:
					continue
				for item in p.items:
					if item.material == BlockRegistry.Resource_.COPPER:
						copper += item.volume
	print("copper: ", copper, " want=", Colony.SMELT_BATCH_CM3 / 2)
	quit(0)


func _wait_until(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 120_000
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return false
