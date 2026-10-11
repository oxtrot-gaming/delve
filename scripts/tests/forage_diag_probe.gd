extends SceneTree

## Diagnoses why the open forage job at (-22,40,-17) in the default
## save never gets claimed: reports the job's board state and drop
## records, each unit's state/activity, whether the terrain around the
## bush paths, and what claim_job actually hands out when forced.
##
##     godot --headless --path . --script res://scripts/tests/forage_diag_probe.gd

var target := Vector3i(-22, 40, -17)


func _initialize() -> void:
	_run()


func _run() -> void:
	Main.pending_load = "user://saves/default"
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	while not main._units_spawned:
		await process_frame
	var colony: Colony = main.colony
	var world: VoxelWorld = main.world
	print("colony restored — %d units, %d jobs" % [
		colony.units.size(), colony.jobs.size()
	])

	var job: ColonyJob = null
	for j in colony.jobs:
		if j.voxel_position == target and j.is_active():
			job = j
	print(
		"target job: %s" % (
			"none" if job == null
			else "type=%d state=%d suspended=%s drops=%s" % [
				job.type, job.state, job.suspended, job.dropped_by
			]
		)
	)
	for j in colony.jobs:
		if j.is_active():
			print(
				"  board: %s %s state=%d susp=%s" % [
					ColonyJob.Type.keys()[j.type], j.voxel_position,
					j.state, j.suspended
				]
			)

	# Let the site stream and the units settle.
	for i in 120:
		await process_frame

	print("-- unit snapshot --")
	for u in colony.units:
		var cell: Vector3i = u._standing_voxel()
		print(
			"%s state=%d pos=%s act='%s' rec=%.2f mood=%.2f en=%.2f hu=%.2f" % [
				u.name, u.state, cell, u.current_activity(),
				u.recreation, u.mood, u.energy, u.hunger,
			]
		)
		if job != null:
			var reason := colony.job_block_reason(u, job)
			print(
				"    block_reason='%s' drops=%s" % [
					reason, job.dropped_by.get(u, {})
				]
			)

	if job != null:
		print("-- reachability --")
		print(
			"bush: block=%d editable=%s solid=%s" % [
				world.get_block(target), world.is_editable(target),
				world.is_solid(target)
			]
		)
		for u in colony.units:
			var p := world.find_path(u._standing_voxel(), target)
			print(
				"%s -> target: %d nodes" % [u.name, p.size()]
			)

		# Watch the live claim behaviour for ~20 seconds.
		print("-- live claim watch --")
		for t in 40:
			var summary := ""
			for u in colony.units:
				summary += "%s:s%d " % [u.name, u.state]
			print(
				"t=%.1f %s| job state=%d assignee=%s drops=%s" % [
					t * 0.5, summary, job.state,
					job.assignee.name if job.assignee != null else "none",
					job.dropped_by.size(),
				]
			)
			await create_timer(0.5).timeout

		# Force a claim attempt from each idle unit — claim_job is the
		# same call the idle tick makes.
		print("-- forced claim --")
		for u in colony.units:
			if u.state != Unit.State.IDLE or u.job != null:
				continue
			var claimed: ColonyJob = colony.claim_job(u)
			print(
				"%s claimed: %s" % [
					u.name,
					"nothing" if claimed == null else "%s %s" % [
						ColonyJob.Type.keys()[claimed.type],
						claimed.voxel_position,
					]
				]
			)
			if claimed != null:
				u.abandon_job()
				colony.release_job(claimed)
	print("DONE")
	quit(0)
