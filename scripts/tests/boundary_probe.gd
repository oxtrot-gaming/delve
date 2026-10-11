extends SceneTree

## Colony-boundary check: the overseer focus must stay inside
## site.bounds no matter how the camera is driven (keyboard axes,
## middle-mouse drag, jump-to), and delve_bounds must be the same rect
## the colony reports. Save a screenshot at the edge for the fog veil.
##
##     godot --path . --script res://scripts/tests/boundary_probe.gd
## (windowed — the screenshot needs a real viewport)

var _failures: PackedStringArray = []


func _initialize() -> void:
	_run()


func _check(ok: bool, message: String) -> void:
	if ok:
		print("  ok: ", message)
	else:
		_failures.append(message)
		printerr("  FAILED: ", message)


func _run() -> void:
	Main.pending_world = {
		&"seed": 158916680, &"ocean_pct": 60, &"temp_bias_c": 0.0,
		&"moist_bias": 0.0, &"axial_tilt_deg": 23.0, &"world_tile": 99285,
		&"package": &"vanilla", &"scenario": &"lost_tribe",
	}
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	while not main._units_spawned:
		await process_frame
	var overseer: Node3D = main.get_node("Overseer")
	var b: Rect2i = main.site.bounds
	print("site bounds: ", b)

	# delve_bounds is set from site.bounds in main.gd; the readback is
	# editor-only, so the veil gets verified on the screenshot instead.
	_check(
		main.colony.site_bounds == b,
		"colony.site_bounds matches site record (%s)" % main.colony.site_bounds
	)

	var inside := func(p: Vector3) -> bool:
		return (
			p.x >= float(b.position.x) - 0.01
			and p.x <= float(b.end.x) + 0.01
			and p.z >= float(b.position.y) - 0.01
			and p.z <= float(b.end.y) + 0.01
		)

	# Keyboard pan: hold move_right, the focus must stop at the edge.
	overseer.global_position = Vector3(
		b.get_center().x, 60.0, b.get_center().y
	)
	Input.action_press(&"move_right")
	for i in 600:
		await process_frame
	Input.action_release(&"move_right")
	var p: Vector3 = overseer.global_position
	_check(
		inside.call(p) and p.x > float(b.end.x) - 5.0,
		"keyboard pan pinned at +x edge (x=%.1f, bound=%d)" % [p.x, b.end.x]
	)

	# Middle-mouse drag: an absurd pull in each direction.
	for rel in [
		Vector2(-200000, 0), Vector2(200000, 0),
		Vector2(0, -200000), Vector2(0, 200000),
	]:
		overseer.global_position = Vector3(
			b.get_center().x, 60.0, b.get_center().y
		)
		overseer._pan_screen(rel)
		_check(
			inside.call(overseer.global_position),
			"mmb drag %s clamped (pos=%s)"
				% [rel, overseer.global_position]
		)

	# Jump-to: a target kilometres out must land inside the rect.
	overseer.jump_to(Vector3(b.end.x + 5000, 60.0, b.end.y + 5000))
	_check(
		inside.call(overseer.global_position),
		"jump_to clamped (pos=%s)" % overseer.global_position
	)

	# Screenshot: focus just inside the east edge, camera west of it
	# looking outward — near ground stays clear, the out-of-bounds rim
	# veils off. A second shot from the same spot with the veil disabled
	# (bounds pushed to infinity) is the differential.
	overseer.set_process(false)
	overseer.set_physics_process(false)
	overseer.global_position = Vector3(
		float(b.end.x) - 6.0, 60.0, float(b.get_center().y)
	)
	overseer._yaw = -PI * 0.5
	overseer._pitch = 0.28
	overseer._distance = 42.0
	overseer._apply_boom()
	for i in 240:
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png("user://boundary_shot.png")
	RenderingServer.global_shader_parameter_set(
		&"delve_bounds", Vector4(-1.0e6, -1.0e6, 1.0e6, 1.0e6)
	)
	for i in 30:
		await process_frame
	img = root.get_viewport().get_texture().get_image()
	img.save_png("user://boundary_shot_nofog.png")
	print("saved boundary_shot.png + boundary_shot_nofog.png")

	if _failures.is_empty():
		print("BOUNDARY PROBE PASSED")
		quit(0)
	else:
		quit(1)
