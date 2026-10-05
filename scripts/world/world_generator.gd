class_name WorldGenerator
extends VoxelGeneratorScript

## Procedural terrain for the colony: a rolling soil surface over stone —
## grass itself is a decoration layer (see Grass, PLAN item 12) — with
## occasional rock masses that rise at or above the surface, plus caves
## and depth-dependent ore veins.
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
## Thickness of the topsoil band at the surface.
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
## Berry bushes scatter on their own coarser lattice — a food source has
## to be findable but not a lawn.
@export var bush_cell_size: int = 10
## Surface scree — small clusters of loose cobbles and boulders — on a
## much coarser lattice again: a fresh colony needs stone in reach but
## the ground shouldn't read as a quarry.
@export var rock_cell_size: int = 40
## Soil-patch noise threshold: above it the dirt band lays down clay
## instead. The patches come out as loose clusters along the surface —
## near-water placement comes with water features (PLAN item 42).
@export var clay_threshold: float = 0.42

var _height_noise := FastNoiseLite.new()
var _cave_noise := FastNoiseLite.new()
var _clay_noise := FastNoiseLite.new()
var _rock_noise := FastNoiseLite.new()

## Underground mineral intrusions: one seeded 3D lattice cell of this
## side length either holds a connected blob of 3–9 ore voxels in the
## rock or it doesn't — the hash decides. Mirrored cell-for-cell in
## delve_generator.cpp; both draw from the same _imix.
const INTRUSION_DEEP_CELL := 12
## Surface intrusions ride a 2D lattice: each cell inside an outcrop can
## seed one or two small blobs (1–3 voxels) of mineral embedded in the
## exposed rock — "each small stone outcrop carries an ore hint".
const INTRUSION_SURF_CELL := 8
## A blob never grows farther than its target size in Manhattan steps
## from its centre, so a voxel's possible owners all sit within one
## lattice cell of it — the per-voxel query scans neighbours only.
const INTRUSION_REACH := 4

## The mineral pick, by weight — common measures dominate, cassiterite
## and native gold stay rare. Sum is the divisor.
const INTRUSION_TABLE: Array[int] = [
	Blocks.COAL_ORE, Blocks.COAL_ORE, Blocks.COAL_ORE, Blocks.COAL_ORE,
	Blocks.HEMATITE_ORE, Blocks.HEMATITE_ORE, Blocks.HEMATITE_ORE,
	Blocks.HEMATITE_ORE,
	Blocks.MALACHITE_ORE, Blocks.MALACHITE_ORE, Blocks.MALACHITE_ORE,
	Blocks.CASSITERITE_ORE, Blocks.CASSITERITE_ORE,
	Blocks.NATIVE_GOLD_ORE,
]

## Face-neighbour expansion order — fixed so the GDScript and C++
## generators grow identical blobs.
const INTRUSION_SIDES: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

## Compiled twin of this generator, or null when delve_native isn't built.
var _native: VoxelGeneratorScript

## Regional layer: an integer heightfield in voxel units, installed when
## a world tile's MesoMap resolves around the active site. Node [i,j]
## sits at world column (_regional_origin + (i,j) * _regional_step);
## _regional_base bilinearly interpolates between nodes and clamps to
## the border outside the window. Empty = flat stub at base_height.
var _regional_grid := PackedInt32Array()
var _regional_origin := Vector2i.ZERO
var _regional_step := 1
var _regional_size := 0


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

	_clay_noise.seed = world_seed + 2
	_clay_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_clay_noise.frequency = 0.07

	_rock_noise.seed = world_seed + 3
	_rock_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_rock_noise.frequency = 0.02


func _get_used_channels_mask() -> int:
	return 1 << VoxelBuffer.CHANNEL_TYPE


## Install the regional heightfield the mesoscale map resolved around
## the site (MesoMap.voxel_grid). Must mirror into DelveGenerator — the
## parity contract covers it — so only integer math may reach the data.
func install_regional_grid(grid: PackedInt32Array, origin: Vector2i, step: int, size: int) -> void:
	_regional_grid = grid
	_regional_origin = origin
	_regional_step = maxi(step, 1)
	_regional_size = size
	if _native != null:
		_native.set("regional_origin", origin)
		_native.set("regional_step", _regional_step)
		_native.set("regional_size", size)
		_native.set("regional_grid", grid)


## Drop the regional layer — terrain returns to the flat base-height
## stub. Used by tests that need pristine flat terrain.
func clear_regional_grid() -> void:
	_regional_grid = PackedInt32Array()
	if _native != null:
		_native.set("regional_grid", PackedInt32Array())


## Altitude of the grass-and-dirt surface at a world column, ignoring rock.
func _terrain_height(x: int, z: int) -> int:
	return _regional_base(x, z) + int(_height_noise.get_noise_2d(float(x), float(z)) * terrain_amplitude)


