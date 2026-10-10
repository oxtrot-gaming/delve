extends SceneTree

## Repro for the playtest screenshot: two 16x16 chunks of missing grass
## plus a structure floating above the terrain. Boots the same world the
## playtest ran (seed/tile from the debug log), lets the embark settle
## storm play out, then scans:
##   1. perched water — wet cells with open air beneath them,
##   2. stale tops — water_level_at reporting a level whose cell is dry,
##   3. floating ruins — STONE_WALL edits/voxels with air below,
##   4. bald grass — oracle-seedable columns with no coverage record.

const DRY := -30000  # SiteField.DRY / WATER_DRY sentinel


func _initialize() -> void:
	_report = FileAccess.open("user://playtest_bug_report.txt", FileAccess.WRITE)
	_out("probe start")
	Main.pending_world = {
		&"seed": 158916680,
		&"ocean_pct": 60,
		&"temp_bias_c": 0.0,
		&"moist_bias": 0.0,
		&"axial_tilt_deg": 23.0,
		&"world_tile": 99285,
		&"package": &"vanilla",
		&"scenario": &"lost_tribe",
	}
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var wait_beats := 0
	var last_beat := Time.get_ticks_msec()
	while not main._units_spawned:
		await process_frame
		wait_beats += 1
		if Time.get_ticks_msec() - last_beat < 10000:
			continue
		last_beat = Time.get_ticks_msec()
		var sy: int = main.world.predicted_surface_height(
			main.colony_site.x, main.colony_site.z)
		var sv := Vector3i(main.colony_site.x, sy, main.colony_site.z)
		var box := AABB(
			Vector3(sv) - Vector3.ONE * 16.0, Vector3.ONE * 32.0)
		_out(
			"waiting: %d frames, booting=%s, meshed=%s"
			% [
				wait_beats, main._booting,
				main.world.is_area_meshed(box),
			]
		)
	_out("=== booted; site bounds %s ===" % main.site.bounds)
	_scan(main, "embark")
	# Fast-forward the settle storm: about a game-minute of water
	# cadence, chunked so the frame loop stays responsive.
	for i in 6:
		for j in 50:
			main.world.sim.tick(0.2)
		await process_frame
		_out("settle %d/6" % [i + 1])
	_scan(main, "settled")
	quit(0)


## Results go to a file too — headless stdout is block-buffered and
## only flushes at quit, which hides progress on a long run.
var _report: FileAccess


func _out(line: String) -> void:
	print(line)
	if _report != null:
		_report.store_line(line)
		_report.flush()


