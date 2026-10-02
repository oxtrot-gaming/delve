extends SceneTree

## Diagnostic: run complete_butcher + a 300-day decay tick, then hunt for
## any keyed SCRAPS pile that survived the sweep.


func _init() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var world: VoxelWorld = main.get_node("VoxelWorld")
	var colony: Colony = main.get_node("Colony")

	await _wait(func() -> bool: return colony.units.size() > 0)
	colony.forest.set_process(false)
	colony.needs_enabled = false
	for u in colony.units:
		u._job_search_cooldown = 120.0

	var unit: Unit = colony.units[0]
	var base := Vector3i(unit.global_position.floor())

	# A flat run of surface cells, like the wildlife fixture.
	var site := Vector3i.MAX
	for z_off in range(4, 60, 2):
		var z := base.z + z_off
		var run := 0
		var run_g := -1
		var start := Vector3i.MAX
		for x in range(base.x + 4, base.x + 44):
			var g := _ground(world, x, z, base.y + 32)
			var cell := Vector3i(x, g + 1, z)
			var flat := (
				world.is_editable(cell)
				and world.is_editable(Vector3i(x, g, z))
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
			if run >= 10:
				site = start
				break
		if site != Vector3i.MAX:
			break
	print("site=%s" % site)
	if site == Vector3i.MAX:
		quit(1)
		return

	# Fake the worksite — complete_butcher only checks butcher_at(spot).
	var spot := site + Vector3i(2, 0, 0)
	colony.buildings[spot] = Building.new(Building.Kind.BUTCHER, spot)

	# Drive two butcher completions, mirroring the smoke test.
	for i in 2:
		var job := ColonyJob.new(ColonyJob.Type.BUTCHER, spot)
		job.components.append(colony.make_corpse(&"deer"))
		colony._register_job(job)
		colony.complete_butcher(job, unit)
	await _wait(func() -> bool: return colony._in_flight.is_empty())

	var scraps_cell := site + Vector3i(4, 0, 0)
	colony._drop_item(
		DropItem.new(BlockRegistry.Resource_.SCRAPS, DropItem.Form.LOOSE, 40_000),
		scraps_cell
	)
	await _wait(func() -> bool: return colony._in_flight.is_empty())

	_dump_scraps(colony, scraps_cell, "pre-tick")
	colony._decay_tick(300.0 * colony.day_length())
	_dump_scraps(colony, scraps_cell, "post-tick")
	quit(0)


func _dump_scraps(colony: Colony, center: Vector3i, tag: String) -> void:
	for off in range(-3, 4):
		for off2 in range(-3, 4):
			for dy in range(-2, 3):
				var cell := center + Vector3i(off, dy, off2)
				var p: ItemPile = colony.item_pile_at(cell)
				if p == null:
					continue
				var parts := PackedStringArray()
				for item in p.items:
					parts.append(
						"%s:%d:f%d" % [
							BlockRegistry.Resource_.keys()[item.material],
							item.volume, int(item.form)
						]
					)
				print(
					"%s: pile %s at %s: [%s]"
					% [tag, p.get_instance_id(), cell, ", ".join(parts)]
				)


func _ground(world: VoxelWorld, x: int, z: int, from_y: int) -> int:
	for y in range(from_y, -32, -1):
		if world.is_solid(Vector3i(x, y, z)):
			return y
	return -32


func _wait(predicate: Callable, step: float = 0.1) -> bool:
	var deadline := Time.get_ticks_msec() + 30_000
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await create_timer(step).timeout
	return false
