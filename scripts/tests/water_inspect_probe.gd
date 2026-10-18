extends SceneTree

## Water-depth readout probe: wets a column near the first unit, aims
## the camera and mouse at it like a real hover, and prints the depth
## helper plus the inspect/tooltip lines — proving the "water X m"
## display and the depth math.
##
##     godot --path . --script res://scripts/tests/water_inspect_probe.gd
## (windowed — the aim needs a real viewport and mouse)

func _initialize() -> void:
	_run()


func _run() -> void:
	Main.pending_load = "user://saves/default"
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	while not main._units_spawned:
		await process_frame
	for i in 30:
		await process_frame
	var colony: Colony = main.colony
	var world: VoxelWorld = main.world
	var overseer: Overseer = main.get_node("Overseer")
	var hud: CanvasLayer = main.get_node("Hud")

	# A standable cell near the first unit — wet it with a 10 cm film,
	# then aim at it like a mouse hover would.
	var base: Vector3i = Vector3i(colony.units[0].global_position.floor())
	var cell := Vector3i.MAX
	for dx in range(3, 30):
		for dz in range(-15, 16):
			var c := base + Vector3i(dx, 0, dz)
			if (
				world.is_solid(c + Vector3i.DOWN)
				and not world.is_solid(c)
				and not world.is_solid(c + Vector3i.UP)
			):
				cell = c
				break
		if cell != Vector3i.MAX:
			break
	print("cell = %s" % cell)
	if cell == Vector3i.MAX:
		quit(1)
		return

	world.sim.water_add(cell, 100_000)
	overseer.global_position = Vector3(cell) + Vector3(0.5, 0.0, 0.5)
	overseer._distance = 12.0
	for i in 3:
		await process_frame
	var screen := overseer.camera.unproject_position(
		Vector3(cell) + Vector3.ONE * 0.5
	)
	Input.warp_mouse(screen)
	await process_frame
	overseer._update_target()
	hud._hover_dwell = 1.0
	for i in 3:
		await process_frame
	var hit := overseer.targeted_voxel()
	print("hit = %s" % (hit.position if hit != null else null))
	print("depth=%.3f" % hud._water_depth_at(cell.x, cell.z))
	print("inspect: %s" % hud._inspect_label.text)
	if hit != null:
		print("tooltip: %s" % hud._tooltip_text(null, hit))

	world.sim.water_add(cell, 900_000)
	world.sim.water_add(cell + Vector3i.UP, 1_000_000)
	await process_frame
	print("depth=%.3f" % hud._water_depth_at(cell.x, cell.z))
	print("inspect: %s" % hud._inspect_label.text)

	quit(0)
