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

var _instances: MultiMeshInstance3D
var _decorations_dirty := false
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
## Thickness of the ground-cover slab on a grassed top face.
const COVER_THICK := 0.06

const SIDES: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)
]


func setup(p_world: VoxelWorld, p_colony: Colony) -> void:
	world = p_world
	colony = p_colony
	var cover := BoxMesh.new()
	cover.size = Vector3(0.96, COVER_THICK, 0.96)
	_instances = _make_decoration(cover)
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
	if _decorations_dirty and _refresh_elapsed >= REFRESH_MIN_SEC:
		_refresh_elapsed = 0.0
		_refresh_decorations()


## Cover at [param cell] right now — lazily validates, so a cell whose
## block went away or got covered reads bare.
func coverage_at(cell: Vector3i) -> float:
	var c := float(coverage.get(cell, 0.0))
	if c <= 0.0:
		return 0.0
	if not _eligible(cell):
		coverage[cell] = 0.0
		_decorations_dirty = true
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
	var worn := maxf(0.0, c - TRAMPLE_WEAR)
	coverage[cell] = worn
	if _band(c) != _band(worn):
		_decorations_dirty = true


## Strips a cell bare — construction buries the grass under it.
func bare(cell: Vector3i) -> void:
	if float(coverage.get(cell, 0.0)) > 0.0:
		coverage[cell] = 0.0
		_decorations_dirty = true


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
			coverage[n] = SPREAD_START
			_pending.erase(Vector2i(n.x, n.z))
			_decorations_dirty = true
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
		coverage[cell] = 0.0
		_decorations_dirty = true
		return
	if c < 1.0:
		var grown := minf(1.0, c + REGROW_STEP)
		coverage[cell] = grown
		if _band(c) != _band(grown):
			_decorations_dirty = true
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
	for rx in 16:
		for rz in 16:
			_try_seed(base.x + rx, base.z + rz)
	for column: Vector2i in _pending.keys():
		_try_seed(column.x, column.y)


func _try_seed(x: int, z: int) -> void:
	var column := Vector2i(x, z)
	var generator := world.generator_script
	var seed := generator.grass_seed_at(x, z)
	if seed < 0.0:
		_pending.erase(column)
		return
	var cell := Vector3i(x, generator.surface_height(x, z), z)
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
	coverage[cell] = seed
	_pending.erase(column)
	_decorations_dirty = true


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


## Redraws the cover multimesh: one slab per living cell, footprint
## shrinking and colour drying out as coverage thins. No eligibility
## check here — dead cells are zeroed by the signals and the scan, so
## a stale slab can only linger for one scan cycle.
func _refresh_decorations() -> void:
	_decorations_dirty = false
	var cells: Array[Vector3i] = []
	for cell: Vector3i in coverage:
		if float(coverage[cell]) > 0.0:
			cells.append(cell)
	var mm := _instances.multimesh
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
