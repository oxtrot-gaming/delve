class_name Grass
extends Node

## Ground cover as a decoration layer — the forest's sapling model
## applied per surface cell. A grassed voxel is still plain DIRT: it
## mines as soil, paths as terrain, and only this system knows it's
## green. Coverage is a float 0..1 — the generator seeds the surface at
## mixed coverage, foot traffic wears it down, and a lush cell slowly
## spreads into bare neighbours. Grazing will read the same coverage.
##
## A cell's cover dies when the block is mined out or its top face gets
## covered — by a wall block, a building, or a packed pile. Records
## persist across streaming: a zeroed cell keeps its entry, so a
## trampled path or a demolished wall's floor doesn't reseed when its
## block reloads.

const Blocks := BlockRegistry.Block

var world: VoxelWorld
var colony: Colony

## voxel → coverage 0..1. Every seeded cell has a record; a 0 entry
## means "seen, currently bare" — which also tombstones it against
## reseeding on the next stream-in.
var coverage: Dictionary = {}
## Columns the oracle calls grassed but that weren't seedable when
## their block arrived — retried until their surface cell loads.
var _pending: Dictionary = {}

## Column-chunk (16×16 x/z window) → the multimesh drawing that chunk's
## cover slabs. One multimesh for the whole map meant every trample or
## seed rebuilt ~100k instances — chunking keeps a rebuild under ~256.
var _chunk_meshes: Dictionary = {}
## Column-chunk → {cell: true}: which coverage cells each chunk draws.
var _chunk_cells: Dictionary = {}
var _dirty_chunks: Dictionary = {}
var _cover_mesh: BoxMesh
var _scan_elapsed := 0.0
var _scan_keys: Array = []
var _scan_pos := 0
var _refresh_elapsed := 0.0

## One entry into a cell's column removes this much cover — about five
## crossings bare a healthy cell.
const TRAMPLE_WEAR := 0.2
## Cover a living patch regains each time the scan visits it.
const REGROW_STEP := 0.05
## Game-seconds between scan slices.
const SCAN_TICK_SEC := 2.0
## Records validated and grown per scan tick — the map's cells are
## visited round-robin, so a full cycle takes size/SCAN_SLICE ticks.
const SCAN_SLICE := 4096
## Per-cell chance per scan visit that a lush cell seeds a neighbour.
const SPREAD_CHANCE := 0.3
## A cell needs this much cover before it can seed neighbours.
const SPREAD_MIN := 0.7
## Cover a spread-seeded cell starts at; cells already above it are
## left alone — they regrow on their own.
const SPREAD_START := 0.3
## Slowest allowed decoration rebuild — foot traffic batches into these.
const REFRESH_MIN_SEC := 0.75
## Most column-chunks rebuilt per refresh — a whole-map-dirty moment
## (fresh seed, mass regrowth) spreads over successive ticks instead of
## one hitch; leftovers stay dirty until their turn.
const REFRESH_MAX_CHUNKS := 48
## Thickness of the ground-cover slab on a grassed top face.
const COVER_THICK := 0.06

const SIDES: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)
]


func setup(p_world: VoxelWorld, p_colony: Colony) -> void:
	world = p_world
	colony = p_colony
	_cover_mesh = BoxMesh.new()
	_cover_mesh.size = Vector3(0.96, COVER_THICK, 0.96)
	world.block_loaded.connect(_on_block_loaded)
	world.block_placed.connect(_on_block_placed)
	world.block_mined.connect(_on_cell_lost)
	world.block_collapsed.connect(_on_cell_lost)


func _process(delta: float) -> void:
	if world == null:
		return
	_scan_elapsed += delta
	if _scan_elapsed >= SCAN_TICK_SEC:
		_scan_elapsed = 0.0
		_scan_tick()
	_refresh_elapsed += delta
	if not _dirty_chunks.is_empty() and _refresh_elapsed >= REFRESH_MIN_SEC:
		_refresh_elapsed = 0.0
		_refresh_decorations()


## Cover at [param cell] right now — lazily validates, so a cell whose
## block went away or got covered reads bare.
func coverage_at(cell: Vector3i) -> float:
	var c := float(coverage.get(cell, 0.0))
	if c <= 0.0:
		return 0.0
	if not _eligible(cell):
		_set_cover(cell, 0.0)
		return 0.0
	return c


## True while [param cell] carries any living cover — the query grazing
## will share.
func grassed(cell: Vector3i) -> bool:
	return coverage_at(cell) > 0.0


## Foot traffic: one entry into the cell's column wears this much
## cover. The caller keys it to ground-cell changes, so standing still
## doesn't grind — only passing over does.
func trample(cell: Vector3i) -> void:
	var c := float(coverage.get(cell, 0.0))
	if c <= 0.0:
		return
	_set_cover(cell, maxf(0.0, c - TRAMPLE_WEAR))