func _scan(main: Node3D, tag: String) -> void:
	var world: VoxelWorld = main.world
	var sim: RefCounted = world.sim
	var gen: WorldGenerator = world.generator_script
	var b: Rect2i = main.site.bounds
	var x0: int = b.position.x
	var z0: int = b.position.y
	var x1: int = b.end.x
	var z1: int = b.end.y

	# --- water scans ---------------------------------------------------
	var perched := 0
	var stale_tops := 0
	var wet_cols := 0
	var perched_examples: Array = []
	var stale_examples: Array = []
	for z in range(z0, z1):
		for x in range(x0, x1):
			var level := int(sim.water_level_at(x, z))
			if level == DRY:
				continue
			wet_cols += 1
			if int(sim.water_volume_at(Vector3i(x, level, z))) == 0:
				stale_tops += 1
				if stale_examples.size() < 8:
					stale_examples.append(
						Vector3i(x, level, z))
				continue
			# Walk the contiguous wet run down from the top; the cell
			# under its bottom must be solid or it hangs in air.
			var y := level
			while int(sim.water_volume_at(Vector3i(x, y, z))) > 0:
				y -= 1
				if y < -64:
					break
			# Support truth from the voxels where editable — the sim
			# mirror can itself be the bug under test.
			var base := Vector3i(x, y, z)
			if world.is_editable(base):
				if world.get_block(base) == BlockRegistry.Block.AIR:
					perched += 1
					if perched_examples.size() < 8:
						perched_examples.append(
							Vector4i(x, y + 1, z, level))
			elif not sim.is_solid(base):
				perched += 1
				if perched_examples.size() < 8:
					perched_examples.append(
						Vector4i(x, y + 1, z, level))
	_out(
		(
			"[%s] water: %d wet cols, %d perched, %d stale tops"
			% [tag, wet_cols, perched, stale_tops]
		)
	)
	for e in perched_examples:
		_out("   perched col (%d,%d) wet from %d, top %d" % [e.x, e.z, e.y, e.w])
	for e in stale_examples:
		_out("   stale top (%d,%d) at y=%d (cell dry)" % [e.x, e.z, e.y])

	# --- ruin walls -----------------------------------------------------
	var walls := 0
	var floating := 0
	var missing := 0
	var float_examples: Array = []
	for v: Vector3i in main.region.edits:
		if int(main.region.edits[v]) != BlockRegistry.Block.STONE_WALL:
			continue
		walls += 1
		if not world.is_editable(v):
			continue
		var cur := world.get_block(v)
		if cur != BlockRegistry.Block.STONE_WALL:
			missing += 1
			continue
		var below := v + Vector3i.DOWN
		if (
			world.is_editable(below)
			and world.get_block(below) == BlockRegistry.Block.AIR
		):
			# Air below in the real voxels — check the ring for any
			# support before calling it floating. Uneditable sides
			# get the benefit of the doubt (their truth isn't in).
			var supported := false
			var certain := true
			for d: Vector3i in [
				Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
				Vector3i(0, 0, 1), Vector3i(0, 0, -1),
			]:
				var side := v + d
				if not world.is_editable(side):
					certain = false
					continue
				if world.get_block(side) != BlockRegistry.Block.AIR:
					supported = true
					break
			if not supported and certain:
				floating += 1
				if float_examples.size() < 12:
					float_examples.append(v)
	_out(
		(
			"[%s] ruins: %d wall edits, %d floating, %d replayed-missing"
			% [tag, walls, floating, missing]
		)
	)
	for e in float_examples:
		var ground := -999
		for y in range(e.y, e.y - 16, -1):
			var gp := Vector3i(e.x, y, e.z)
			if (
				world.is_editable(gp)
				and world.get_block(gp) != BlockRegistry.Block.AIR
			):
				ground = y
				break
		_out(
			"   floating wall %s — nearest solid below at y=%d"
			% [e, ground]
		)

	# --- grass -----------------------------------------------------------
	var want := 0
	var missing_cov := 0
	var tombstoned := 0
	var wet_reject := 0
	var bald_chunks := {}
	var miss_examples: Array = []
	var grass: Grass = main.colony.grass
	for z in range(z0, z1):
		for x in range(x0, x1):
			var col := gen.grass_column(x, z)
			if col.y < 0.0:
				continue
			want += 1
			var cell := Vector3i(x, int(col.x), z)
			if grass.coverage.has(cell):
				if float(grass.coverage[cell]) <= 0.0:
					tombstoned += 1
				continue
			missing_cov += 1
			if not world.is_editable(cell):
				continue  # unstreamed — the seed pass hasn't seen it
			var wl := int(world.water_level_at(x, z))
			if wl > cell.y:
				wet_reject += 1
			var ck := Vector2i(x >> 4, z >> 4)
			bald_chunks[ck] = int(bald_chunks.get(ck, 0)) + 1
			if miss_examples.size() < 12:
				var above := cell + Vector3i.UP
				var why := ""
				if (
					BlockRegistry.fertilizability(world.get_block(cell))
					<= 0.0
				):
					why = "soil"
				elif wl > cell.y:
					why = "water"
				elif sim.is_solid(above):
					why = "covered"
				elif main.colony.building_at(above) != null:
					why = "building"
				elif main.colony.is_packed(above):
					why = "pile"
				else:
					why = "ELIGIBLE??"
				miss_examples.append(
					[
						x, z, cell.y, wl, int(world.get_block(cell)),
						int(world.get_block(above)),
						grass._pending.has(Vector2i(x, z)), why,
					]
				)
	_out(
		(
			"[%s] grass: %d seedable, %d missing, %d tombstoned, "
			+ "%d of the missing now wet"
		) % [tag, want, missing_cov, tombstoned, wet_reject]
	)
	var chunks_sorted := bald_chunks.keys()
	chunks_sorted.sort_custom(
		func(a, b): return bald_chunks[a] > bald_chunks[b]
	)
	for ck in chunks_sorted.slice(0, 10):
		_out("   bald chunk %s: %d missing columns" % [ck, bald_chunks[ck]])
	for e in miss_examples:
		_out(
			(
				"   miss (%d,%d): cell y=%d, lv=%d, voxel=%d, "
				+ "above=%d, pending=%s, why=%s"
			) % [e[0], e[1], e[2], e[3], e[4], e[5], e[6], e[7]]
		)
	# Column-by-column mirror vs voxel dump at a few misses — prefer the
	# divergent ones (voxel air, mirror solid) over plain tree cover.
	var dump_cols: Array = []
	for e in miss_examples:
		if int(e[5]) == 0 and dump_cols.size() < 4:
			dump_cols.append(e)
	for e in dump_cols:
		var x: int = e[0]
		var z: int = e[1]
		var base: int = e[2]
		var line := "   col (%d,%d):" % [x, z]
		for y in range(base - 1, base + 7):
			line += (
				" y%d[v=%d,m=%d]"
				% [
					y, world.get_block(Vector3i(x, y, z)),
					int(sim.get_block(Vector3i(x, y, z))),
				]
			)
		_out(line)
