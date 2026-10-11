extends SceneTree

## Job-board probe: boots the smoke site, designates a mix of jobs —
## a reachable mine, a buried one nobody can path to, a floating wall
## nobody can support — restricts Unit1 to a small paddock so its rows
## show the allowed-area gate, opens the Work tab's panel and shoots.
##
##     godot --path . --script res://scripts/tests/job_board_shot.gd
## (windowed — the screenshot needs a real viewport)

func _initialize() -> void:
	_run()


func _run() -> void:
	Main.pending_world = {
		&"seed": 1337,
		&"ocean_pct": 60,
		&"temp_bias_c": 0.0,
		&"moist_bias": 0.0,
		&"axial_tilt_deg": 23.0,
		&"world_tile": -1,
		&"package": &"vanilla",
		&"scenario": &"lost_tribe",
	}
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	while not main._units_spawned:
		await process_frame
	var colony: Colony = main.colony
	var hud: CanvasLayer = main.get_node("Hud")
	var gen: Object = main.world.generator_script

	# Paddock Unit1 — any job outside its box reads "outside allowed
	# area" for it on the breakdown.
	var unit0: Unit = colony.units[0]
	var home := Vector3i(unit0.global_position)
	var area := colony.add_area("Paddock")
	var cells: Array[Vector3i] = []
	for dx in range(-5, 6):
		for dz in range(-5, 6):
			for dy in range(-8, 9):
				cells.append(home + Vector3i(dx, dy, dz))
	colony.designate_area_cells(cells, area)
	colony.set_unit_area(unit0, area)
	var ph: int = gen.surface_height(home.x, home.z)
	var gh: int = main.world.ground_height(home.x, home.z)
	print(
		"spawn %s surf=%d ground=%d solid=%s" % [
			home, ph, gh,
			main.world.is_solid(Vector3i(home.x, gh - 1, home.z))
		]
	)

	# Surface mine — a solid voxel with open air just above it, close
	# to camp so somebody actually takes it.
	var near := Vector3i.MAX
	for dx in range(-24, 25):
		for dz in range(-24, 25):
			var c2 := Vector3i(home.x + dx, 0, home.z + dz)
			var h: int = main.world.ground_height(c2.x, c2.z)
			if h < 4:
				continue
			# ground_height lands on the top solid — walk up past any
			# cap (grass blocks, a shallow face) to the exposed cell.
			var top := Vector3i(c2.x, h, c2.z)
			while top.y > h - 6 and (
				not main.world.is_solid(top)
				or main.world.is_solid(top + Vector3i.UP)
			):
				top.y -= 1
			if (
				top.y > h - 6
				and main.world.is_solid(top)
				and not main.world.is_solid(top + Vector3i.UP)
			):
				near = top
		if near != Vector3i.MAX:
			break
	print("near mine: ", near)
	var near_job := colony.designate_mine(near)

	# Deep mine — twenty under the surface. Solid, designated, and
	# unreachable: units claim it, fail to path, give up, cool off.
	var deep := Vector3i(near.x, near.y - 20, near.z)
	print("deep mine: ", deep)
	var deep_job := colony.designate_mine(deep)

	# Floating wall — air five over the surface, no neighbours. The
	# first unit to claim it finds it unsupported and suspends it.
	var air := Vector3i(near.x, near.y + 6, near.z)
	var float_job := colony.designate_build(air, &"dirt_wall")
	print("float wall: ", air, " job=", float_job != null)

	# Let the claim/drop cycle run — the deep job wants a couple of
	# give-ups before the cooldown text shows.
	for i in 900:
		await process_frame

	for job in colony.jobs:
		if job.is_active():
			print(
				"job: %s %s — %s"
				% [
					ColonyJob.Type.keys()[job.type], job.voxel_position,
					colony.job_board_status(job)
				]
			)
	hud._jobs_panel.visible = true
	# Select the deep mine for the per-unit breakdown if it's still live.
	if deep_job != null and deep_job.is_active():
		hud._jobs_selected = deep_job
	elif near_job != null:
		hud._jobs_selected = near_job
	hud._update_jobs_panel()
	print("--- detail ---\n%s" % hud._jobs_detail.text)
	var overseer: Node3D = main.get_node("Overseer")
	overseer.jump_to(Vector3(near))
	overseer._distance = 30.0
	overseer._apply_boom()
	for i in 10:
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png("user://job_board.png")
	print("saved job_board.png")
	quit(0)
