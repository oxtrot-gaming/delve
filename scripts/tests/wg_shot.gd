extends SceneTree

## Render probe: boots the worldgen scene, generates a planet, saves
## screenshots of stage 1 and the globe for visual verification.
##     godot --path . --script res://scripts/tests/wg_shot.gd
## (needs a real renderer — not --headless)

func _init() -> void:
	var wg: Worldgen = load("res://scenes/worldgen.tscn").instantiate()
	root.add_child(wg)
	await process_frame
	await process_frame
	await _shot(root.get_texture().get_image(), "user://wg_stage1.png")
	wg._on_generate_pressed()
	var deadline := Time.get_ticks_msec() + 30000
	while wg._globe == null and Time.get_ticks_msec() < deadline:
		await process_frame
	for i in 30:
		await process_frame
	await _shot(root.get_texture().get_image(), "user://wg_globe.png")
	# Tilt so the shot isn't just the default face.
	wg._globe_root.rotation = Vector3(0.4, 0.9, 0.0)
	for i in 10:
		await process_frame
	await _shot(root.get_texture().get_image(), "user://wg_globe_tilted.png")
	# Select a land tile facing the camera — ring + embark arm.
	var pick := -1
	var best := -2.0
	for t in WorldGlobe.TILE_COUNT:
		if wg._globe.ocean[t] != 0:
			continue
		var local: Vector3 = wg._globe.centers[t]
		var facing: Vector3 = wg._globe_root.global_transform.basis * local
		if facing.z > best:
			best = facing.z
			pick = t
	wg._on_tile_clicked(pick)
	for i in 10:
		await process_frame
	await _shot(root.get_texture().get_image(), "user://wg_selected.png")
	print("shots written to ", OS.get_user_data_dir())
	quit(0)


func _shot(img: Image, path: String) -> void:
	img.save_png(path)
	print("saved ", path)
