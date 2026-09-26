extends SceneTree

## Headless benchmark for the costs that drive streaming stutter and sim
## throughput — the baseline every performance change is evaluated against.
##
##     godot --headless --path . --script res://scripts/tests/bench.gd
##
## Prints `BENCH|name|value|unit` lines so runs can be diffed.

const TIMEOUT_SECONDS := 300.0
## Side of the column window swept by the generator bench (3 → 3x3 blocks).
const GEN_BLOCKS_XZ := 3
## Number of 16-voxel block layers generated per column.
const GEN_BLOCKS_Y := 4
## Reps for cheap calls (nearest_* scans, claim_job) to get a stable average.
const SCAN_REPS := 50

var _failures: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	_run()


func _run() -> void:
	print("== delve bench ==")
	print("cpu: ", OS.get_processor_name())
	_bench_generator()
	await _bench_scene()
	print("== done ==")
	quit(0)


func _report(name: String, value: float, unit: String) -> void:
	print("BENCH|%s|%.3f|%s" % [name, value, unit])


func _wait_until(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return false


## Per-voxel cost of the terrain generator — the code that runs on the
## streaming worker threads while the camera flies around. Reports the
## script generator and, when the delve_native extension is loaded, the
## native DelveGenerator with identical sampling so they can be compared.
func _bench_generator() -> void:
	var script_gen := WorldGenerator.new()
	# Force the interpreted path: WorldGenerator delegates _generate_block to
	# the native impl when the extension is loaded, which would make the
	# "script" row measure native code instead of the baseline.
	script_gen._native = null
	var surface := script_gen.surface_height(0, 0)
	var buffer := VoxelBuffer.new()
	buffer.create(16, 16, 16)

	# A window of 16^3 blocks centred on the surface band — the expensive
	# region (sky blocks early-out; deep bedrock skips the surface layers).
	var base_y := floori(float(surface) / 16.0) * 16 - 16
	var origins: Array[Vector3i] = []
	for bx in range(-GEN_BLOCKS_XZ / 2, GEN_BLOCKS_XZ / 2 + 1):
		for bz in range(-GEN_BLOCKS_XZ / 2, GEN_BLOCKS_XZ / 2 + 1):
			for by in range(GEN_BLOCKS_Y):
				origins.append(Vector3i(bx * 16, base_y + by * 16, bz * 16))

	_report("gen_blocks", origins.size(), "count")
	_bench_one_generator("script", script_gen, buffer, origins)
	if ClassDB.class_exists(&"DelveGenerator"):
		var native_gen = ClassDB.instantiate(&"DelveGenerator")
		native_gen.set("world_seed", script_gen.world_seed)
		_bench_one_generator("native", native_gen, buffer, origins)


func _bench_one_generator(label: String, generator: Object, buffer: VoxelBuffer, origins: Array[Vector3i]) -> void:
	# The native class's _generate_block is an engine-dispatched virtual;
	# generate_block_test is its script-callable equivalent.
	var method := "generate_block_test" if generator.has_method(&"generate_block_test") else "_generate_block"
	var t0 := Time.get_ticks_usec()
	for origin in origins:
		generator.call(method, buffer, origin, 0)
	var elapsed := float(Time.get_ticks_usec() - t0) / 1000.0
	var voxels := origins.size() * 16 * 16 * 16
	_report(label + "_gen_ms_per_block", elapsed / origins.size(), "ms")
	_report(label + "_gen_us_per_voxel", elapsed * 1000.0 / voxels, "us")
	_report(label + "_gen_blocks_per_sec", origins.size() / maxf(elapsed / 1000.0, 0.001), "rate")

	t0 = Time.get_ticks_usec()
	for i in 8:
		generator.call(method, buffer, Vector3i(i * 16, 512, 0), 0)
	elapsed = float(Time.get_ticks_usec() - t0) / 1000.0
	_report(label + "_gen_sky_ms_per_block", elapsed / 8.0, "ms")


## Whole-scene numbers: how long until the world is playable, then the
## per-operation costs inside it.
func _bench_scene() -> void:
	var t0 := Time.get_ticks_usec()
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var world: VoxelWorld = main.get_node("VoxelWorld")
	var colony: Colony = main.get_node("Colony")

	var spawned := await _wait_until(func() -> bool: return colony.units.size() > 0)
	_report(
		"stream_time_to_playable",
		float(Time.get_ticks_usec() - t0) / 1000.0 if spawned else -1.0,
		"ms"
	)
	if not spawned:
		print("  scene never became playable — skipping scene benches")
		return
	# Growth on a timer would change the world under the measurements.
	colony.forest.set_process(false)

	_bench_forest_scan(colony)
	_bench_drops(colony, world)
	_bench_pathing(colony, world)
	_bench_scans(colony, world)
	await _bench_unit_ticks(colony, world)
	_report("nodes_total", float(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), "count")
	_report("pile_nodes", float(colony.item_piles.size()), "count")


## Main-thread cost of Forest's per-streamed-block scan: the column loop runs
## sapling_species_at (noise) even for columns that fail the sapling hash.
func _bench_forest_scan(colony: Colony) -> void:
	var total := 0.0
	var worst := 0.0
	for origin in [Vector3i(0, 2, 0), Vector3i(-1, 2, 0), Vector3i(1, 2, -1)]:
		var t := Time.get_ticks_usec()
		colony.forest._on_block_loaded(origin)
		var ms := float(Time.get_ticks_usec() - t) / 1000.0
		total += ms
		worst = maxf(worst, ms)
	_report("forest_scan_avg_ms", total / 3.0, "ms")
	_report("forest_scan_worst_ms", worst, "ms")


## Mined-block drops: 40-item spills, pile creation, per-item mesh rebuilds.
func _bench_drops(colony: Colony, world: VoxelWorld) -> void:
	var spots := _open_air_spots(world, 12)
	if spots.is_empty():
		return
	var total := 0.0
	var worst := 0.0
	for pos in spots:
		var t := Time.get_ticks_usec()
		colony.drop_block(BlockRegistry.Block.STONE, pos)
		var ms := float(Time.get_ticks_usec() - t) / 1000.0
		total += ms
		worst = maxf(worst, ms)
	_report("drop_avg_ms", total / spots.size(), "ms")
	_report("drop_worst_ms", worst, "ms")


## Path planning: find_path over the voxel astar, and the work-spot scan
## every repath performs per candidate.
func _bench_pathing(colony: Colony, world: VoxelWorld) -> void:
	var unit: Unit = colony.units[0]
	var start := unit._standing_voxel()
	var targets: Array[Vector3i] = []
	for i in 8:
		var angle := TAU * float(i) / 8.0
		var x := start.x + int(cos(angle) * 20.0)
		var z := start.z + int(sin(angle) * 20.0)
		targets.append(Vector3i(x, world.ground_height(x, z) + 1, z))

	var total := 0.0
	var worst := 0.0
	for target in targets:
		var t := Time.get_ticks_usec()
		world.find_path(start, target)
		var ms := float(Time.get_ticks_usec() - t) / 1000.0
		total += ms
		worst = maxf(worst, ms)
	_report("find_path_avg_ms", total / targets.size(), "ms")
	_report("find_path_worst_ms", worst, "ms")

	# Second pass over the same targets: the native mirror's lazy chunk
	# materialization is a one-time cost, so warm queries are the steady
	# state that unit repaths actually run at.
	total = 0.0
	worst = 0.0
	for target in targets:
		var t := Time.get_ticks_usec()
		world.find_path(start, target)
		var ms := float(Time.get_ticks_usec() - t) / 1000.0
		total += ms
		worst = maxf(worst, ms)
	_report("find_path_warm_avg_ms", total / targets.size(), "ms")
	_report("find_path_warm_worst_ms", worst, "ms")

	# _work_spots against a solid floor voxel — the reach+march scan.
	var t := Time.get_ticks_usec()
	for r in 10:
		unit._work_spots(start + Vector3i.DOWN)
	_report("work_spots_avg_ms", float(Time.get_ticks_usec() - t) / 1000.0 / 10.0, "ms")


## Colony-scale stress: extra units + a field of jobs, then per-frame cost
## with the colony live vs. with unit ticks frozen. The difference is the
## per-unit decision cost — what a native sim.tick batch would replace —
## measured at a scale closer to a real colony than the 3-unit start.
func _bench_unit_ticks(colony: Colony, world: VoxelWorld) -> void:
	var extra_units := 47
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--units="):
			extra_units = int(arg.trim_prefix("--units=")) - colony.units.size()
	const STRESS_JOBS := 40
	const WARM_SECONDS := 2.5
	const MEASURE_FRAMES := 60

	var origin: Vector3i = colony.units[0]._standing_voxel()
	for i in extra_units:
		var angle := TAU * float(i) / maxi(extra_units, 1)
		# Spread extra spawns over two rings so 200+ units don't pile up.
		var ring := 14 + 14 * (i / maxi(extra_units / 2, 1))
		colony.spawn_unit(
			origin + Vector3i(int(cos(angle) * ring), 0, int(sin(angle) * ring))
		)
	_report("stress_units", colony.units.size(), "count")

	var jobs := 0
	for pos in _open_air_spots(world, STRESS_JOBS, 2):
		colony._deposit_item(
			DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 400_000), pos
		)
		for voxel in colony.item_piles:
			if colony.designate_clear(voxel) != null:
				jobs += 1
				break
	_report("stress_jobs", jobs, "count")

	# Warm up: units claim jobs, start moving, piles settle.
	var until := Time.get_ticks_msec() + int(WARM_SECONDS * 1000)
	while Time.get_ticks_msec() < until:
		await physics_frame

	# Real physics-step cost while units are working, via the engine's own
	# monitor — frame deltas alone would just show the 60Hz tick cadence.
	var busy := 0.0
	for f in MEASURE_FRAMES:
		await physics_frame
		busy += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_report("tick_busy_physics_ms", busy / MEASURE_FRAMES, "ms")

	# Quiet physics step: same bodies, no unit ticks — splits engine
	# physics (broadphase, resting contacts) from script-driven motion.
	for u in colony.units:
		u.set_physics_process(false)
	var quiet := 0.0
	for f in MEASURE_FRAMES:
		await physics_frame
		quiet += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_report("tick_quiet_physics_ms", quiet / MEASURE_FRAMES, "ms")

	# Manual tick: with engine ticking paused, driving _physics_process by
	# hand isolates the per-unit decision+move script cost — the sum a
	# native sim.tick batch would replace.
	var step := 1.0 / 60.0
	var manual := 0.0
	var sim_ms := 0.0
	var forest_ms := 0.0
	for f in MEASURE_FRAMES:
		var t := Time.get_ticks_usec()
		for u in colony.units:
			u._physics_process(step)
		manual += float(Time.get_ticks_usec() - t) / 1000.0
		t = Time.get_ticks_usec()
		colony._physics_process(step)
		sim_ms += float(Time.get_ticks_usec() - t) / 1000.0
		t = Time.get_ticks_usec()
		colony.forest._process(step)
		forest_ms += float(Time.get_ticks_usec() - t) / 1000.0
	_report("unit_tick_all_us", manual * 1000.0 / MEASURE_FRAMES, "us")
	_report("unit_tick_us", manual * 1000.0 / MEASURE_FRAMES / colony.units.size(), "us")
	_report("sim_tick_us", sim_ms * 1000.0 / MEASURE_FRAMES, "us")
	_report("forest_tick_us", forest_ms * 1000.0 / MEASURE_FRAMES, "us")
	_report("forest_trees", float(colony.forest.trees.size()), "count")
	for u in colony.units:
		u.set_physics_process(true)


