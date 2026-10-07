extends SceneTree

## Focused probe: watch a unit run an UNINSTALL job end to end and
## print its state each second so the stall point is visible.

func _initialize() -> void:
	_run()


func _run() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var world: VoxelWorld = main.get_node("VoxelWorld")
	var colony: Colony = main.get_node("Colony")
	await _wait_until(func() -> bool: return colony.units.size() > 0)
	colony.forest.set_process(false)
	colony.needs_enabled = false
	for u in colony.units:
		u._job_search_cooldown = 600.0
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()

	var ground := func(x: int, z: int) -> int:
		for y in range(96, -32, -1):
			var cell := Vector3i(x, y, z)
			if world.is_editable(cell) and BlockRegistry.is_solid(world.get_block(cell)):
				return y
		return -32
	var row := Vector3i.MAX
	for z in range(0, 400, 8):
		for x in range(0, 200, 4):
			var g: int = ground.call(x, z)
			if g > -32:
				var ok := true
				for i in range(10):
					if ground.call(x + i, z) != g:
						ok = false
				if ok:
					var clear := true
					for i in range(10):
						var c := Vector3i(x + i, g + 1, z)
						if world.get_block(c) != BlockRegistry.Block.AIR or colony.voxel_fill(c) > 0:
							clear = false
					if clear:
						row = Vector3i(x, g + 1, z)
		if row != Vector3i.MAX:
			break
	print("row: ", row)

	var plan := colony.designate_furniture(row, &"table_1x2")
	print("plan: ", plan, " cells=", plan.extra_voxels if plan else [])
	var plank_v := row + Vector3i(7, 0, 0)
	for i in 4:
		colony._deposit_item(
			DropItem.new(BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK, DropItem.PLANK_CM3),
			plank_v
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var worker: Unit = colony.units[0]
	worker.global_position = Vector3(plank_v + Vector3i(0, 0, 1)) + Vector3(0.5, 0.9, 0.5)
	worker.velocity = Vector3.ZERO
	plan.state = ColonyJob.State.ASSIGNED
	plan.assignee = worker
	worker.job = plan
	worker._fetching = true
	worker._goal_voxel = plank_v
	worker._clear_budget = 0.0
	worker.state = Unit.State.MOVING
	var built := await _wait_until(func() -> bool: return plan.state == ColonyJob.State.DONE)
	print("built: ", built, " table: ", colony.building_at(row))

	var un_job := colony.designate_uninstall(row)
	print("uninstall job: ", un_job)
	var shell_v := row + Vector3i(9, 0, 0)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK, DropItem.PLANK_CM3),
		shell_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	print("shell pile: ", colony.item_pile_at(shell_v))
	print("shell query: ", worker._uninstall_shell_voxel())

	worker.global_position = Vector3(shell_v + Vector3i(0, 0, 1)) + Vector3(0.5, 0.9, 0.5)
	worker.velocity = Vector3.ZERO
	un_job.state = ColonyJob.State.ASSIGNED
	un_job.assignee = worker
	worker.job = un_job
	worker._fetching = true
	worker._goal_voxel = shell_v
	worker._clear_budget = 0.0
	worker.state = Unit.State.MOVING

	for i in range(30):
		await _wait_seconds(1.0)
		print(
			"t+%ds state=%s job=%s fetching=%s goal=%s pos=%s carried=%d progress=%.2f" % [
				i, worker.state, worker.job, worker._fetching,
				worker._goal_voxel, Vector3i(worker.global_position.floor()),
				worker._carried.size(), un_job.progress if un_job else -1.0
			]
		)
		if colony.building_at(row) == null:
			print("building gone at t+%d" % i)
			break
	print("crate check:")
	for voxel: Vector3i in colony.item_piles:
		for item in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.CRATE:
				print("  crate at ", voxel, " spec=", item.spec, " packed=", item.packed.size(), " shell=", item.shell.size())
	quit()


func _wait_until(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return false


func _wait_seconds(s: float) -> void:
	var deadline := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame
