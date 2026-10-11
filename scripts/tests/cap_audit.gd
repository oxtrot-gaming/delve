extends SceneTree

## Slice-cap coverage audit: boots the real world, opens the slice view,
## waits for cap tiles around the focus, then checks every cell of every
## built tile — does a solid-at-top_layer cell actually carry a quad in
## the cap mesh, and does probe_block agree with the real block data?
##
##     godot --headless --path . --script res://scripts/tests/cap_audit.gd

var _main: Node3D
var _slice: SliceView
var _overseer: Node3D


func _initialize() -> void:
	_run()


func _run() -> void:
	if OS.get_environment("CAP_SHOT") == "1":
		_shot()
		return
	Main.pending_world = {
		&"seed": 158916680, &"ocean_pct": 60, &"temp_bias_c": 0.0,
		&"moist_bias": 0.0, &"axial_tilt_deg": 23.0, &"world_tile": 99285,
		&"package": &"vanilla", &"scenario": &"lost_tribe",
	}
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)
	while not _main._units_spawned:
		await process_frame
	_slice = _main.slice_view
	_overseer = _main.get_node("Overseer")
	var sim: Object = _main.world.sim
	var g: float = _overseer._terrain_height()

	# Park over the user's marked cell and cut at their level —
	# "cut above y29" means top_layer=28 (plane 29).
	_overseer.global_position = Vector3(-78, 60, -73)
	for i in 30:
		await process_frame
	_slice.adjust(-1, 29)  # opens at top_layer = 28, plane = 29

	# Dump the column around the marked cell — what's where vertically.
	var sim0: Object = _main.world.sim
	for x in range(-82, -74):
		for z in range(-77, -69):
			var col := "(%d,%d):" % [x, z]
			for y in [27, 28, 29, 30]:
				col += " y%d=%d" % [y, sim0.probe_block(
					Vector3i(x, y, z))]
			print("   ", col)
		break  # one column row first
	print("slice level: top_layer=%d  plane=%.2f" % [
		_slice.top_layer, _slice.plane()])

	# Let the cap fill in around the focus — measure drain rate and
	# per-frame cost of SliceView._process while it works.
	var worst_frame_us := 0
	var frames := 120
	for i in frames:
		var t := Time.get_ticks_usec()
		await process_frame
		worst_frame_us = maxi(
			worst_frame_us, Time.get_ticks_usec() - t)
	print(
		"warm: %d frames, worst frame %.1f ms" % [
			frames, worst_frame_us / 1000.0])

	# Direct cost of a tile rebuild over materialized vs gen-only ground.
	var t0 := Time.get_ticks_usec()
	_slice._rebuild_tile(Vector2i(0, 0))
	print("rebuild near tile: %.2f ms"
		% ((Time.get_ticks_usec() - t0) / 1000.0))
	t0 = Time.get_ticks_usec()
	_slice._rebuild_tile(Vector2i(40, 40))
	print("rebuild far tile: %.2f ms"
		% ((Time.get_ticks_usec() - t0) / 1000.0))

	# Water-view tile rebuild cost — the pending drain in _process has
	# no deadline; if a tile costs tens of ms that's the frame spike.
	var wv: Node = _main.water_view
	t0 = Time.get_ticks_usec()
	wv._rebuild_tile(Vector2i(0, 0))
	var wet_ms := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	wv._rebuild_tile(Vector2i(30, 5))
	var dry_ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("water tile rebuild: wet=%.2f ms dry=%.2f ms pending=%d"
		% [wet_ms, dry_ms, wv._pending.size()])

	# Frame-cost split over a settled window: time each periodic piece.
	var colony: Node = _main.colony
	var sim_ms := 0.0
	var col_ms := 0.0
	var wv_ms := 0.0
	var sl_ms := 0.0
	var n := 240
	for i in n:
		t0 = Time.get_ticks_usec()
		colony._physics_process(1.0 / 60.0)
		col_ms += (Time.get_ticks_usec() - t0) / 1000.0
		t0 = Time.get_ticks_usec()
		wv._process(0.016)
		wv_ms += (Time.get_ticks_usec() - t0) / 1000.0
		t0 = Time.get_ticks_usec()
		_slice._process(0.016)
		sl_ms += (Time.get_ticks_usec() - t0) / 1000.0
		await process_frame
	print(
		"avg per frame over %d: colony_phys=%.1f water_view=%.1f slice=%.1f ms"
		% [n, col_ms / n, wv_ms / n, sl_ms / n])
	print(
		"after warm: tiles=%d pending=%d built=%d"
		% [_slice._tiles.size(), _slice._pending.size(), _slice._built.size()]
	)

	# Per-tile audit: quads in the mesh vs cells probe_block calls solid,
	# and probe vs the real (streamed) block data.
	var total_solid := 0
	var total_quads := 0
	var miss_tiles: Array[Vector2i] = []
	var disagree := 0
	var probe_only := 0
	var data_only := 0
	for tile: Vector2i in _slice._tiles:
		var inst: MeshInstance3D = _slice._tiles[tile]
		var quads := 0
		if inst.mesh.get_surface_count() > 0:
			var arrays: Array = inst.mesh.surface_get_arrays(0)
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			quads = idx.size() / 6 if idx.size() > 0 else \
				(arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 6
		var solid := 0
		var ox: int = tile.x * SliceView.TILE
		var oz: int = tile.y * SliceView.TILE
		for dz in SliceView.TILE:
			for dx in SliceView.TILE:
				var pos := Vector3i(
					ox + dx, _slice.top_layer, oz + dz)
				var probe := int(sim.probe_block(pos)) != 0
				var data := -1
				if _main.world.is_editable(pos):
					data = _main.world.get_block(pos)
				if probe:
					solid += 1
					if data == 0:
						probe_only += 1  # probe says solid, data says air
				elif data > 0:
					data_only += 1      # data solid, probe says air
				if data >= 0 and ((data != 0) != probe):
					disagree += 1
		total_solid += solid
		total_quads += quads
		if solid > 0 and quads == 0:
			miss_tiles.append(tile)
		elif quads != solid:
			print(
				"  tile %s: solid=%d quads=%d"
				% [tile, solid, quads])
	print(
		("AUDIT solid=%d quads=%d miss_tiles=%d disagree=%d "
		+ "(probe_solid_data_air=%d data_solid_probe_air=%d)")
		% [total_solid, total_quads, miss_tiles.size(), disagree,
				probe_only, data_only])
	for t in miss_tiles:
		print("  MISSING tile %s" % t)

	# Verify quad world heights — the cap should sit at plane()-CAP_EPS.
	for tile: Vector2i in _slice._tiles:
		var inst: MeshInstance3D = _slice._tiles[tile]
		if inst.mesh.get_surface_count() == 0:
			continue
		var arrays: Array = inst.mesh.surface_get_arrays(0)
		var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var wy: float = vs[0].y + inst.global_position.y
		print("  tile %s quad world_y=%.3f (expect %.2f)" % [
			tile, wy, _slice.plane() - SliceView.CAP_EPS])
		break

	# Find a concrete example: a solid cell at top_layer with a solid
	# voxel above it — the mesher-culled-top case the user screenshotted.
	var found := 0
	var b: Rect2i = _main.site.bounds
	for z in range(b.position.y, b.end.y):
		for x in range(b.position.x, b.end.x):
			var p := Vector3i(x, _slice.top_layer, z)
			if sim.probe_block(p) != 0 \
					and sim.probe_block(p + Vector3i(0, 1, 0)) != 0:
				var tile := Vector2i(x >> 4, z >> 4)
				print(
					("  capped-solid-buried example %s "
					+ "(tile %s built=%s has_mesh=%s)")
					% [p, tile, _slice._built.has(tile),
							_slice._tiles.has(tile)])
				found += 1
				if found >= 8:
					break
		if found >= 8:
			break
	quit(0)


## Windowed capture: boot, slice, park the camera over the site, save a
## viewport PNG — shows what the player actually sees, caps and all.
func _shot() -> void:
	Main.pending_world = {
		&"seed": 158916680, &"ocean_pct": 60, &"temp_bias_c": 0.0,
		&"moist_bias": 0.0, &"axial_tilt_deg": 23.0, &"world_tile": 99285,
		&"package": &"vanilla", &"scenario": &"lost_tribe",
	}
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)
	while not _main._units_spawned:
		await process_frame
	_slice = _main.slice_view
	_overseer = _main.get_node("Overseer")
	# Frame the user's cliff through the overseer's own boom — focus on
	# the marked cell, camera SE looking NW at a moderate pitch.
	# Freeze the camera driver, then pose the camera ourselves so test
	# geometry lands exactly in frame.
	_overseer.set_process(false)
	_overseer.set_physics_process(false)
	var cam: Camera3D = _overseer.find_child("Camera3D")
	cam.global_position = Vector3(-50, 45, -50)
	cam.look_at(Vector3(-78, 25, -73))
	for i in 30:
		await process_frame
	# top_layer = 29 → plane = 30, matching "cut above y29" readout if
	# the HUD prints top_layer+... either way one layer under the sand.
	_slice.adjust(-1, 30)
	# Let caps build and the first rendered frames present.
	for i in 400:
		await process_frame
		if i % 100 == 99:
			print("frame %d: tiles=%d pending=%d" % [
				i + 1, _slice._tiles.size(), _slice._pending.size()])
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png("user://cap_shot.png")
	# Second level down — the reported failure case.
	_slice.adjust(-1, 30)
	for i in 400:
		await process_frame
		if i % 100 == 99:
			print("lvl2 frame %d: tiles=%d pending=%d top=%d" % [
				i + 1, _slice._tiles.size(), _slice._pending.size(),
				_slice.top_layer])
	img = root.get_viewport().get_texture().get_image()
	img.save_png("user://cap_shot_lvl2.png")
	# Ground truth for the marked cell: rebuild its tile by hand and
	# confirm a quad exists at (-78,29,-73).
	var stile := Vector2i(-5, -5)
	_slice._rebuild_tile(stile)
	var sinst: MeshInstance3D = _slice._tiles[stile]
	var sarr: Array = sinst.mesh.surface_get_arrays(0)
	var sverts: PackedVector3Array = sarr[Mesh.ARRAY_VERTEX]
	var want := Vector3(2, _slice.plane() - 0.1, 7)
	var hit := false
	for v in sverts:
		if v == want:
			hit = true
	print("marked-cell cap vert present: ", hit, " tile=", stile, " verts=", sverts.size())
	# Hide all caps → differential shot.
	for tile: Vector2i in _slice._tiles:
		_slice._tiles[tile].visible = false
	for i in 10:
		await process_frame
	img = root.get_viewport().get_texture().get_image()
	img.save_png("user://cap_shot_nocap.png")
	print("saved cap_shot.png + cap_shot_nocap.png")
	quit(0)