## Strips a cell bare — construction buries the grass under it.
func bare(cell: Vector3i) -> void:
	if float(coverage.get(cell, 0.0)) > 0.0:
		_set_cover(cell, 0.0)


## One spread attempt outward from a lush cell: the first bare or thin
## eligible neighbour in a hashed direction order gains cover, stepping
## up or down one level for terraces. Public for tests.
func spread_from(cell: Vector3i) -> bool:
	var start := _hash(cell) % 4
	for i in range(4):
		var dir: Vector3i = SIDES[(start + i) % 4]
		for dy in [0, 1, -1]:
			var n := cell + dir + Vector3i(0, dy, 0)
			if not _eligible(n):
				continue
			if float(coverage.get(n, 0.0)) >= SPREAD_START:
				continue
			_set_cover(n, SPREAD_START)
			_pending.erase(Vector2i(n.x, n.z))
			return true
	return false


## One scan visit for a cell: dead cells zero out, living cover
## thickens, and lush cells occasionally seed a neighbour. The scan
## calls this per record on a rotating slice; tests drive it directly.
func _tick_cell(cell: Vector3i) -> void:
	var c := float(coverage.get(cell, 0.0))
	if c <= 0.0:
		return
	if not _eligible(cell):
		_set_cover(cell, 0.0)
		return
	if c < 1.0:
		var grown := minf(1.0, c + REGROW_STEP)
		_set_cover(cell, grown)
		c = grown
	if c >= SPREAD_MIN and randf() < SPREAD_CHANCE:
		spread_from(cell)


## Whether [param cell] can hold cover: a dirt block with open air —
## no block, building or packed pile — above it.
func _eligible(cell: Vector3i) -> bool:
	if world.get_block(cell) != Blocks.DIRT:
		return false
	var above := cell + Vector3i.UP
	if world.is_solid(above):
		return false
	if colony != null:
		if colony.building_at(above) != null:
			return false
		if colony.is_packed(above):
			return false
	return true


## A placed block covers the face it sits on — the grass under it dies
## the moment construction lands.
func _on_block_placed(position: Vector3i, _block_id: int) -> void:
	bare(position + Vector3i.DOWN)


## A mined or collapsed cell's cover dies with the block.
func _on_cell_lost(position: Vector3i, _block_id: int) -> void:
	bare(position)


## Seeded columns are discovered as their blocks stream in — the same
## restore pattern forest saplings and bushes use. A zeroed record or a
## pending column suppresses reseeding, so worn or built-over ground
## stays bare across reloads.
func _on_block_loaded(block_origin: Vector3i) -> void:
	var base := block_origin * 16
	var generator := world.generator_script
	# Sky and deep-rock blocks can't contain any column's surface — they
	# skip the sweep entirely; inside the band, only the block holding a
	# column's surface voxel pays for the seeding checks.
	if (
		base.y <= generator.max_surface_height()
		and base.y + 16 > generator.min_surface_height()
	):
		for rx in 16:
			for rz in 16:
				var col := generator.grass_column(base.x + rx, base.z + rz)
				if col.x >= base.y and col.x < base.y + 16:
					_try_seed(base.x + rx, base.z + rz, col)
	# A pending column is waiting on the cell above its surface — it
	# unblocks when a block covering its column loads, which this is.
	for column: Vector2i in _pending.keys():
		if (
			column.x >= base.x and column.x < base.x + 16
			and column.y >= base.z and column.y < base.z + 16
		):
			_try_seed(column.x, column.y)


## [param col] is the generator's grass_column answer for the column
## when the caller already paid for it — Vector2(surface_y, seed).
func _try_seed(x: int, z: int, col := Vector2(INF, INF)) -> void:
	var column := Vector2i(x, z)
	if col.x == INF:
		col = world.generator_script.grass_column(x, z)
	if col.y < 0.0:
		_pending.erase(column)
		return
	var cell := Vector3i(x, int(col.x), z)
	if coverage.has(cell):
		_pending.erase(column)
		return
	if not world.is_editable(cell) or not world.is_editable(cell + Vector3i.UP):
		_pending[column] = true
		return
	if not _eligible(cell):
		# Loaded and already changed — mined, built, buried. Bare it is.
		_pending.erase(column)
		return
	_set_cover(cell, col.y)
	_pending.erase(column)


## Records cover for [param cell], registering it under its column-chunk
## and flagging a rebuild only when the rendered band changes.
func _set_cover(cell: Vector3i, c: float) -> void:
	var chunk := _column_chunk(cell)
	_chunk_cells.get_or_add(chunk, {})[cell] = true
	if _band(float(coverage.get(cell, 0.0))) != _band(c):
		_dirty_chunks[chunk] = true
	coverage[cell] = c


