extends SceneTree

## FlowView screenshot probe: boots the smoke-test site (which wires
## 16 source + 16 drain boundary columns), enables the flow overlay,
## parks the camera over the reach and saves a frame.
##
##     godot --path . --script res://scripts/tests/flow_shot.gd
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
	main.flow_view.set_enabled(true)
	# Find the boundary source columns — the view needs to sit over
	# running water, so aim at the reach carrying the source.
	var target := Vector3i.ZERO
	var found := false
	var bounds: Rect2i = main.site.bounds
	var field: SiteField = main.site_field
	for cz in field.side:
		for cx in field.side:
			if (
				field.flags[cz * field.side + cx]
				& (SiteField.FLAG_WATER | SiteField.FLAG_RIVER)
			) == (SiteField.FLAG_WATER | SiteField.FLAG_RIVER):
				var vx := field.origin.x + cx * field.cell_m + 2
				var vz := field.origin.y + cz * field.cell_m + 2
				if bounds.has_point(Vector2i(vx, vz)):
					target = Vector3i(vx, 60, vz)
					found = true
		if found:
			break
	print("river cell: ", target)
	var overseer: Node3D = main.get_node("Overseer")
	# Pour a strong source beside the reach — a spreading puddle with
	# big flux, so the overlay's arrows must show at full size.
	var dry := Vector3i.ZERO
	var field2 := SiteField.DRY
	var forest: Node = main.world.get_node_or_null("Forest")
	var open := func(x: int, y: int, z: int) -> bool:
		for dy in range(4):
			if forest != null and forest.tree_root_at(Vector3i(x, y + dy, z)) != Vector3i.MAX:
				return false
		return true
	for dz in range(-8, 9):
		for dx in range(-8, 9):
			var c := Vector2i(target.x + dx, target.z + dz)
			if main.world.sim.water_level_at(c.x, c.y) != field2:
				continue
			var h: int = main.world.generator_script.surface_height(c.x, c.y)
			if open.call(c.x, h + 1, c.y):
				dry = Vector3i(c.x, h + 1, c.y)
		if dry != Vector3i.ZERO:
			break
	print("pour at: ", dry)
	main.world.sim.water_set_source(dry, 400000)
	overseer.jump_to(Vector3(dry) + Vector3(0, 60, 0))
	overseer._pitch = 0.8
	overseer._distance = 24.0
	overseer._apply_boom()
	# Let the sim run a few seconds so the reach is actually cycling.
	for i in 600:
		await process_frame
	var flux: PackedVector3Array = main.world.sim.water_flow_field()
	var n := flux.size() / 2
	var biggest := 0.0
	var at := Vector3.ZERO
	for k in range(0, flux.size(), 2):
		var m: float = flux[k + 1].length()
		if m > biggest:
			biggest = m
			at = flux[k]
	print("flow field: %d flux cells, max %.0f cm³ at %s" % [n, biggest, at])
	# Aim at the biggest rendered arrow inside the camera's reachable
	# bounds — straight from the multimesh.
	var mm: MultiMesh = main.flow_view._mmi.multimesh
	var drawn: int = mm.visible_instance_count
	var best_scale := 0.0
	var aim := Vector3.ZERO
	for k in drawn:
		var t: Transform3D = mm.get_instance_transform(k)
		if not bounds.has_point(Vector2i(int(t.origin.x), int(t.origin.z))):
			continue
		var s: float = t.basis.get_scale().x
		if s > best_scale:
			best_scale = s
			aim = t.origin
	print("arrows: %d drawn, biggest scale %.2f at %s" % [drawn, best_scale, aim])
	overseer.jump_to(aim)
	overseer._pitch = 0.9
	overseer._distance = 12.0
	overseer._apply_boom()
	for i in 30:
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png("user://flow_shot.png")
	main.flow_view.set_enabled(false)
	for i in 30:
		await process_frame
	img = root.get_viewport().get_texture().get_image()
	img.save_png("user://flow_shot_off.png")
	print("saved flow_shot.png + flow_shot_off.png")
	quit(0)
