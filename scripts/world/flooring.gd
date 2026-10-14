class_name Flooring
extends Node

## Surface coverings as a decoration layer — the grass model applied to
## every exposed block face, not just ground tops. A covered face is a
## thin quad riding the air cell that sees it: the solid block behind
## stays plain terrain, and only this layer knows it's flagged or
## planked. Covers work on any of a cell's six faces — paving underfoot,
## plaster on a wall, a ceiling board — keyed (open cell, face index
## into [constant FACE_DIRS]) where the direction points from the open
## cell at the block it dresses.
##
## A cover dies two ways: the air cell fills (a block placed into it
## buries every face) or its backing block goes away (mined or
## collapsed — a covering hangs on the block it dresses, not the air).
## Records persist through colony serialize; there is no reseeding —
## flooring only exists where a job put it.

var world: VoxelWorld
var colony: Colony

## The six face directions a covering can dress, indexed by the low
## bits of a face key. The direction points from the open cell at the
## block it dresses — DOWN is the floor underfoot, UP the ceiling
## overhead, the four laterals the walls around the cell.
const FACE_DIRS: Array[Vector3i] = [
	Vector3i(0, -1, 0), Vector3i(0, 1, 0),
	Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
	Vector3i(0, 0, -1), Vector3i(0, 0, 1),
]

## The face index of a direction — its slot in [constant FACE_DIRS],
## or -1 when [param dir] isn't an axis step.
static func face_index(dir: Vector3i) -> int:
	return FACE_DIRS.find(dir)


## open cell → {face index → spec key}. A cell entry with no faces is
## erased outright — no tombstones here, nothing reseeds.
var covers: Dictionary = {}

## Column-chunk (16×16 x/z window) → the multimesh drawing that chunk's
## face quads — the grass chunking so a repaint is bounded.
var _chunk_meshes: Dictionary = {}
## Column-chunk → {cell: true}: which cells each chunk draws faces for.
var _chunk_cells: Dictionary = {}
var _dirty_chunks: Dictionary = {}
var _face_mesh: QuadMesh
var _refresh_elapsed := 0.0

## Slowest allowed decoration rebuild — covering edits batch into these.
const REFRESH_MIN_SEC := 0.75
## Most column-chunks rebuilt per refresh — leftovers stay dirty until
## their turn, same bargain grass strikes.
const REFRESH_MAX_CHUNKS := 48
## How far into the air cell a covering quad floats — enough to clear
## z-fighting with the block face it dresses.
const FACE_EPSILON := 0.02


func setup(p_world: VoxelWorld, p_colony: Colony) -> void:
	world = p_world
	colony = p_colony
	_face_mesh = QuadMesh.new()
	_face_mesh.size = Vector2(0.96, 0.96)
	_face_mesh.orientation = QuadMesh.FACE_Z
	world.block_placed.connect(_on_block_placed)
	world.block_mined.connect(_on_cell_lost)
	world.block_collapsed.connect(_on_cell_lost)
	# remove_voxel (teardowns, felling) emits only block_edited —
	# re-validate the six faces around the edited cell so a stripped
	# backing drops its covering instead of leaving a floating quad.
	world.block_edited.connect(_on_cell_edited)


func _process(delta: float) -> void:
	if world == null:
		return
	_refresh_elapsed += delta
	if not _dirty_chunks.is_empty() and _refresh_elapsed >= REFRESH_MIN_SEC:
		_refresh_elapsed = 0.0
		_refresh_decorations()


## The covering spec on [param cell]'s [param face]-ward face, or &"" —
## lazily validates: a face whose air cell filled or whose backing
## block vanished reads bare.
func covering_at(cell: Vector3i, face: int) -> StringName:
	var faces: Dictionary = covers.get(cell, {})
	var spec: StringName = faces.get(face, &"")
	if spec == &"":
		return &""
	if not _has_backing(cell, face):
		_strip_face(cell, face)
		return &""
	return spec


## Whether [param face] of [param cell] can take a covering: the cell
## must be open air and the block the face dresses solid.
func coverable(cell: Vector3i, face: int) -> bool:
	if covering_at(cell, face) != &"":
		return false
	if not world.is_editable(cell):
		return false
	if world.get_block(cell) != BlockRegistry.Block.AIR:
		return false
	return _has_backing(cell, face)


