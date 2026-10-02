extends SceneTree

## Diagnostic: drive a downed-unit rescue to a medical bed, then a
## medicined tend — mirrors the smoke test's health section.


func _init() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var world: VoxelWorld = main.get_node("VoxelWorld")
	var colony: Colony = main.get_node("Colony")

	await _wait(func() -> bool: return colony.units.size() > 0)
	colony.forest.set_process(false)
	colony.needs_enabled = false
	for u in colony.units:
		u._job_search_cooldown = 600.0
		u.abandon_job()

	var unit: Unit = colony.units[0]
	var base := Vector3i(unit.global_position.floor())

	var site := Vector3i.MAX
	for z_off in range(4, 80, 2):
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
			if run >= 12:
				site = start
				break
		if site != Vector3i.MAX:
			break
	print("site=%s" % site)
	if site == Vector3i.MAX:
		quit(1)
		return
	site += Vector3i(2, 0, 0)

	# Downed patient.
	var patient := colony.spawn_unit(site)
	patient._job_search_cooldown = 600.0
	await process_frame
	patient.add_wound(&"left_leg", &"cut", 15.0)
	print("patient state=%s downed=%s" % [patient.state, patient.is_downed()])

	# Medical bed two cells over.
	var bed_cell := site + Vector3i(-2, 0, 0)
	var bed := Building.new(Building.Kind.BED, bed_cell)
	bed.footprint.append(bed_cell + Vector3i(1, 0, 0))
	bed.medical = true
	colony.register_building(bed)
	print("med bed at %s -> %s" % [bed_cell, colony.nearest_free_medical_bed(site)])

	colony._medical_tick()
	var rescue_job := colony._patient_job(patient, ColonyJob.Type.RESCUE)
	var tend_job := colony._patient_job(patient, ColonyJob.Type.TEND)
	print("rescue=%s tend=%s" % [rescue_job, tend_job])

	# Drive the rescue.
	unit.global_position = Vector3(site + Vector3i(1, 0, 0)) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	rescue_job.state = ColonyJob.State.ASSIGNED
	rescue_job.assignee = unit
	unit.job = rescue_job
	unit._goal_voxel = site
	unit.state = Unit.State.MOVING
	var watch := 0
	while rescue_job.state != ColonyJob.State.DONE and watch < 1200:
		await process_frame
		watch += 1
	print(
		"rescue done=%s patient rest_bed=%s state=%s pos=%s"
		% [
			rescue_job.state == ColonyJob.State.DONE,
			patient._rest_bed, patient.state, patient.global_position
		]
	)

	# Drive the tend with a medicine bundle on the ground.
	var med_cell := site + Vector3i(4, 0, 0)
	colony._drop_item(
		DropItem.new(BlockRegistry.Resource_.MEDICINE, DropItem.Form.FRUIT, 4),
		med_cell
	)
	await _wait(func() -> bool: return colony._in_flight.is_empty())
	print("med pile at %s: %s" % [med_cell, colony.item_pile_at(med_cell)])

	unit.abandon_job()
	unit.global_position = Vector3(site + Vector3i(3, 0, 0)) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	tend_job.state = ColonyJob.State.ASSIGNED
	tend_job.assignee = unit
	unit.job = tend_job
	unit._fetching = true
	unit._goal_voxel = med_cell
	unit.state = Unit.State.MOVING
	watch = 0
	var last_state := -1
	while tend_job.state != ColonyJob.State.DONE and watch < 1500:
		await process_frame
		watch += 1
		if unit.state != last_state:
			print(
				"t+%d unit %d->%d pos=%s prog=%.2f standing=%s"
				% [
					watch, last_state, unit.state,
					unit.global_position, tend_job.progress,
					unit._standing_voxel(),
				]
			)
			last_state = unit.state
		if watch % 60 == 0:
			print(
				"t+%d tend state=%d unit state=%d pos=%s goal=%s fetching=%s carried=%d"
				% [
					watch, tend_job.state, unit.state,
					unit.global_position, unit._goal_voxel,
					unit._fetching, unit._carried.size(),
				]
			)
	print("tend done=%s progress=%s" % [tend_job.state == ColonyJob.State.DONE, tend_job.progress])
	for w: Dictionary in patient.wounds:
		print("wound %s care=%s sev=%s" % [w[&"part"], w[&"care"], w[&"severity"]])
	quit(0)


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
