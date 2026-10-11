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
## instead — used only when no soil field is installed (the site
## field's spec table takes over topsoil classes once it is).
@export var clay_threshold: float = 0.42

var _height_noise := FastNoiseLite.new()
var _clay_noise := FastNoiseLite.new()
var _rock_noise := FastNoiseLite.new()
## Soil-field pick channels — the patch noise resolves a spec's
## topsoil weights into clumps, the subsoil noise its B-horizon
## (DESIGN: Soils and hydrology). Mirrored in DelveGenerator.
var _patch_noise := FastNoiseLite.new()
var _subsoil_noise := FastNoiseLite.new()

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

## The site's soil/water field (SiteField), installed after the
## regional grid — a finer raster centred on the anchor that the
## generator samples per column. All integer math, mirrored into
## DelveGenerator the same way the regional grid is. Empty = the
## legacy flat ruleset (plain dirt, `soil_depth`, clay patches).
var _field_carve := PackedByteArray()
var _field_water := PackedInt32Array()
var _field_flood := PackedInt32Array() ## voxel-resolution waterline — _flood_water's output
var _field_soil := PackedByteArray()
var _field_depth := PackedByteArray()
var _field_spill := PackedInt32Array()
var _field_specs := PackedByteArray()
var _field_origin := Vector2i.ZERO
var _field_m := 1
var _field_side := 0

## Spec-table layout — the topsoil weight order and its block map.
## Subsoil weights follow the same packing (clay, sand, frozen); the
## remainder picks plain parent dirt.
const SOIL_TOPSOIL_KEYS: Array[StringName] = [
	&"poor", &"soil", &"rich", &"clay", &"sand", &"peat"
]
const SOIL_SUBSOIL_KEYS: Array[StringName] = [
	&"clay", &"sand", &"frozen", &"none"
]
const SOIL_SPEC_STRIDE := 10
const TOPSOIL_BLOCKS: Array[int] = [
	Blocks.POOR_DIRT, Blocks.DIRT, Blocks.RICH_DIRT,
	Blocks.CLAY, Blocks.SAND, Blocks.PEAT
]
const SUBSOIL_BLOCKS: Array[int] = [
	Blocks.CLAY, Blocks.SAND, Blocks.FROZEN_GROUND, Blocks.DIRT
]


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



	_clay_noise.seed = world_seed + 2
	_clay_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_clay_noise.frequency = 0.07

	_rock_noise.seed = world_seed + 3
	_rock_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_rock_noise.frequency = 0.02

	_patch_noise.seed = world_seed + 5
	_patch_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_patch_noise.frequency = 0.035

	_subsoil_noise.seed = world_seed + 6
	_subsoil_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_subsoil_noise.frequency = 0.028


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
	clear_site_field()
	if _native != null:
		_native.set("regional_grid", PackedInt32Array())


## Install the site's soil/water field (SiteField.generate) — carved
## drops, water levels, soil specs and depths in voxel-y integers.
## Mirrored into DelveGenerator in one shot; clear_site_field returns
## to the legacy flat ruleset.
func install_site_field(field: SiteField) -> void:
	_field_carve = field.carve
	_field_water = field.water
	_field_soil = field.soil
	_field_depth = field.depth_q
	_field_spill = field.spill
	_field_origin = field.origin
	_field_m = field.cell_m
	_field_side = field.side
	_field_specs = _pack_specs(field.specs)
	_flood_water(field)
	_field_flood = field.flood
	if _native != null:
		_native.call(
			"install_field", _field_carve, _field_water, _field_soil,
			_field_depth, _field_specs, _field_flood,
			_field_origin, _field_m, _field_side
		)