## The regional layer's contribution to column height — the left term in
## the two-layer split (DESIGN: surface = regional_base + local detail).
## With no grid installed it stays the flat [member base_height] stub;
## otherwise it bilinearly samples the installed mesoscale window in
## pure integer math — mirrored exactly in DelveGenerator::regional_base,
## including the border clamp, so the two stay voxel-identical.
func _regional_base(x: int, z: int) -> int:
	if _regional_grid.is_empty() or _regional_size < 2:
		return base_height
	var span := (_regional_size - 1) * _regional_step
	var cx := clampi(x - _regional_origin.x, 0, span)
	var cz := clampi(z - _regional_origin.y, 0, span)
	# gx stops at size-2 so the +1/+size reads stay in bounds; fx can
	# reach step exactly at the far edge, which evaluates to the border
	# node's exact value.
	var gx := mini(cx / _regional_step, _regional_size - 2)
	var gz := mini(cz / _regional_step, _regional_size - 2)
	var fx := cx - gx * _regional_step
	var fz := cz - gz * _regional_step
	var i00 := gz * _regional_size + gx
	var top := _regional_grid[i00] * (_regional_step - fx) + _regional_grid[i00 + 1] * fx
	var bot := _regional_grid[i00 + _regional_size] * (_regional_step - fx) + _regional_grid[i00 + _regional_size + 1] * fx
	# GDScript and C++ int division both truncate toward zero, so the
	# negative-height path stays parity-identical too.
	return (top * (_regional_step - fz) + bot * fz) / (_regional_step * _regional_step)


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


## Seeded grass coverage for a soil-topped column, or a negative number
## when rock tops it (outcrops grow none). Grass is a decoration layer,
## not voxel data — this is just the deterministic seed value Grass
## consults as blocks stream in; live coverage belongs to Grass.
func grass_seed_at(x: int, z: int) -> float:
	var col := grass_column(x, z)
	return col.y


## The column's surface voxel y and its grass seed in one oracle pass —
## [code]Vector2(surface_y, seed)[/code], seed < 0 on rock. The terrain
## pair is the expensive part (two noise evals), so the per-column
## streaming scan pays it once instead of per question.
func grass_column(x: int, z: int) -> Vector2:
	var grass := _terrain_height(x, z)
	var rock := _rock_top(x, z, grass)
	# Clay soil grows no grass — the patch reads as bare ground.
	if grass <= rock or _clay_at(x, z):
		return Vector2(maxi(grass, rock), -1.0)
	return Vector2(
		grass,
		0.4
		+ 0.6 * float((hash(Vector4i(x, 0, z, world_seed)) & 0x7fffffff) % 1000)
			/ 1000.0
	)


## Global bounds on [method surface_height] — a streamed block whose
## y-range clears them can't contain any column's surface, so the
## decoration seeders skip its 256-column sweep entirely.
func min_surface_height() -> int:
	return base_height - int(ceil(terrain_amplitude)) - 1


func max_surface_height() -> int:
	return (
		base_height
		+ int(ceil(terrain_amplitude))
		+ int(ceil(outcrop_protrusion))
		+ 1
	)


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


## True when the column's dirt band is a clay patch — clay clusters
## spawn in place of dirt at the surface (later: preferentially near
## water). Checked on x/z only: the whole soil column goes clay.
func _clay_at(x: int, z: int) -> bool:
	return _clay_noise.get_noise_2d(float(x), float(z)) > clay_threshold


func _block_at(x: int, y: int, z: int, grass: int, rock_top: int) -> int:
	var top := maxi(grass, rock_top)
	if y > top:
		return Blocks.AIR
	if y <= bedrock_height:
		return Blocks.STONE
	if y > rock_top:
		return Blocks.CLAY if _clay_at(x, z) else Blocks.DIRT

	var depth := top - y
	if depth > 2 and _is_cave(x, y, z):
		return Blocks.AIR

	var ore := _intrusion_at(x, y, z)
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
	if grass <= _rock_top(x, z, grass) or _clay_at(x, z):
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
			if grass <= _rock_top(x, z, grass) or _clay_at(x, z):
				continue
			out[Vector2i(x, z)] = &"oak"
	return out