## Lays [param spec] on [param cell]'s [param face]-ward face. The job
## validates at designation, but the world can shift under a pending
## plan — a missing backing or a filled cell refuses the lay and the
## caller decides what the escrowed material does.
func lay(cell: Vector3i, face: int, spec: StringName) -> bool:
	if not coverable(cell, face):
		return false
	var faces: Dictionary = covers.get_or_add(cell, {})
	faces[face] = spec
	_chunk_cells.get_or_add(_column_chunk(cell), {})[cell] = true
	_dirty_chunks[_column_chunk(cell)] = true
	if colony != null and colony.rooms != null:
		colony.rooms.invalidate_beauty()
	_push_floor_cost(cell)
	return true


## Strips whatever covers [param cell]'s [param face]-ward face —
## removal recovers nothing: the material was trowelled thin, scraped
## off it's scrap. Returns the spec that came off, &"" if bare.
func strip(cell: Vector3i, face: int) -> StringName:
	var spec := covering_at(cell, face)
	if spec == &"":
		return &""
	_strip_face(cell, face)
	return spec


## The beauty a face presents to a viewer in [param cell]: the
## covering's value when laid, else the backing block's own — with a
## grassed ground face reading the sod's, not the dirt's.
func face_beauty(cell: Vector3i, face: int) -> float:
	var spec := covering_at(cell, face)
	if spec != &"":
		return BlockRegistry.floor_beauty(spec)
	var backing := cell + FACE_DIRS[face]
	if (
		face == 0 and colony != null and colony.grass != null
		and colony.grass.grassed(backing)
	):
		return BlockRegistry.block_beauty(BlockRegistry.Block.GRASS)
	return BlockRegistry.block_beauty(world.get_block(backing))


## Every covering whose cell sits inside the (inclusive) box — for the
## sight-line sampler. Rows are [cell, face index].
func covers_within(lo: Vector3i, hi: Vector3i) -> Array:
	var found: Array = []
	for cell: Vector3i in covers:
		if (
			cell.x < lo.x or cell.x > hi.x or cell.y < lo.y
			or cell.y > hi.y or cell.z < lo.z or cell.z > hi.z
		):
			continue
		for face: int in covers[cell]:
			found.append([cell, face])
	return found


## A block placed into [param cell] buries every covering the open cell
## carried.
func _on_block_placed(cell: Vector3i, _block_id: int) -> void:
	if covers.has(cell):
		_clear_cell(cell)


## A mined or collapsed block drops the coverings that dressed it —
## they're recorded on the open cells whose faces pointed at it.
func _on_cell_lost(cell: Vector3i, _block_id: int) -> void:
	for face in FACE_DIRS.size():
		var open_cell := cell - FACE_DIRS[face]
		var faces: Dictionary = covers.get(open_cell, {})
		if faces.has(face):
			_strip_face(open_cell, face)


## The catch-all edit: silently-removed blocks (wall teardowns, tree
## felling) skip the mined/collapsed signals, so re-validate the faces
## that dressed the cell — and the cell's own covers if it filled.
func _on_cell_edited(cell: Vector3i, _block_id: int) -> void:
	if covers.has(cell) and world.is_solid(cell):
		_clear_cell(cell)
	for face in FACE_DIRS.size():
		var open_cell := cell - FACE_DIRS[face]
		var faces: Dictionary = covers.get(open_cell, {})
		if faces.has(face):
			# covering_at validates the backing lazily.
			covering_at(open_cell, face)


func _has_backing(cell: Vector3i, face: int) -> bool:
	return world.is_solid(cell + FACE_DIRS[face])


func _strip_face(cell: Vector3i, face: int) -> void:
	var faces: Dictionary = covers.get(cell, {})
	faces.erase(face)
	if faces.is_empty():
		covers.erase(cell)
	else:
		covers[cell] = faces
	_dirty_chunks[_column_chunk(cell)] = true
	if colony != null and colony.rooms != null:
		colony.rooms.invalidate_beauty()
	_push_floor_cost(cell)


