class_name WorldGenerator
extends VoxelGeneratorScript

## Procedural terrain for the colony: a rolling surface of grass and dirt over
## stone, with occasional rock masses that rise at or above the surface, plus
## caves and depth-dependent ore veins.
##
## Runs on Voxel Tools' generation threads, so it must only touch its own data.
## When the delve_native extension is loaded this script is a thin runnable
## shell: [code]_generate_block[/code] forwards to the compiled DelveGenerator
## (voxel-for-voxel identical), because VoxelGeneratorScript.is_runnable()
## requires a Script — an extension object alone can't drive streaming.
## Without the extension the GDScript path below runs; a
## [VoxelGeneratorGraph] resource remains an option if the ruleset changes.

const Blocks := BlockRegistry.Block

@export var world_seed: int = 1337:
	set(value):
		world_seed = value
		_configure_noise()
		if _native != null:
			_native.set("world_seed", value)

## Altitude of the average terrain surface, in voxels.
@export var base_height: int = 32
## Peak-to-trough amplitude of the surface, in voxels.
@export var terrain_amplitude: float = 18.0
## Thickness of the dirt layer under the grass.
@export var soil_depth: int = 4
## Everything below this altitude is solid, so the world has a floor.
@export var bedrock_height: int = -64
## Rock-mass noise threshold: higher makes surface stone rarer.
@export var outcrop_threshold: float = 0.45
## How far a rock mass can rise above the terrain surface, in voxels.
@export var outcrop_protrusion: float = 7.0
## Saplings scatter one per lattice cell of this many columns — the cell's
## slot is jittered by a hash so they don't line up in rows.
@export var tree_cell_size: int = 8

var _height_noise := FastNoiseLite.new()
var _cave_noise := FastNoiseLite.new()
var _ore_noise := FastNoiseLite.new()
var _rock_noise := FastNoiseLite.new()

## Ore type, minimum depth below the surface, rarity threshold (higher is rarer).
## Ordered from rarest to most common: the first match wins.
var _ore_rules: Array[Dictionary] = [
	{&"block": Blocks.GOLD_ORE, &"min_depth": 28, &"threshold": 0.86},
	{&"block": Blocks.IRON_ORE, &"min_depth": 12, &"threshold": 0.74},
	{&"block": Blocks.COAL_ORE, &"min_depth": 4, &"threshold": 0.62},
]

## Compiled twin of this generator, or null when delve_native isn't built.
var _native: VoxelGeneratorScript


func _init() -> void:
	_configure_noise()
	if ClassDB.class_exists(&"DelveGenerator"):
		_native = ClassDB.instantiate(&"DelveGenerator")
		_native.set("world_seed", world_seed)


## True when _generate_block forwards to the compiled generator.
func has_native_delegate() -> bool:
	return _native != null


## The compiled generator behind this shell, or null — DelveSim uses it to
## refill its mirrored chunks with the same terrain rules.
func native_generator() -> Object:
	return _native


func _configure_noise() -> void:
	_height_noise.seed = world_seed
	_height_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_height_noise.frequency = 0.006
	_height_noise.fractal_octaves = 4

	_cave_noise.seed = world_seed + 1
	_cave_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_cave_noise.frequency = 0.035

	_ore_noise.seed = world_seed + 2
	_ore_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_ore_noise.frequency = 0.09

	_rock_noise.seed = world_seed + 3
	_rock_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_rock_noise.frequency = 0.02


func _get_used_channels_mask() -> int:
	return 1 << VoxelBuffer.CHANNEL_TYPE


## Altitude of the grass-and-dirt surface at a world column, ignoring rock.
func _terrain_height(x: int, z: int) -> int:
	return base_height + int(_height_noise.get_noise_2d(float(x), float(z)) * terrain_amplitude)


## Altitude of the top of the rock mass at a world column. Normally it sits
## just under the soil, but outcrop noise can push it at or above the surface.
func _rock_top(x: int, z: int, grass: int) -> int:
	var normal := grass - soil_depth
	var n := _rock_noise.get_noise_2d(float(x), float(z))
	if n <= outcrop_threshold:
		return normal
	var t := (n - outcrop_threshold) / (1.0 - outcrop_threshold)
	return normal + int(round(t * (soil_depth + outcrop_protrusion)))


## Surface altitude (the y of the topmost solid voxel) at a world column.
func surface_height(x: int, z: int) -> int:
	var grass := _terrain_height(x, z)
	return maxi(grass, _rock_top(x, z, grass))