## Resolve the raster's water into a voxel-resolution waterline. The
## 4 m cells only decide WHERE water exists; this flood decides how
## far it reaches — every column of a flagged cell seeds at the
## cell's datum (flagged ⇒ submerged, so slope pockets the raster
## misread stay under the skin), then the water walks a short apron
## out into dry cells: any column whose carved surface sits below the
## propagated level and whose cell can actually hold it (the raster's
## own spill bound) takes water, out to APRON_VOX past the flag edge.
## The bound is deliberate — an unbounded flood follows sub-4 m dips
## the raster couldn't see for hundreds of metres and floods ground
## the hydrology meant to keep dry; the apron exists to land the
## shoreline on the terrain contour, not to re-resolve basins.
## Pure function of the installed rasters — computed once here and
## handed to the native mirror, so parity can't drift.
const APRON_VOX := 8 ## how far past a flagged edge water may reach (voxels)

func _flood_water(field: SiteField) -> void:
	var m := field.cell_m
	var vs := field.side * m
	field.flood = PackedInt32Array()
	field.flood.resize(vs * vs)
	field.flood.fill(SiteField.DRY)
	field.flood_cells = PackedByteArray()
	field.flood_cells.resize(field.side * field.side)
	var vdist := PackedInt32Array()
	vdist.resize(vs * vs)
	vdist.fill(APRON_VOX)
	var lo := 0
	var hi := SiteField.DRY
	for w in field.water:
		if w == SiteField.DRY:
			continue
		if hi == SiteField.DRY:
			lo = w
			hi = w
		else:
			lo = mini(lo, w)
			hi = maxi(hi, w)
	if hi == SiteField.DRY:
		return
	var buckets: Array = []
	buckets.resize(hi - lo + 1)
	for k in buckets.size():
		buckets[k] = []
	# Carved heights get probed from every flooded neighbour — cache
	# them so the frontier doesn't re-evaluate noise per check.
	const UNEVALED := -2147480000
	var carved := PackedInt32Array()
	carved.resize(vs * vs)
	carved.fill(UNEVALED)
	var carved_at := func(j: int) -> int:
		if carved[j] == UNEVALED:
			var wx := field.origin.x + j % vs
			var wz := field.origin.y + j / vs
			carved[j] = raw_height(wx, wz) - _carve_drop(wx, wz)
		return carved[j]
	# Fields without a resolved spill raster (synthetic fixtures) get
	# no hydraulic bound — every carved dip floods.
	var bounded := field.spill.size() == field.side * field.side
	# Seeds — flagged ⇒ submerged, the raster contract. Only cells
	# bordering dry ground enqueue work: propagation never enters a
	# flagged cell, the interior of a flat-water cluster can't spread
	# anywhere new, and skipping its queue entries is most of the
	# seed count on a big lake.
	for cz in field.side:
		for cx in field.side:
			var w: int = field.water[cz * field.side + cx]
			if w == SiteField.DRY:
				continue
			var spreads := false
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var jx: int = cx + d.x
				var jz: int = cz + d.y
				if jx < 0 or jx >= field.side or jz < 0 or jz >= field.side:
					continue
				var nw: int = field.water[jz * field.side + jx]
				if nw == SiteField.DRY:
					spreads = true
					break
			field.flood_cells[cz * field.side + cx] = 1
			for dz in m:
				var row := (cz * m + dz) * vs + cx * m
				for dx in m:
					var v := row + dx
					if field.flood[v] < w:
						field.flood[v] = w
						if spreads:
							vdist[v] = mini(dx, m - 1 - dx)
							vdist[v] = mini(vdist[v], mini(dz, m - 1 - dz))
							buckets[w - lo].append(v)
	# High-to-low drain: a column's first claim is its highest level.
	# Neighbour indices are v±1 / v±vs — unrolled, the array literal
	# would allocate per pop. Two gates keep the apron honest: the
	# propagated level must not exceed the cell's spill (the raster's
	# own "can this cell hold the water" bound), and the column must
	# sit in a cell the raster left dry — flagged cells keep their own
	# datum, so a reach can't re-flood a neighbouring water body.
	for level in range(hi, lo - 1, -1):
		var q: Array = buckets[level - lo]
		var qi := 0
		while qi < q.size():
			var v: int = q[qi]
			qi += 1
			var vx := v % vs
			var vz := v / vs
			var j: int
			var ci: int
			if vx > 0:
				j = v - 1
				ci = vz / m * field.side + (vx - 1) / m
				if (
					field.flood[j] < level and vdist[v] < APRON_VOX
					and field.water[ci] == SiteField.DRY
					and carved_at.call(j) < level
					and (not bounded or level <= field.spill[ci])
				):
					field.flood[j] = level
					field.flood_cells[ci] = 1
					vdist[j] = vdist[v] + 1
					q.append(j)
			if vx + 1 < vs:
				j = v + 1
				ci = vz / m * field.side + (vx + 1) / m
				if (
					field.flood[j] < level and vdist[v] < APRON_VOX
					and field.water[ci] == SiteField.DRY
					and carved_at.call(j) < level
					and (not bounded or level <= field.spill[ci])
				):
					field.flood[j] = level
					field.flood_cells[ci] = 1
					vdist[j] = vdist[v] + 1
					q.append(j)
			if vz > 0:
				j = v - vs
				ci = (vz - 1) / m * field.side + vx / m
				if (
					field.flood[j] < level and vdist[v] < APRON_VOX
					and field.water[ci] == SiteField.DRY
					and carved_at.call(j) < level
					and (not bounded or level <= field.spill[ci])
				):
					field.flood[j] = level
					field.flood_cells[ci] = 1
					vdist[j] = vdist[v] + 1
					q.append(j)
			if vz + 1 < vs:
				j = v + vs
				ci = (vz + 1) / m * field.side + vx / m
				if (
					field.flood[j] < level and vdist[v] < APRON_VOX
					and field.water[ci] == SiteField.DRY
					and carved_at.call(j) < level
					and (not bounded or level <= field.spill[ci])
				):
					field.flood[j] = level
					field.flood_cells[ci] = 1
					vdist[j] = vdist[v] + 1
					q.append(j)