## Seeded bush slots whose columns fall inside [param base] to
## base + size on x/z: {Vector2i(x, z): species} — the same lattice walk
## as [method saplings_in], on the bush grid with its own salt. Bushes
## grow on grass columns only, same as saplings.
func bushes_in(base: Vector3i, size: int) -> Dictionary:
	var out := {}
	var cx0 := floori(float(base.x) / bush_cell_size)
	var cx1 := floori(float(base.x + size - 1) / bush_cell_size)
	var cz0 := floori(float(base.z) / bush_cell_size)
	var cz1 := floori(float(base.z + size - 1) / bush_cell_size)
	for cx in range(cx0, cx1 + 1):
		for cz in range(cz0, cz1 + 1):
			var h := hash(Vector4i(world_seed, cx, cz, 61)) & 0x7fffffff
			if h & 0x80 == 0:
				continue
			var x := cx * bush_cell_size + h % bush_cell_size
			var z := cz * bush_cell_size + (h / bush_cell_size) % bush_cell_size
			if (
				x < base.x or x >= base.x + size
				or z < base.z or z >= base.z + size
			):
				continue
			var grass := _terrain_height(x, z)
			if grass <= _rock_top(x, z, grass) or _clay_at(x, z):
				continue
			# One seeded slot in eight bears heal-all instead of
			# berries — the medicinal herb is findable in the wild but
			# scarce enough that a colony farms it.
			out[Vector2i(x, z)] = (
				&"heal_all" if (h >> 9) % 8 == 0 else &"berry_bush"
			)
	return out


## Surface scree slots whose columns fall inside [param base] to
## base + size on x/z: {Vector2i(x, z): {boulders, cobbles, mineral}} —
## the same lattice walk as [method bushes_in], on the rock grid with
## its own salt. A seeded cell scatters a main pile and sometimes a
## cobble satellite beside it; the colony drops them as real item piles
## when the block streams in, so they're gathered like mined stone.
## Scree lands on any surface — rock outcrops included. Roughly one
## pile in six is ore-bearing instead of plain stone (`mineral` names
## the resource; absent means stone) — alluvial concentration belongs
## to the water feature, so for now the scatter is seed-flat.
func loose_rocks_in(base: Vector3i, size: int) -> Dictionary:
	var out := {}
	var cx0 := floori(float(base.x) / rock_cell_size)
	var cx1 := floori(float(base.x + size - 1) / rock_cell_size)
	var cz0 := floori(float(base.z) / rock_cell_size)
	var cz1 := floori(float(base.z + size - 1) / rock_cell_size)
	for cx in range(cx0, cx1 + 1):
		for cz in range(cz0, cz1 + 1):
			var h := hash(Vector4i(world_seed, cx, cz, 71)) & 0x7fffffff
			# A third of lattice cells seed a cluster.
			if h & 0x30 == 0:
				continue
			var x := cx * rock_cell_size + h % rock_cell_size
			var z := cz * rock_cell_size + (h / rock_cell_size) % rock_cell_size
			if (
				x < base.x or x >= base.x + size
				or z < base.z or z >= base.z + size
			):
				continue
			# ~1 pile in 6 carries an intrusion mineral instead of stone.
			var mineral := -1
			if (h >> 20) % 6 == 0:
				mineral = BlockRegistry.ores_mineral(
					INTRUSION_TABLE[(h >> 17) % INTRUSION_TABLE.size()]
				)
			out[Vector2i(x, z)] = {
				&"boulders": 1 + (h >> 8) % 3,
				&"cobbles": 4 + (h >> 12) % 7,
				&"mineral": mineral,
			}
			# Half the clusters shed a cobble-only satellite one cell
			# over — the cluster reads as scree, not a tidy stack.
			if h & 0x40 != 0:
				var sx := x + 1 - int((h >> 6) % 3)
				var sz := z + 1 - int((h >> 9) % 3)
				if (
					(sx != x or sz != z)
					and sx >= base.x and sx < base.x + size
					and sz >= base.z and sz < base.z + size
					and not out.has(Vector2i(sx, sz))
				):
					out[Vector2i(sx, sz)] = {
						&"boulders": 0, &"cobbles": 2 + (h >> 14) % 5,
						&"mineral": mineral,
					}
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


## Deterministic 32-bit mix — identical arithmetic to
## DelveGenerator::imix in delve_generator.cpp. The intrusion layout is
## world data: both generators must agree bit-for-bit, so this never
## calls Godot's hash() (whose internals are engine-defined).
func _imix(x: int, y: int, z: int, salt: int) -> int:
	var h: int = (
		x * 2654435761 + y * 2246822519 + z * 3266489917
		+ salt * 668265263 + world_seed * 374761393
	) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 3266489917) & 0xFFFFFFFF
	h = (h ^ (h >> 16)) & 0xFFFFFFFF
	return h


## Would this voxel generate as plain country rock — the only matrix an
## intrusion may occupy? Stone means under the rock face, out of the
## soil band, and not eaten by a cave. Mirrors DelveGenerator's
## base_is_stone.
func _base_is_stone(x: int, y: int, z: int) -> bool:
	if y <= bedrock_height:
		return true
	var grass := _terrain_height(x, z)
	var rt := _rock_top(x, z, grass)
	var top := maxi(grass, rt)
	if y > top or y > rt:
		return false
	if top - y > 2 and _is_cave(x, y, z):
		return false
	return true


