extends SceneTree

## Mirror-audit probe: boots the `wall` save, then walks the cells
## around the reported ruin wall and diffs terrain solidity against
## the sim's answer. A visible wall the pathfinder can't see means
## store-persisted voxels never reached the mirror.

func _initialize() -> void:
	_run()


func _run() -> void:
	Main.pending_load = "user://saves/treenext"
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	var frames := 0
	while not main._units_spawned and frames < 7200:
		frames += 1
		await process_frame
	print("boot done: spawned=%s frames=%d" % [main._units_spawned, frames])
	for i in 60:
		await process_frame
	var world = main.world
	var sim = world.sim
	var target := Vector3i(-34, 32, 36)
	print(
		"target %s: terrain=%d sim_solid=%s sim_block=%d" % [
			target,
			world.get_block(target),
			sim.is_solid(target),
			sim.get_block(target),
		]
	)
	var mismatches := 0
	var checked := 0
	for dx in range(-8, 9):
		for dy in range(-4, 5):
			for dz in range(-8, 9):
				var v := target + Vector3i(dx, dy, dz)
				var terr_solid := BlockRegistry.is_solid(
					world.get_block(v)
				)
				checked += 1
				if terr_solid != sim.is_solid(v):
					mismatches += 1
					print(
						"  mismatch %s: terrain=%d sim_block=%d"
						% [v, world.get_block(v), sim.get_block(v)]
					)
	print("checked=%d mismatches=%d" % [checked, mismatches])
	quit(0)