func clear_site_field() -> void:
	_field_carve = PackedByteArray()
	_field_water = PackedInt32Array()
	_field_flood = PackedInt32Array()
	_field_soil = PackedByteArray()
	_field_depth = PackedByteArray()
	_field_spill = PackedInt32Array()
	_field_specs = PackedByteArray()
	_field_side = 0
	if _native != null:
		_native.call(
			"install_field", PackedByteArray(), PackedInt32Array(),
			PackedByteArray(), PackedByteArray(), PackedByteArray(),
			PackedInt32Array(),
			Vector2i.ZERO, 1, 0
		)


## Spec dicts → the flat byte table both generators read — topsoil
## weights in SOIL_TOPSOIL_KEYS order, then subsoil weights.
func _pack_specs(specs: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(specs.size() * SOIL_SPEC_STRIDE)
	for s in specs.size():
		var spec: Dictionary = specs[s]
		var row := s * SOIL_SPEC_STRIDE
		var tops: Dictionary = spec.get(&"topsoil", {})
		var subs: Dictionary = spec.get(&"subsoil", {})
		for k in SOIL_TOPSOIL_KEYS.size():
			out[row + k] = clampi(int(tops.get(SOIL_TOPSOIL_KEYS[k], 0)), 0, 255)
		for k in SOIL_SUBSOIL_KEYS.size():
			out[row + 6 + k] = clampi(int(subs.get(SOIL_SUBSOIL_KEYS[k], 0)), 0, 255)
	return out


## The field cell covering column (x,z), or -1 outside the installed
## window. Integer division truncates toward zero in both GDScript and
## C++, so the clamp keeps the edge-cell behaviour identical.
func _field_index(x: int, z: int) -> int:
	if _field_side < 1:
		return -1
	var cx := (x - _field_origin.x) / _field_m
	var cz := (z - _field_origin.y) / _field_m
	if cx < 0 or cx >= _field_side or cz < 0 or cz >= _field_side:
		return -1
	return cz * _field_side + cx


## The voxel-resolution field index covering world column (x,z), or
## -1 outside the installed window — indexes the flood waterline.
func _voxel_index(x: int, z: int) -> int:
	var n := _field_side * _field_m
	if n < 1:
		return -1
	var vx := x - _field_origin.x
	var vz := z - _field_origin.y
	if vx < 0 or vx >= n or vz < 0 or vz >= n:
		return -1
	return vz * n + vx


## The raster's resolved spill for the cell covering column (x,z) —
## the level water can stand at there before the bowl's outlet drains
## it. The live sim can carry flow *through* a cell above its spill,
## but nothing holds above it, so a surface above spill is unreachable
## ground for fixtures and play. SiteField.DRY when no field is
## installed.
func spill_level_at(x: int, z: int) -> int:
	var i := _field_index(x, z)
	if i < 0 or _field_spill.is_empty():
		return SiteField.DRY
	return _field_spill[i]


## Integer bilinear over the carve grid — each cell's drop anchors at
## its centre, so a carved channel centres its trough on the flagged
## cells and banks taper symmetrically into their neighbours. Mirrors
## DelveGenerator::carve_drop exactly.
func _carve_drop(x: int, z: int) -> int:
	if _field_side < 2:
		return 0
	var span := (_field_side - 1) * _field_m
	var cx := clampi(x - _field_origin.x - _field_m / 2, 0, span)
	var cz := clampi(z - _field_origin.y - _field_m / 2, 0, span)
	var gx := mini(cx / _field_m, _field_side - 2)
	var gz := mini(cz / _field_m, _field_side - 2)
	var fx := cx - gx * _field_m
	var fz := cz - gz * _field_m
	var i00 := gz * _field_side + gx
	var top := int(_field_carve[i00]) * (_field_m - fx) + int(_field_carve[i00 + 1]) * fx
	var bot := int(_field_carve[i00 + _field_side]) * (_field_m - fx) + int(_field_carve[i00 + _field_side + 1]) * fx
	return (top * (_field_m - fz) + bot * fz) / (_field_m * _field_m)


## Altitude of the land surface at a world column before water carving —
## regional bilinear plus local noise. The field pass samples this.
func raw_height(x: int, z: int) -> int:
	return _regional_base(x, z) + int(_height_noise.get_noise_2d(float(x), float(z)) * terrain_amplitude)


## The true land surface — raw height minus the field's carve drop.
## Everything that asks "where is the ground" reads this.
## Columns under the flood waterline are pulled a voxel below their
## datum: the raster's depression fill only sees 4 m centre samples,
## so without this the water skin would float over slope pockets
## whose rim the raster misread. The flood already resolves WHERE
## water is — this only shapes the bed under it. Mirrored in the
## native terrain_height.
func terrain_height(x: int, z: int) -> int:
	var h := raw_height(x, z) - _carve_drop(x, z)
	var i := _voxel_index(x, z)
	if i >= 0:
		var w := _field_flood[i]
		if w != SiteField.DRY and h > w - 1:
			h = w - 1
	return h


## Standing-water depth over a column in voxels — 0 when dry. Water is
## a level datum, never a block: the column is submerged while its
## carved top sits under the flooded datum.
func water_depth_at(x: int, z: int) -> int:
	var w := water_level_at(x, z)
	if w == SiteField.DRY:
		return 0
	return maxi(0, w - terrain_height(x, z))


## The water level datum at a column — the flood waterline's y, or
## SiteField.DRY where no water reaches. Floods move this; terrain
## never stores water.
func water_level_at(x: int, z: int) -> int:
	var i := _voxel_index(x, z)
	if i < 0:
		return SiteField.DRY
	return _field_flood[i]


## The column's soil depth in voxels — the field's per-cell depth
## (quarter-metres, spec × climate × slope resolved at install), or
## the legacy export when no field is installed.
func _soil_depth_at(x: int, z: int) -> int:
	var i := _field_index(x, z)
	if i < 0:
		return soil_depth
	return clampi((_field_depth[i] + 2) / 4, 0, 12)


## A weight-table pick against a spec row: [param offset] 0 walks the
## six topsoil weights, 6 the three subsoil ones; [param u] is the
## column's noise draw in 0..255. Returns the class index, or -1 when
## the weights are empty.
func _spec_pick(spec_i: int, u: int, offset: int, count: int) -> int:
	var row := spec_i * SOIL_SPEC_STRIDE + offset
	var total := 0
	for k in count:
		total += int(_field_specs[row + k])
	if total <= 0:
		return -1
	var v := (u * total) >> 8
	for k in count:
		v -= int(_field_specs[row + k])
		if v < 0:
			return k
	return -1


## A weight-table pick against the blended neighbourhood: the four
## cell-centres around the column contribute their spec rows in
## proportion to the same centre-anchored bilinear weights
## `_carve_drop` samples, so soil classes feather across a field edge
## instead of stepping on it — 4 m peat and sand cells meet as a
## speckled transition, not a cliff. Falls back to the plain pick when
## the field is too small to blend. Mirrors
## DelveGenerator::spec_pick_blended.
func _spec_pick_blended(
	x: int, z: int, i: int, u: int, offset: int, count: int
) -> int:
	if _field_side < 2:
		return _spec_pick(int(_field_soil[i]), u, offset, count)
	var span := (_field_side - 1) * _field_m
	var cx := clampi(x - _field_origin.x - _field_m / 2, 0, span)
	var cz := clampi(z - _field_origin.y - _field_m / 2, 0, span)
	var gx := mini(cx / _field_m, _field_side - 2)
	var gz := mini(cz / _field_m, _field_side - 2)
	var fx := cx - gx * _field_m
	var fz := cz - gz * _field_m
	var i00 := gz * _field_side + gx
	var ws: Array[int] = [
		(_field_m - fx) * (_field_m - fz),
		fx * (_field_m - fz),
		(_field_m - fx) * fz,
		fx * fz,
	]
	var corners: Array[int] = [
		i00, i00 + 1, i00 + _field_side, i00 + _field_side + 1,
	]
	var blend := PackedInt64Array()
	blend.resize(count)
	for c in 4:
		var row := int(_field_soil[corners[c]]) * SOIL_SPEC_STRIDE + offset
		for k in count:
			blend[k] += int(_field_specs[row + k]) * ws[c]
	var total := 0
	for k in count:
		total += blend[k]
	if total <= 0:
		return -1
	var v := (u * total) >> 8
	for k in count:
		v -= blend[k]
		if v < 0:
			return k
	return -1


## The column's topsoil block — the surface voxel's grade. Unfielded
## terrain keeps the legacy clay-patch rule.
func _topsoil_block(x: int, z: int) -> int:
	var i := _field_index(x, z)
	if i < 0:
		return Blocks.CLAY if _clay_at(x, z) else Blocks.DIRT
	var u := clampi(int((_patch_noise.get_noise_2d(float(x), float(z)) + 1.0) * 128.0), 0, 255)
	var pick := _spec_pick_blended(x, z, i, u, 0, TOPSOIL_BLOCKS.size())
	return TOPSOIL_BLOCKS[pick] if pick >= 0 else Blocks.DIRT


## The column's subsoil block — the band under the topsoil voxel.
## "None" weights fall through to plain parent dirt.
func _subsoil_block(x: int, z: int) -> int:
	var i := _field_index(x, z)
	if i < 0:
		return Blocks.CLAY if _clay_at(x, z) else Blocks.DIRT
	var u := clampi(int((_subsoil_noise.get_noise_2d(float(x), float(z)) + 1.0) * 128.0), 0, 255)
	var pick := _spec_pick_blended(x, z, i, u, 6, SUBSOIL_BLOCKS.size())
	return SUBSOIL_BLOCKS[pick] if pick >= 0 else Blocks.DIRT


## Open growable ground — soil surface over rock, out of the water.
## Saplings, bushes and grass all read this instead of re-deriving it.
func _grows_at(x: int, z: int) -> bool:
	var grass := terrain_height(x, z)
	if grass <= _rock_top(x, z, grass):
		return false
	if water_depth_at(x, z) > 0:
		return false
	return BlockRegistry.fertilizability(_topsoil_block(x, z)) > 0.0


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
	# The soil band's depth is per-column when a site field is
	# installed — slope and climate already priced in. The outcrop
	# ramp keeps the fixed export so protrusion heights stay stable.
	var normal := grass - _soil_depth_at(x, z)
	var n := _rock_noise.get_noise_2d(float(x), float(z))
	if n <= outcrop_threshold:
		return normal
	var t := (n - outcrop_threshold) / (1.0 - outcrop_threshold)
	var top := normal + int(round(t * (soil_depth + outcrop_protrusion)))
	# Water wins: an outcrop under a level datum tops out at the
	# surface — a drowned ledge whose tip breaks the skin — rather
	# than damming a channel or a pond with a pillar.
	var w := water_level_at(x, z)
	if w > SiteField.DRY and top > w:
		return w
	return top


## Surface altitude (the y of the topmost solid voxel) at a world column.
func surface_height(x: int, z: int) -> int:
	var grass := terrain_height(x, z)
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
	var grass := terrain_height(x, z)
	var rock := _rock_top(x, z, grass)
	# Bare ground grows nothing — rock tops, open water, and topsoil
	# that can't hold cover (clay, sand, peat, frozen).
	if (
		grass <= rock
		or water_depth_at(x, z) > 0
		or BlockRegistry.fertilizability(_topsoil_block(x, z)) <= 0.0
	):
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
	# Channel carving dips the surface a few voxels below the noise
	# trough — the bound has to stay under it.
	return base_height - int(ceil(terrain_amplitude)) - 1 - SiteField.RIVER_CUT - 1


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
			var grass := terrain_height(x, z)
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
		# The soil band: the surface voxel carries the graded topsoil,
		# the rest of the column is the spec's subsoil class.
		return _topsoil_block(x, z) if y == grass else _subsoil_block(x, z)

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
	if not _grows_at(x, z):
		return &""
	return _sapling_pick(x, z)


## The pack's sapling species for a lattice cell — hashed so a column's
## pick is stable across calls and streaming order.
func _sapling_pick(x: int, z: int) -> StringName:
	var trees: Array = DataPackage.worldgen().get(&"saplings", [])
	if trees.is_empty():
		return &""
	var h := hash(Vector4i(
		world_seed,
		floori(float(x) / tree_cell_size),
		floori(float(z) / tree_cell_size),
		53
	)) & 0x7fffffff
	return trees[(h >> 12) % trees.size()]


## Seeded sapling slots whose columns fall inside the square [param base]
## to base + size on x/z: {Vector2i(x, z): species}. Jumps straight to
## the tree_cell_size² lattice cells covering the region instead of
## probing every column — a 16×16 block is 4 cells, not 256.
func saplings_in(base: Vector3i, size: int) -> Dictionary:
	var out := {}
	var trees: Array = DataPackage.worldgen().get(&"saplings", [])
	if trees.is_empty():
		return out
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
			if not _grows_at(x, z):
				continue
			out[Vector2i(x, z)] = trees[(h >> 12) % trees.size()]
	return out


## Seeded bush slots whose columns fall inside [param base] to
## base + size on x/z: {Vector2i(x, z): species} — the same lattice walk
## as [method saplings_in], on the bush grid with its own salt. Bushes
## grow on grass columns only, same as saplings.
func bushes_in(base: Vector3i, size: int) -> Dictionary:
	var out := {}
	var bush_weights: Dictionary = DataPackage.worldgen().get(&"bushes", {})
	if bush_weights.is_empty():
		return out
	var bush_weight_total := 0
	for id: StringName in bush_weights:
		bush_weight_total += int(bush_weights[id])
	if bush_weight_total <= 0:
		return out
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
			if not _grows_at(x, z):
				continue
			# The pack's weighted bush mix — vanilla keeps heal-all a
			# one-in-eight slot so a colony still farms it.
			var pick := (h >> 9) % bush_weight_total
			var species := &""
			for id: StringName in bush_weights:
				pick -= int(bush_weights[id])
				if pick < 0:
					species = id
					break
			if species == &"":
				continue
			out[Vector2i(x, z)] = species
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
				or water_depth_at(x, z) > 0
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


## Cavern lattice — sparse ellipsoid chambers on a 48m 3D cell grid,
## plus short tunnels between face-adjacent chambers. Fewer, larger
## caves than the old worm-noise lace; everything hashes through _imix
## so the native DelveGenerator agrees bit-for-bit. Salts live in their
## own band, clear of the intrusion salts.
const CAVE_CELL := 48
const CAVE_SALT_A := 31001
const CAVE_SALT_B := 31002
const CAVE_SALT_LINK := 31010


## The chamber a lattice cell hosts — empty when the cell is bare
## (~28% host rate). Centre and radii come from the cell's own hash so
## a voxel anywhere can answer membership by checking nearby cells.
func _cavern_at(cx: int, cy: int, cz: int) -> Dictionary:
	var h1 := _imix(cx, cy, cz, CAVE_SALT_A)
	if h1 % 1000 >= 280:
		return {}
	var h2 := _imix(cx, cy, cz, CAVE_SALT_B)
	return {
		&"center": Vector3i(
			cx * CAVE_CELL + 6 + (h1 >> 10) % 36,
			cy * CAVE_CELL + 6 + h2 % 36,
			cz * CAVE_CELL + 6 + (h1 >> 20) % 36),
		&"rx": 10 + (h2 >> 6) % 9,
		&"ry": 5 + (h2 >> 14) % 6,
		&"rz": 10 + (h2 >> 20) % 9,
	}


## Whether two face-adjacent cells run a tunnel between their
## chambers — ~45% of host pairs, keyed canonically on the lower
## endpoint + axis so either query direction agrees.
func _cavern_link(a: Vector3i, b: Vector3i) -> bool:
	var lo := a
	var hi := b
	if hi.x < lo.x or hi.y < lo.y or hi.z < lo.z:
		lo = b
		hi = a
	var axis := 0 if hi.x != lo.x else (1 if hi.y != lo.y else 2)
	return _imix(lo.x, lo.y, lo.z, CAVE_SALT_LINK + axis) % 1000 < 450


## Squared distance from point p to segment a→b (tunnel walls).
func _seg_dist2(p: Vector3i, a: Vector3i, b: Vector3i) -> float:
	var ab := Vector3(b - a)
	var len2 := ab.length_squared()
	var pa := Vector3(p - a)
	if len2 <= 0.0:
		return pa.length_squared()
	var t := clampf(pa.dot(ab) / len2, 0.0, 1.0)
	return pa.distance_squared_to(Vector3(a) + ab * t)


func _is_cave(x: int, y: int, z: int) -> bool:
	var cx := floori(float(x) / CAVE_CELL)
	var cy := floori(float(y) / CAVE_CELL)
	var cz := floori(float(z) / CAVE_CELL)
	# A chamber's reach stays inside its cell ring (offsets ≥6, radii
	# ≤18), and a tunnel only spans the two cells it links — the 3×3×3
	# neighbourhood covers everything that can touch this voxel.
	const FWD := [Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 1)]
	var p := Vector3i(x, y, z)
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var cell := Vector3i(cx + dx, cy + dy, cz + dz)
				var cav := _cavern_at(cell.x, cell.y, cell.z)
				if cav.is_empty():
					continue
				var d: Vector3i = p - cav[&"center"]
				var nx := d.x / float(cav[&"rx"])
				var ny := d.y / float(cav[&"ry"])
				var nz := d.z / float(cav[&"rz"])
				if nx * nx + ny * ny + nz * nz <= 1.0:
					return true
				for s in FWD:
					var next: Vector3i = cell + s
					var other := _cavern_at(next.x, next.y, next.z)
					if other.is_empty() or not _cavern_link(cell, next):
						continue
					if _seg_dist2(
						p, cav[&"center"], other[&"center"]
					) <= 9.0:
						return true
	return false


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
	var grass := terrain_height(x, z)
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
				var grass := terrain_height(px, pz)
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
