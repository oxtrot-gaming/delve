extends SceneTree

## Minimal VoxelTools churn repro — a bare VoxelTerrain + viewer + the
## game's generator/mesher, no colony, no decorations, no water. If
## static memory ramps while the viewer sweeps the site (revisits
## included), the leak lives in the module, not our code.
##
##     godot --headless --path . --script res://scripts/tests/vt_leak.gd

func _initialize() -> void:
	_run()

var _terrain: VoxelTerrain

func _sample(tag: String) -> void:
	var st := ""
	if _terrain != null:
		var d: Dictionary = _terrain.get_statistics()
		st = " dl=%s dm=%s upd=%s" % [
			d.get("dropped_block_loads", "?"),
			d.get("dropped_block_meshs", "?"),
			d.get("updated_blocks", "?")]
	print("%-22s static=%.0fMB objs=%d nodes=%d%s" % [
		tag,
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		Performance.get_monitor(Performance.OBJECT_COUNT),
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		st])

func _run() -> void:
	# Real generator pipeline — regional grid + site field installed —
	# so the terrain matches what the game streams.
	var globe := WorldGlobe.new(158916680)
	await globe.generate()
	var tile := globe.nearest_land_tile(WorldGlobe.default_settle_dir())
	var meso := MesoMap.generate(globe, tile)
	var vg: Dictionary = meso.voxel_grid(Vector2i.ZERO, 32)
	var gen := WorldGenerator.new()
	gen.world_seed = 158916680
	gen.install_regional_grid(vg["grid"], vg["origin"], vg["step"], vg["size"])
	var field := await SiteField.generate(meso, gen, Vector2i.ZERO)
	gen.install_site_field(field)

	_terrain = VoxelTerrain.new()
	var terrain := _terrain
	terrain.max_view_distance = 160
	# The game disables collision generation when the sim runs, but the
	# viewer's post-boot restore still requests colliders — mirror that
	# mismatch unless told otherwise.
	terrain.generate_collisions = OS.get_environment("VT_COLLIDE") == "1"
	var mesher := VoxelMesherBlocky.new()
	mesher.library = BlockRegistry.build_library()
	terrain.mesher = mesher
	terrain.generator = gen
	root.add_child(terrain)

	var viewer := VoxelViewer.new()
	viewer.view_distance = 160
	viewer.view_distance_vertical_ratio = 0.5
	viewer.requires_collisions = true
	viewer.requires_data_block_notifications = true
	root.add_child(viewer)
	viewer.global_position = Vector3(0, 48, 0)

	for i in 90:
		await process_frame
	_sample("settled")

	var tool: VoxelTool = terrain.get_voxel_tool()
	var write := OS.get_environment("VT_WRITE") == "1"
	# Oscillate the viewer's height while panning — mimics the overseer
	# riding the terrain, so the streamed band sweeps vertically and
	# touches many more unique blocks per pass.
	var ride := OS.get_environment("VT_RIDE") == "1"
	var pass_i := 0
	for rep in 4:
		for gz in range(-64, 65, 32):
			for gx in range(-64, 65, 32):
				var vy := 48.0
				if ride:
					vy = 20.0 + 60.0 * (
						sin(gx * 0.11) * 0.5 + sin(gz * 0.07) * 0.5)
				viewer.global_position = Vector3(gx, vy, gz)
				for i in 3:
					await process_frame
				if write:
					# Mirror _replay_chunk_edits: a write marks the
					# block modified — with no stream, does it stay
					# resident forever?
					tool.channel = VoxelBuffer.CHANNEL_TYPE
					tool.mode = VoxelTool.MODE_SET
					tool.value = tool.get_voxel(
						Vector3i(gx, 40, gz))
					tool.do_point(Vector3i(gx, 40, gz))
		pass_i += 1
		_sample("sweep %d" % pass_i)
	# Hammer reads through never-streamed space — if get_voxel
	# generates data blocks on demand, they never unload.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	for i in 20000:
		tool.get_voxel(Vector3i(
			rng.randi_range(-2000, 2000),
			rng.randi_range(-32, 64),
			rng.randi_range(-2000, 2000)))
		if i % 5000 == 4999:
			_sample("reads %d" % (i + 1))
	# And rays through unloaded space.
	for i in 5000:
		var from := Vector3(
			rng.randf_range(-2000, 2000), 60, rng.randf_range(-2000, 2000))
		tool.raycast(from, Vector3(0, -1, 0), 100.0)
		if i % 1000 == 999:
			_sample("rays %d" % (i + 1))
	# is_area_editable — the overseer's per-cell loaded check.
	for i in 20000:
		tool.is_area_editable(AABB(Vector3(
			rng.randi_range(-2000, 2000),
			rng.randi_range(-32, 64),
			rng.randi_range(-2000, 2000)), Vector3.ONE))
		if i % 5000 == 4999:
			_sample("editable %d" % (i + 1))
	print("mesh=%s" % (mesher != null))
	quit(0)