func _generate_block(out_buffer: VoxelBuffer, origin_in_voxels: Vector3i, lod: int) -> void:
	if _native != null:
		_native.generate_block_test(out_buffer, origin_in_voxels, lod)
		return
	if lod != 0:
		return

	var size := out_buffer.get_size()
	var max_surface := base_height + int(ceil(terrain_amplitude)) + int(ceil(outcrop_protrusion))
	if origin_in_voxels.y > max_surface:
		out_buffer.fill(Blocks.AIR, VoxelBuffer.CHANNEL_TYPE)
		return

	for rx in size.x:
		var x := origin_in_voxels.x + rx
		for rz in size.z:
			var z := origin_in_voxels.z + rz
			var grass := _terrain_height(x, z)
			var rock_top := _rock_top(x, z, grass)
			for ry in size.y:
				var y := origin_in_voxels.y + ry
				var block := _block_at(x, y, z, grass, rock_top)
				if block != Blocks.AIR:
					out_buffer.set_voxel(block, rx, ry, rz, VoxelBuffer.CHANNEL_TYPE)

	out_buffer.compress_uniform_channels()


func _block_at(x: int, y: int, z: int, grass: int, rock_top: int) -> int:
	var top := maxi(grass, rock_top)
	if y > top:
		return Blocks.AIR
	if y <= bedrock_height:
		return Blocks.STONE
	if y > rock_top:
		return Blocks.GRASS if y == grass else Blocks.DIRT

	var depth := top - y
	if depth > 2 and _is_cave(x, y, z):
		return Blocks.AIR

	var ore := _ore_at(x, y, z, grass - y)
	return ore if ore != Blocks.AIR else Blocks.STONE


## The species of sapling a column seeds, or [code]&""[/code] — one
## jittered slot per [member tree_cell_size]² patch, half of patches
## seeded, and only on grass (rock outcrops grow nothing). Saplings
## aren't voxels: [Forest] plants them as decorations when a block
## bearing one streams in. The lattice hash runs first — it's cheap and
## rejects ~99% of columns, so only real candidates pay for the noise.
func sapling_species_at(x: int, z: int) -> StringName:
	if not _is_sapling_column(x, z):
		return &""
	var grass := _terrain_height(x, z)
	if grass <= _rock_top(x, z, grass):
		return &""
	return &"oak"


## Seeded sapling slots whose columns fall inside the square [param base]
## to base + size on x/z: {Vector2i(x, z): species}. Jumps straight to
## the tree_cell_size² lattice cells covering the region instead of
## probing every column — a 16×16 block is 4 cells, not 256.
func saplings_in(base: Vector3i, size: int) -> Dictionary:
	var out := {}
	var cx0 := floori(float(base.x) / tree_cell_size)
	var cx1 := floori(float(base.x + size - 1) / tree_cell_size)
	var cz0 := floori(float(base.z) / tree_cell_size)
	var cz1 := floori(float(base.z + size - 1) / tree_cell_size)
	for cx in range(cx0, cx1 + 1):
		for cz in range(cz0, cz1 + 1):
			var h := hash(Vector4i(world_seed, cx, cz, 53)) & 0x7fffffff
			if h & 0x40 == 0:
				continue
			var x := cx * tree_cell_size + h % tree_cell_size
			var z := cz * tree_cell_size + (h / tree_cell_size) % tree_cell_size
			if (
				x < base.x or x >= base.x + size
				or z < base.z or z >= base.z + size
			):
				continue
			var grass := _terrain_height(x, z)
			if grass <= _rock_top(x, z, grass):
				continue
			out[Vector2i(x, z)] = &"oak"
	return out


## True when the column is a tree's lattice slot: one deterministic cell
## per [member tree_cell_size]² patch, jittered within the cell — and only
## half of the patches seed a sapling (a spare hash bit is the gate).
func _is_sapling_column(x: int, z: int) -> bool:
	var cx := floori(float(x) / tree_cell_size)
	var cz := floori(float(z) / tree_cell_size)
	var h := hash(Vector4i(world_seed, cx, cz, 53)) & 0x7fffffff
	if h & 0x40 == 0:
		return false
	return (
		x == cx * tree_cell_size + h % tree_cell_size
		and z == cz * tree_cell_size + (h / tree_cell_size) % tree_cell_size
	)


func _is_cave(x: int, y: int, z: int) -> bool:
	return absf(_cave_noise.get_noise_3d(float(x), float(y) * 2.0, float(z))) < 0.05


func _ore_at(x: int, y: int, z: int, depth: int) -> int:
	var value := absf(_ore_noise.get_noise_3d(float(x), float(y), float(z)))
	for rule in _ore_rules:
		if depth >= int(rule[&"min_depth"]) and value > float(rule[&"threshold"]):
			return int(rule[&"block"])
	return Blocks.AIR
