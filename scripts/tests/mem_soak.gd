extends SceneTree

## Memory soak: boots the real world, activates the slice view, sweeps
## the camera focus across the site (forcing block stream + cap churn)
## while ticking the sim — samples memory each pass so a runaway path
## shows as a ramp instead of a mystery 40GB OOM.
##
##     godot --headless --path . --script res://scripts/tests/mem_soak.gd

var _main: Node3D
var _sim: RefCounted
var _slice: SliceView
var _overseer: Node3D
var _objects: Array = []

var _classes := {}

func _collect(n: Node) -> void:
	var cls := n.get_class()
	if n.get_script() != null:
		cls += ":" + n.get_script().resource_path.get_file()
		_objects.append(n)
		# Object-typed members not in the tree (region, astar, field...)
		for p in n.get_property_list():
			if not (p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
				continue
			var v: Variant = n.get(p.name)
			if v is Object and v.get_script() != null and not (v is Node):
				_objects.append(v)
	_classes[cls] = _classes.get(cls, 0) + 1
	for c in n.get_children():
		_collect(c)

func _dump_class_delta() -> void:
	var now := {}
	_collect_classes(root, now)
	var deltas := []
	for cls in now:
		var d: int = now[cls] - _classes.get(cls, 0)
		if d != 0:
			deltas.append("%s:%+d" % [cls, d])
	print("node deltas: ", " ".join(deltas))
	_classes = now

func _collect_classes(n: Node, into: Dictionary) -> void:
	var cls := n.get_class()
	if n.get_script() != null:
		cls += ":" + n.get_script().resource_path.get_file()
	into[cls] = into.get(cls, 0) + 1
	for c in n.get_children():
		_collect_classes(c, into)

func _initialize() -> void:
	_run()

func _sample(tag: String) -> void:
	var monitors := [
		Performance.MEMORY_STATIC,
		Performance.OBJECT_COUNT, Performance.OBJECT_RESOURCE_COUNT,
		Performance.OBJECT_NODE_COUNT, Performance.OBJECT_ORPHAN_NODE_COUNT,
		Performance.RENDER_TOTAL_OBJECTS_IN_FRAME,
		Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME,
		Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME,
		Performance.RENDER_VIDEO_MEM_USED,
		Performance.PHYSICS_3D_ACTIVE_OBJECTS,
		Performance.PHYSICS_3D_COLLISION_PAIRS,
		Performance.PHYSICS_3D_ISLAND_COUNT,
		Performance.NAVIGATION_ACTIVE_MAPS,
		Performance.NAVIGATION_REGION_COUNT,
		Performance.NAVIGATION_AGENT_COUNT,
		Performance.NAVIGATION_LINK_COUNT,
		Performance.NAVIGATION_POLYGON_COUNT,
		Performance.NAVIGATION_EDGE_COUNT,
		Performance.NAVIGATION_EDGE_MERGE_COUNT,
		Performance.NAVIGATION_EDGE_CONNECTION_COUNT,
		Performance.NAVIGATION_EDGE_FREE_COUNT,
	]
	var names := [
		"static", "objs", "res", "nodes", "orphans",
		"r_objs", "r_prim", "r_calls", "r_vmem",
		"phys_obj", "phys_pairs", "phys_islands",
		"nav_maps", "nav_regions", "nav_agents", "nav_links",
		"nav_polys", "nav_edges", "nav_emerge", "nav_econn", "nav_efree",
	]
	var nums := ""
	for i in monitors.size():
		var v := Performance.get_monitor(monitors[i])
		if v > 1048576.0:
			nums += "%s=%.0fMB " % [names[i], v / 1048576.0]
		else:
			nums += "%s=%d " % [names[i], int(v)]
	# RSS: MEMORY_STATIC only counts Godot-tracked allocs — extension
	# C++ (std containers, new) and driver buffers don't show in it.
	# get_memory_info().physical is system RAM, so ask the OS directly.
	var out: Array = []
	OS.execute("powershell", [
		"-NoProfile", "-Command",
		"(Get-Process -Id %d).WorkingSet64" % OS.get_process_id(),
	], out)
	if out.size() > 0:
		var ws := float(str(out[0]).strip_edges())
		nums += "rss=%.0fMB " % (ws / 1048576.0)
	print("%-22s %s" % [tag, nums])
	var line := ""
	# Data-block residency: count loaded VoxelData blocks over the site —
	# if blocks never unload this climbs with unique area visited.
	var blocks := 0
	var bsz: int = _main.world.get_data_block_size()
	var bs: Rect2i = _main.site.bounds
	for by in range(-32, 80, bsz):
		for bz in range(bs.position.y, bs.end.y, bsz * 4):
			for bx in range(bs.position.x, bs.end.x, bsz * 4):
				if _main.world.has_data_block(Vector3i(
					bx / bsz, by / bsz, bz / bsz)):
					blocks += 1
	line += "  data_blocks_sampled=%d" % blocks
	if _main.world.has_method(&"get_statistics"):
		var st: Dictionary = _main.world.get_statistics()
		var parts := ""
		for k in st:
			parts += "%s=%s " % [k, st[k]]
		line += "  vt{%s}" % parts
	if _sim != null and _sim.has_method(&"debug_sizes"):
		var ds: Dictionary = _sim.debug_sizes()
		var parts := ""
		for k in ds:
			parts += "%s=%s " % [k, ds[k]]
		line += "\n     sim{%s}" % parts
	# Census every live object's Dictionary/Array script vars — a
	# bookkeeping table growing per stream event reads as a ramp here.
	for o in _objects:
		if not is_instance_valid(o):
			continue
		var parts := ""
		for p in o.get_property_list():
			if not (p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
				continue
			var v: Variant = o.get(p.name)
			if v is Dictionary and (v as Dictionary).size() > 512:
				parts += "%s=%d " % [p.name, (v as Dictionary).size()]
			elif v is Array and (v as Array).size() > 1024:
				parts += "%s[]=%d " % [p.name, (v as Array).size()]
			elif v is PackedByteArray or v is PackedInt32Array \
					or v is PackedInt64Array or v is PackedFloat32Array \
					or v is PackedFloat64Array or v is PackedVector2Array \
					or v is PackedVector3Array or v is PackedVector4Array \
					or v is PackedColorArray or v is PackedStringArray:
				var n: int = v.size()
				if n > 4096:
					parts += "%s<>=%d " % [p.name, n]
		if parts != "":
			line += "\n     %s{%s}" % [
				o.get_script().resource_path.get_file(), parts]
	print(line)

func _run() -> void:
	Main.pending_world = {
		&"seed": 158916680, &"ocean_pct": 60, &"temp_bias_c": 0.0,
		&"moist_bias": 0.0, &"axial_tilt_deg": 23.0, &"world_tile": 99285,
		&"package": &"vanilla", &"scenario": &"lost_tribe",
	}
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)
	while not _main._units_spawned:
		await process_frame
	_sim = _main.world.sim
	_slice = _main.slice_view
	_overseer = _main.get_node("Overseer")
	_collect(root)
	_sample("boot")

	# Strip every stream-signal handler — if the leak survives with no
	# game code reacting to loads, it's the engine's own churn.
	var strip := OS.get_environment("SOAK_STRIP")
	if strip == "1":
		# Signals only — the terrain's own process keeps streaming.
		for sig in [&"block_loaded", &"block_unloaded", &"block_edited"]:
			for c in _main.world.get_signal_connection_list(sig):
				_main.world.disconnect(sig, c.callable)
		_sample("handlers stripped")
	elif strip == "nodes":
		# Reduce toward the proven-flat bare repro: keep only the
		# terrain and the viewer-riding overseer (script off), free
		# colony/water/decorations/day-cycle/HUD entirely.
		for sig in [&"block_loaded", &"block_unloaded", &"block_edited"]:
			for c in _main.world.get_signal_connection_list(sig):
				_main.world.disconnect(sig, c.callable)
		for child in _main.get_children():
			if child != _main.world and child != _overseer:
				child.queue_free()
		_overseer.set_process(false)
		_overseer.set_physics_process(false)
		_overseer.set_process_input(false)
		_overseer.set_process_unhandled_input(false)
		_main.set_process(false)
		_main.set_physics_process(false)
		for i in 2:
			await process_frame
		_sample("scene stripped")
	elif strip == "water":
		_main.water_view.queue_free()
		await process_frame
		_sample("water_view freed")
	elif strip == "process":
		# Nodes stay alive (their dicts persist) but no game script
		# callbacks run — streaming alone vs streaming+callbacks.
		for o in _objects:
			if o is Node and o != _main.world and o != _main.world_viewer:
				var n: Node = o
				n.set_process(false)
				n.set_physics_process(false)
				n.set_process_input(false)
				n.set_process_unhandled_input(false)
		_sample("processes stopped")
	elif strip.begins_with("on:"):
		# Disable process callbacks on everything EXCEPT the named
		# scripts — isolates a single callback set's contribution.
		# Never touch the world node: set_process(false) suppresses
		# NOTIFICATION_PROCESS for the C++ VoxelTerrain too, which is
		# where streaming detection runs.
		var names := strip.substr(3).split(",")
		var hit := 0
		for o in _objects:
			if not (o is Node) or o.get_script() == null:
				continue
			if o == _main.world:
				continue
			if names.has(o.get_script().resource_path.get_file()):
				continue
			var n: Node = o
			n.set_process(false)
			n.set_physics_process(false)
			n.set_process_input(false)
			n.set_process_unhandled_input(false)
			hit += 1
		_sample("only %s on (%d stopped)" % [names, hit])
	elif strip.begins_with("off:"):
		# Disable process callbacks only on the named scripts —
		# e.g. SOAK_STRIP=off:overseer.gd,colony.gd,unit.gd
		var names := strip.substr(4).split(",")
		var hit := 0
		for o in _objects:
			if not (o is Node) or o.get_script() == null:
				continue
			if names.has(o.get_script().resource_path.get_file()):
				var n: Node = o
				n.set_process(false)
				n.set_physics_process(false)
				n.set_process_input(false)
				n.set_process_unhandled_input(false)
				hit += 1
		_sample("stopped %d of %s" % [hit, names])
	elif OS.get_environment("SOAK_STRIP") == "replay":
		# Just the edit-replay hook — its VoxelTool writes mark loaded
		# blocks modified, which the module retains across unloads.
		_main.world.block_loaded.disconnect(_main.world._replay_chunk_edits)
		_sample("replay stripped")

	var g: float = _overseer._terrain_height()
	var slicing := (
		OS.get_environment("SOAK_SLICE") != "0"
		and is_instance_valid(_slice)
	)
	if slicing:
		# Activate the slice at focus ground — cap tiles stream.
		_slice.adjust(-1, int(g))
		for i in 30:
			await process_frame
		_sample("slice opened")

	# Stationary phase — sim ticks only, no camera motion: separates
	# water/unit churn from streaming churn.
	for i in 60:
		_sim.tick(0.2)
		if i % 20 == 19:
			_sample("stationary %d" % (i + 1))
	# Parked-frames phase — camera still, but frames pump so per-frame
	# callbacks (raycasts, terrain rides) run hot. A ramp here means a
	# per-FRAME allocation; flat means growth needs new area.
	for i in 300:
		await process_frame
		if i % 100 == 99:
			_sample("parked %d" % (i + 1))

	var b: Rect2i = _main.site.bounds
	var pass_i := 0
	var ticking := OS.get_environment("SOAK_TICK") != "0"
	# Grid sweep — pan the focus in strides so streaming + cap tiles
	# churn; tick the sim so water/unit systems run too.
	for gz in range(b.position.y, b.end.y, 64):
		for gx in range(b.position.x, b.end.x, 64):
			_overseer.global_position = Vector3(gx, g + 30, gz)
			for i in 4:
				await process_frame
			if ticking:
				_sim.tick(0.2)
		pass_i += 1
		_sample("sweep row %d" % pass_i)
		if slicing:
			_slice.adjust(-1, 0)  # lower the cut each row — rescan
			for i in 6:
				await process_frame
	# Return sweep over visited ground — flat memory here means the
	# climb was streaming footprint; a ramp means a real leak.
	var back := 0
	for gz in range(b.end.y - 32, b.position.y - 1, -64):
		for gx in range(b.end.x - 32, b.position.x - 1, -64):
			_overseer.global_position = Vector3(gx, g + 30, gz)
			for i in 4:
				await process_frame
			if ticking:
				_sim.tick(0.2)
		back += 1
		_sample("return row %d" % back)
	# Drain phase — park the camera and pump frames: if the growth was
	# queued load/mesh work rather than retention, memory falls back.
	for i in 600:
		await process_frame
		if i % 200 == 199:
			_sample("drain %d" % (i + 1))
	_sample("done")
	_dump_class_delta()
	if is_instance_valid(_slice):
		print("cap tiles retained: %d  pending: %d" % [
			_slice._tiles.size(), _slice._pending.size()])
	# Free the scene and pump a few frames before quitting — the known
	# teardown crash lives in VoxelTools' apply-mesh-update teardown;
	# dismantling first sometimes lets the leak report actually print.
	_main.free()
	for i in 30:
		await process_frame
	Node.print_orphan_nodes()
	quit(0)