## Linear scans that run per idle unit tick: nearest pile, nearest stockpile,
## job claiming. Seeded at colony scale so the growth curve is measurable.
func _bench_scans(colony: Colony, world: VoxelWorld) -> void:
	var unit: Unit = colony.units[0]
	var here := unit._standing_voxel()

	# Seed a realistic pile field — a 10x10m scatter of loose piles.
	var piles := 0
	for pos in _open_air_spots(world, 100, 2):
		colony._deposit_item(
			DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 50_000), pos
		)
		piles += 1
	_report("scan_piles_seeded", piles, "count")

	var t := Time.get_ticks_usec()
	for r in SCAN_REPS:
		colony.nearest_haulable_pile(here, {})
	_report("nearest_pile_us", float(Time.get_ticks_usec() - t) / SCAN_REPS, "us")

	# Stockpile tiles are a plain dictionary — inject directly.
	var sp := 0
	for pos in _open_air_spots(world, 64, 3):
		colony.stockpiles[pos] = true
		sp += 1
	_report("scan_stockpiles_seeded", sp, "count")

	t = Time.get_ticks_usec()
	for r in SCAN_REPS:
		colony.nearest_stockpile_with_room(here, 50_000, {})
	_report("nearest_stockpile_us", float(Time.get_ticks_usec() - t) / SCAN_REPS, "us")

	# Two hundred open jobs spread over the map, claimed-and-released per rep.
	for i in 200:
		var angle := TAU * float(i) / 200.0
		colony.jobs.append(
			ColonyJob.new(
				ColonyJob.Type.MINE,
				here + Vector3i(int(cos(angle) * 40.0), 0, int(sin(angle) * 40.0))
			)
		)
	t = Time.get_ticks_usec()
	for r in SCAN_REPS:
		var claimed := colony.claim_job(unit)
		if claimed != null:
			claimed.state = ColonyJob.State.PENDING
			claimed.assignee = null
	_report("claim_job_us", float(Time.get_ticks_usec() - t) / SCAN_REPS, "us")


## Air voxels standing on solid ground, spread across the loaded map —
## valid drop/pile/stockpile spots.
func _open_air_spots(world: VoxelWorld, count: int, spacing: int = 4) -> Array[Vector3i]:
	var spots: Array[Vector3i] = []
	var radius := count * spacing
	for x in range(-radius, radius, spacing):
		for z in range(-radius, radius, spacing):
			if spots.size() >= count:
				return spots
			var y := world.ground_height(x, z)
			if y <= -32:
				continue
			var pos := Vector3i(x, y + 1, z)
			if not world.is_editable(pos) or world.is_solid(pos):
				continue
			spots.append(pos)
	return spots