func _clear_cell(cell: Vector3i) -> void:
	covers.erase(cell)
	_dirty_chunks[_column_chunk(cell)] = true
	if colony != null and colony.rooms != null:
		colony.rooms.invalidate_beauty()
	_push_floor_cost(cell)


## Pushes the cell's walk cost into the sim — the underfoot covering's
## 1/speed discount, mirrored like the door's swing cost so paths
## price paved ground cheaper. Wall and ceiling covers don't read.
func _push_floor_cost(cell: Vector3i) -> void:
	if world == null or world.sim == null:
		return
	var faces: Dictionary = covers.get(cell, {})
	var spec: StringName = faces.get(0, &"")
	world.sim.set_floor(
		cell, 1.0 / maxf(0.05, BlockRegistry.floor_speed(spec))
	)


func _column_chunk(cell: Vector3i) -> Vector2i:
	return Vector2i(cell.x >> 4, cell.z >> 4)


## The quad transform for [param face] of [param cell]: flat against
## the face, nudged into the open cell so it clears the block behind.
func _face_transform(cell: Vector3i, face: int) -> Transform3D:
	var dir := Vector3(FACE_DIRS[face])
	# +Z of the quad must aim into the open cell — opposite the stored
	# face direction, which points at the backing block.
	var basis := Basis.looking_at(dir, Vector3.FORWARD if absf(dir.y) > 0.9 else Vector3.UP)
	var origin := (
		Vector3(cell) + Vector3.ONE * 0.5
		+ dir * (0.5 - FACE_EPSILON)
	)
	return Transform3D(basis, origin)


## Redraws the covering multimeshes of just the dirty column-chunks:
## one quad per covered face, tinted by spec.
func _refresh_decorations() -> void:
	var chunks := _dirty_chunks.keys()
	for ci in mini(chunks.size(), REFRESH_MAX_CHUNKS):
		var chunk: Vector2i = chunks[ci]
		_dirty_chunks.erase(chunk)
		var faces: Array = []
		for cell: Vector3i in _chunk_cells.get(chunk, {}):
			var cell_faces: Dictionary = covers.get(cell, {})
			for face: int in cell_faces:
				faces.append([cell, face])
		var inst: MultiMeshInstance3D = _chunk_meshes.get(chunk)
		if inst == null:
			if faces.is_empty():
				continue
			inst = _make_decoration(_face_mesh)
			_chunk_meshes[chunk] = inst
		var mm := inst.multimesh
		mm.instance_count = faces.size()
		for i in faces.size():
			var cell: Vector3i = faces[i][0]
			var face: int = faces[i][1]
			mm.set_instance_transform(i, _face_transform(cell, face))
			mm.set_instance_color(
				i, BlockRegistry.floor_color(covers[cell][face])
			)


## One multimesh drawing a decoration mesh — same construction the
## grass and plant decorations use.
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
	instances.material_override = SliceView.vcolor()
	instances.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instances)
	return instances


## Save records: one row per covered face — [x, y, z, face, spec].
func serialize() -> Dictionary:
	var entries: Array = []
	for cell: Vector3i in covers:
		for face: int in covers[cell]:
			var spec: StringName = covers[cell][face]
			entries.append([cell.x, cell.y, cell.z, face, String(spec)])
	return {"covers": entries}


## Replaces live state wholesale — the colony clears before loading.
func deserialize(data: Dictionary) -> void:
	covers.clear()
	_chunk_cells.clear()
	_dirty_chunks.clear()
	for chunk: Vector2i in _chunk_meshes:
		_dirty_chunks[chunk] = true
	for e: Array in data.get("covers", []):
		var cell := Vector3i(int(e[0]), int(e[1]), int(e[2]))
		var face := int(e[3])
		var spec := StringName(e[4])
		var faces: Dictionary = covers.get_or_add(cell, {})
		faces[face] = spec
		var chunk := _column_chunk(cell)
		_chunk_cells.get_or_add(chunk, {})[cell] = true
		_dirty_chunks[chunk] = true
		_push_floor_cost(cell)
	# Paint now, same deal as grass: a paused game never runs the ticks.
	while not _dirty_chunks.is_empty():
		_refresh_decorations()
