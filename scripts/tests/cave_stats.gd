extends SceneTree

## Cavern lattice stats: how porous the redesign actually is. Counts
## cave voxels in a subsurface slab through the GDScript oracle
## (native parity is gen_parity.gd's job), flood-fills the connected
## components, and reports the count and largest volumes — the goal is
## fewer, larger caverns rather than the old worm-noise lace.
##
##     godot --headless --path . --script res://scripts/tests/cave_stats.gd

const X0 := -48
const X1 := 48
const Y0 := -40
const Y1 := 24
const Z0 := -48
const Z1 := 48


func _initialize() -> void:
	var gen := WorldGenerator.new()
	gen._native = null # pure GDScript oracle
	gen.world_seed = 1337
	var nx := X1 - X0
	var ny := Y1 - Y0
	var nz := Z1 - Z0
	var cave := PackedByteArray()
	cave.resize(nx * ny * nz)
	var hits := 0
	for z in range(Z0, Z1):
		for y in range(Y0, Y1):
			for x in range(X0, X1):
				if gen._is_cave(x, y, z):
					cave[(z - Z0) * nx * ny + (y - Y0) * nx + (x - X0)] = 1
					hits += 1
	var total := nx * ny * nz
	print(
		"cave voxels: %d / %d (%.2f%% of slab)"
		% [hits, total, hits * 100.0 / total]
	)

	# Flood fill connected components (6-neighbourhood).
	var seen := PackedByteArray()
	seen.resize(cave.size())
	var components: Array[int] = []
	var queue: Array[int] = []
	for i in cave.size():
		if cave[i] == 0 or seen[i] != 0:
			continue
		var size := 0
		queue.clear()
		queue.append(i)
		seen[i] = 1
		while not queue.is_empty():
			var c: int = queue.pop_back()
			size += 1
			var cx := c % nx
			var cy := (c / nx) % ny
			var cz := c / (nx * ny)
			for d: Vector3i in [
				Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
				Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
			]:
				var fx := cx + d.x
				var fy := cy + d.y
				var fz := cz + d.z
				if fx < 0 or fx >= nx or fy < 0 or fy >= ny or fz < 0 or fz >= nz:
					continue
				var j := fz * nx * ny + fy * nx + fx
				if cave[j] != 0 and seen[j] == 0:
					seen[j] = 1
					queue.append(j)
		components.append(size)
	components.sort()
	components.reverse()
	print("components: %d" % components.size())
	for i in mini(10, components.size()):
		print("  #%d: %d voxels" % [i + 1, components[i]])
	if components.size() > 1:
		var bulk := 0
		for s in components:
			if s >= 100:
				bulk += s
		print(
			"voxels in components >=100: %d / %d (%.1f%%)"
			% [bulk, hits, bulk * 100.0 / hits]
		)
	quit(0)
