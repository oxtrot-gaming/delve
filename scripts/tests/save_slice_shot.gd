extends SceneTree

## Slice-cap check on the user's real save: loads it, parks the camera
## over the colony anchor, slices down two levels and screenshots each.

func _initialize() -> void:
	_run()


func _run() -> void:
	Main.pending_load = "user://saves/default"
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	while not main._units_spawned:
		await process_frame
	var slice: SliceView = main.slice_view
	var overseer: Node3D = main.get_node("Overseer")
	overseer.set_process(false)
	overseer.set_physics_process(false)
	var anchor: Vector3i = main.site.anchor
	var cam: Camera3D = overseer.find_child("Camera3D")
	cam.global_position = Vector3(anchor) + Vector3(30, 30, 30)
	cam.look_at(Vector3(anchor))
	for i in 60:
		await process_frame
	var ground := int(overseer._terrain_height())
	print("anchor=%s ground=%d" % [anchor, ground])
	slice.adjust(-1, ground + 1)
	for i in 400:
		await process_frame
		if i % 100 == 99:
			print("lvl1 %d: tiles=%d pending=%d top=%d" % [
				i, slice._tiles.size(), slice._pending.size(),
				slice.top_layer])
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png("user://save_lvl1.png")
	slice.adjust(-1, ground + 1)
	for i in 400:
		await process_frame
		if i % 100 == 99:
			print("lvl2 %d: tiles=%d pending=%d top=%d" % [
				i, slice._tiles.size(), slice._pending.size(),
				slice.top_layer])
	img = root.get_viewport().get_texture().get_image()
	img.save_png("user://save_lvl2.png")
	# Close-up, shallow angle over the cap field — z-fighting reads
	# as interleaved pixels between two near-coplanar surfaces.
	cam.global_position = Vector3(
		anchor.x + 14, ground + 8, anchor.z + 14)
	cam.look_at(Vector3(anchor.x, ground - 2, anchor.z))
	for i in 30:
		await process_frame
	img = root.get_viewport().get_texture().get_image()
	img.save_png("user://save_lvl2_close.png")
	slice.adjust(1, ground + 1)
	for i in 400:
		await process_frame
	img = root.get_viewport().get_texture().get_image()
	img.save_png("user://save_lvl1_close.png")
	# Ground truth: count solid cells vs quads at each level's tile.
	var sim: Object = main.world.sim
	for lvl in [slice.top_layer, slice.top_layer + 1]:
		var t := Vector2i(anchor.x >> 4, anchor.z >> 4)
		var solid := 0
		for dz in 16:
			for dx in 16:
				if sim.probe_block(Vector3i(
						t.x * 16 + dx, lvl, t.y * 16 + dz)) != 0:
					solid += 1
		var inst: MeshInstance3D = slice._tiles.get(t)
		var quads := -1
		if inst != null and inst.mesh.get_surface_count() > 0:
			var arr: Array = inst.mesh.surface_get_arrays(0)
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			quads = idx.size() / 6 if idx.size() > 0 \
				else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 6
		print("lvl %d tile %s: solid=%d quads=%d" % [lvl, t, solid, quads])
	quit(0)