func _column_chunk(cell: Vector3i) -> Vector2i:
	return Vector2i(cell.x >> 4, cell.z >> 4)


## The rotating scan: SCAN_SLICE records a tick, each visited cell
## validated and grown — plus a pass over columns still waiting to
## seed. Coverage records are never erased, so snapshot keys can't go
## stale mid-slice.
func _scan_tick() -> void:
	if _scan_pos >= _scan_keys.size():
		_scan_keys = coverage.keys()
		_scan_pos = 0
	var end := mini(_scan_pos + SCAN_SLICE, _scan_keys.size())
	for i in range(_scan_pos, end):
		_tick_cell(_scan_keys[i])
	_scan_pos = end
	for column: Vector2i in _pending.keys():
		_try_seed(column.x, column.y)


func _hash(cell: Vector3i, salt: int = 0) -> int:
	return hash(Vector4i(cell.x, cell.y, cell.z, salt)) & 0x7fffffff


## Coarse coverage bands — a rebuild only fires when a cell's rendered
## footprint actually changes size, not on every wear or regrow step.
func _band(c: float) -> int:
	return int(c * 4.0)


## Redraws the cover multimeshes of just the dirty column-chunks: one
## slab per living cell, footprint shrinking and colour drying out as
## coverage thins. No eligibility check here — dead cells are zeroed by
## the signals and the scan, so a stale slab lingers one scan cycle.
func _refresh_decorations() -> void:
	var chunks := _dirty_chunks.keys()
	for ci in mini(chunks.size(), REFRESH_MAX_CHUNKS):
		var chunk: Vector2i = chunks[ci]
		_dirty_chunks.erase(chunk)
		var cells: Array[Vector3i] = []
		for cell: Vector3i in _chunk_cells.get(chunk, {}):
			if float(coverage[cell]) > 0.0:
				cells.append(cell)
		var inst: MultiMeshInstance3D = _chunk_meshes.get(chunk)
		if inst == null:
			if cells.is_empty():
				continue
			inst = _make_decoration(_cover_mesh)
			_chunk_meshes[chunk] = inst
		var mm := inst.multimesh
		mm.instance_count = cells.size()
		for i in cells.size():
			var cell := cells[i]
			var c: float = coverage[cell]
			var s := 0.4 + 0.6 * c
			mm.set_instance_transform(
				i,
				Transform3D(
					Basis.from_scale(Vector3(s, 1.0, s)),
					Vector3(cell) + Vector3(0.5, 1.0 + COVER_THICK * 0.5, 0.5)
				)
			)
			mm.set_instance_color(
				i, Color(0.42, 0.38, 0.18).lerp(Color(0.30, 0.55, 0.22), c)
			)


## One multimesh drawing a decoration mesh once per tracked voxel —
## same construction the plants and forest decorations use.
func _make_decoration(mesh: Mesh) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.custom_aabb = AABB(
		Vector3(-8192, -512, -8192), Vector3(16384, 1024, 16384)
	)
	var instances := MultiMeshInstance3D.new()
	instances.multimesh = mm
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.9
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	instances.material_override = material
	instances.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instances)
	return instances


## Save records: every coverage entry including the zeroes — a 0 is a
## tombstone against reseeding, not an absence.
func serialize() -> Dictionary:
	var cells: Array = []
	for cell: Vector3i in coverage:
		cells.append([cell.x, cell.y, cell.z, coverage[cell]])
	return {"coverage": cells}


## Replaces live state wholesale — the colony clears before loading.
func deserialize(data: Dictionary) -> void:
	coverage.clear()
	_chunk_cells.clear()
	_dirty_chunks.clear()
	# Chunks with no surviving records still need a rebuild — their old
	# slabs are stale until redrawn empty.
	for chunk: Vector2i in _chunk_meshes:
		_dirty_chunks[chunk] = true
	for e: Array in data.get("coverage", []):
		var cell := Vector3i(int(e[0]), int(e[1]), int(e[2]))
		coverage[cell] = float(e[3])
		var cell_chunk := _column_chunk(cell)
		_chunk_cells.get_or_add(cell_chunk, {})[cell] = true
		_dirty_chunks[cell_chunk] = true
	_scan_keys = coverage.keys()
	_scan_pos = 0
	# Paint now: the dirty→refresh cadence exists to batch streaming
	# churn, but a load shouldn't sit bare waiting on ticks that a
	# paused game never runs.
	while not _dirty_chunks.is_empty():
		_refresh_decorations()
