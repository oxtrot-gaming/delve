extends SceneTree

## Focused probe for item 49 regressions: a ladder fetch from a dense
## plank pile, clearing a packed pile out of a walled hole, and the
## room-starved detour blacklist.

var fails := 0


func ok(cond: bool, label: String) -> void:
	if cond:
		print("  ok: " + label)
	else:
		fails += 1
		print("  FAILED: " + label)


func _initialize() -> void:
	_run()


func _wait_until(pred: Callable, frames := 4000) -> bool:
	var i := 0
	while not pred.call() and i < frames:
		await physics_frame
		i += 1
	return pred.call()


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
				var flat := true
				for i in range(14):
					if ground.call(x + i, z) != g:
						flat = false
				if flat:
					var clear := true
					for i in range(14):
						var c := Vector3i(x + i, g + 1, z)
						if world.get_block(c) != BlockRegistry.Block.AIR or colony.voxel_fill(c) > 0:
							clear = false
					if clear:
						row = Vector3i(x, g + 1, z)
		if row != Vector3i.MAX:
			break
	print("row: ", row)
	if row == Vector3i.MAX:
		print("no flat row")
		quit(1)
		return

	# --- Ladder: 4 planks (800k = dense) at a pile; the job takes 3.
	var site := row + Vector3i(2, 0, 0)
	var plank_v := row + Vector3i(4, 0, 0)
	for i in 4:
		colony._deposit_item(
			DropItem.new(BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK, DropItem.PLANK_CM3),
			plank_v
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	ok(colony.is_dense_pile(plank_v), "four planks pack a dense pile")
	var job := colony.designate_ladder(site)
	ok(job != null, "a ladder designates beside a dense pile")
	if job != null:
		var worker: Unit = colony.units[0]
		worker.global_position = Vector3(plank_v + Vector3i(0, 0, 1)) + Vector3(0.5, 0.9, 0.5)
		worker.velocity = Vector3.ZERO
		job.state = ColonyJob.State.ASSIGNED
		job.assignee = worker
		worker.job = job
		worker._fetching = false
		worker._goal_voxel = job.voxel_position
		worker._clear_budget = 0.0
		worker.state = Unit.State.MOVING
		var built := await _wait_until(func() -> bool: return job.state == ColonyJob.State.DONE)
		ok(built, "the ladder builds from a dense pile")
		# The dense pile blocks the worker's line — reaching the site
		# shoves the heap aside, so the leftover plank may land in a
		# neighbour. What must hold is conservation: one plank survives
		# somewhere near the pile.
		var plank_cm3 := 0
		for v in colony.item_piles:
			for it in colony.item_piles[v].items:
				if it.form == DropItem.Form.PLANK:
					plank_cm3 += it.volume
		ok(
			plank_cm3 == DropItem.PLANK_CM3,
			"the fourth plank survives the build"
		)
		if plank_cm3 != DropItem.PLANK_CM3:
			print("    plank total ", plank_cm3, "; near planks:")
			for v in colony.item_piles:
				for it in colony.item_piles[v].items:
					if it.form == DropItem.Form.PLANK:
						print("      ", v - plank_v, " ", it.volume)

	# --- Walled hole: an air cell on the ground, walled on four sides,
	# open top — matching _test_hole's geometry.
	var hole := row + Vector3i(8, 0, 0)
	for side: Vector3i in [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.FORWARD, Vector3i.BACK]:
		var wall_cell := hole + side
		world.remove_voxel(wall_cell)
		world.place(wall_cell, BlockRegistry.Block.STONE)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1250000),
		hole
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	print("hole fill:", colony.voxel_fill(hole), " rim fill:", colony.voxel_fill(hole + Vector3i.UP))
	var cjob := colony.designate_clear(hole)
	ok(cjob != null, "the hole pile designates for clearing")
	if cjob != null:
		# Natural assignment — the nearest idle unit walks over on its own.
		for u in colony.units:
			u._job_search_cooldown = 0.0
		var t0 := Time.get_ticks_msec()
		var cleared := false
		var worker2: Unit = null
		for i in 4800:
			await physics_frame
			if cjob.assignee != null and worker2 == null:
				worker2 = cjob.assignee
			if colony.item_pile_at(hole) == null:
				cleared = true
				break
			if i % 300 == 0:
				print(
					(
						"    t+%d fill=%d assignee=%s state=%s goal=%s pos=%s"
						% [
							i, colony.voxel_fill(hole), worker2,
							(
								Unit.State.keys()[worker2.state]
								if worker2
								else "?"
							),
							worker2._goal_voxel if worker2 else "?",
							Vector3i(worker2.global_position) if worker2 else "?",
						]
					)
				)
		print("    cleared in %d ms wall" % (Time.get_ticks_msec() - t0))
		ok(cleared, "a unit clears the pile out of a walled hole")

	print("fails: ", fails)
	quit(0 if fails == 0 else 1)