## The ore block at a rock voxel — AIR for country stone. Membership is
## derived, not stored: scan the intrusion lattices whose cells can
## reach here, regrow each seeded blob, and ask whether this voxel is
## in it. Both generators implement the same scan.
func _intrusion_at(x: int, y: int, z: int) -> int:
	# Surface lattice — blobs only exist inside outcrop rock.
	var sc := INTRUSION_SURF_CELL
	var cx := floori(float(x) / sc)
	var cz := floori(float(z) / sc)
	for dcx in range(-1, 2):
		for dcz in range(-1, 2):
			var c0x := cx + dcx
			var c0z := cz + dcz
			var h := _imix(c0x, 0, c0z, 811)
			# ~half of cells seed, each one or two blobs.
			if h % 2 == 0:
				continue
			for k in 1 + (h >> 3) % 2:
				var hk := _imix(c0x, k, c0z, 937)
				var px := c0x * sc + hk % sc
				var pz := c0z * sc + (hk >> 4) % sc
				var grass := _terrain_height(px, pz)
				var rt := _rock_top(px, pz, grass)
				if rt <= grass:
					continue  # no outcrop at the seed column
				var center := Vector3i(px, rt - 1 - (hk >> 8) % 2, pz)
				var size := 1 + (hk >> 12) % 3
				var dist := (
					absi(x - center.x) + absi(y - center.y)
					+ absi(z - center.z)
				)
				if dist > size + 1:
					continue
				var ore := _intrusion_member(
					center, size, INTRUSION_TABLE[hk % 14],
					Vector3i(x, y, z), hk
				)
				if ore != Blocks.AIR:
					return ore
	# Deep lattice — blobs scatter through the rock mass.
	var dc := INTRUSION_DEEP_CELL
	var bx := floori(float(x) / dc)
	var by := floori(float(y) / dc)
	var bz := floori(float(z) / dc)
	for dxx in range(-1, 2):
		for dyy in range(-1, 2):
			for dzz in range(-1, 2):
				var c0x := bx + dxx
				var c0y := by + dyy
				var c0z := bz + dzz
				var h := _imix(c0x, c0y, c0z, 613)
				# ~2 cells in 5 seed a blob.
				if h % 5 > 1:
					continue
				var center := Vector3i(
					c0x * dc + h % dc,
					c0y * dc + (h >> 5) % dc,
					c0z * dc + (h >> 10) % dc
				)
				var size := 3 + (h >> 15) % 7
				var dist := (
					absi(x - center.x) + absi(y - center.y)
					+ absi(z - center.z)
				)
				if dist > size + 1:
					continue
				var ore := _intrusion_member(
					center, size, INTRUSION_TABLE[(h >> 21) % 14],
					Vector3i(x, y, z), h
				)
				if ore != Blocks.AIR:
					return ore
	return Blocks.AIR


## Whether [param v] belongs to the blob grown from [param center]: the
## block id when it does, AIR otherwise. Growth is a face-connected
## flood — each step takes the unvisited neighbour with the lowest hash
## (organically-shaped nuggets), counting only rock voxels toward the
## target size so blobs at stone edges just run short.
func _intrusion_member(
	center: Vector3i, size: int, block: int, v: Vector3i, salt: int
) -> int:
	if not _base_is_stone(center.x, center.y, center.z):
		return Blocks.AIR
	if v == center:
		return block
	var members := 1
	var visited := {center: true}
	var frontier: Array[Vector3i] = []
	_seed_frontier(frontier, visited, center)
	while members < size and not frontier.is_empty():
		var best := 0
		var best_h := _imix(
			frontier[0].x, frontier[0].y, frontier[0].z, salt
		)
		for i in range(1, frontier.size()):
			var hv := _imix(
				frontier[i].x, frontier[i].y, frontier[i].z, salt
			)
			if hv < best_h:
				best_h = hv
				best = i
		var pick := frontier[best]
		frontier.remove_at(best)
		var stone := _base_is_stone(pick.x, pick.y, pick.z)
		if pick == v:
			return block if stone else Blocks.AIR
		if stone:
			members += 1
		for side in INTRUSION_SIDES:
			var n := pick + side
			if visited.has(n):
				continue
			visited[n] = true
			if (
				absi(n.x - center.x) + absi(n.y - center.y)
				+ absi(n.z - center.z) <= size + 1
			):
				frontier.append(n)
	return Blocks.AIR


func _seed_frontier(
	frontier: Array[Vector3i], visited: Dictionary, v: Vector3i
) -> void:
	for side in INTRUSION_SIDES:
		var n := v + side
		if not visited.has(n):
			visited[n] = true
			frontier.append(n)
