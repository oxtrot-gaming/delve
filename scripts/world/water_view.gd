class_name WaterView
extends Node3D

## The waterline made visible — a smoothed skin over every submerged
## voxel column, built as one mesh per tile: each top quad's corner
## heights are averaged across the four columns sharing the corner, so
## adjacent surfaces meet without gaps and a drainage gradient reads
## as a slope rather than a staircase. Skirts appear only at edges
## facing a dry or lower bank — never between water columns.
##
## Tiles re-lay from the sim's dirty-column stream, so a flood front,
## a pumped drain or a filling pit redraw at their footprint instead
## of re-laying the map. Column surfaces are fractional — the sim's
## cell fill fraction draws the sheet between voxel boundaries, which
## is also what a rising puddle needs to read as rising rather than
## stepping.

var _world: VoxelWorld
var _field: SiteField
## tile Vector2i → MeshInstance3D — created lazily, freed when the
## tile goes dry.
var _tiles: Dictionary = {}
## Tiles queued for rebuild — deduplicated so a burst of dirty columns
## in one tile costs one pass.
var _pending: Dictionary = {}

## Columns per tile side — matches the decoration column-chunks.
const TILE := 16
## Rebuilds per frame at most — a big flood spreads its redraw over
## frames rather than hitching once.
const MAX_REBUILDS := 48
## Draw the sheet this far under the surface top so a dry neighbour's
## top face at the same plane doesn't z-fight the skin.
const SKIN_EPS := 0.03

const _DIRS := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]


func install(field: SiteField, world: VoxelWorld) -> void:
	_field = field
	_world = world
	if not world.water_columns_changed.is_connected(_on_water_changed):
		world.water_columns_changed.connect(_on_water_changed)
	# Seed the tiles that hold water at install; everything else builds
	# itself the first time the sim dirties a column inside it.
	var first := {}
	for cz in field.side:
		for cx in field.side:
			if field.flood_cells[cz * field.side + cx] == 0:
				continue
			for dz in field.cell_m:
				for dx in field.cell_m:
					var wx: int = field.origin.x + cx * field.cell_m + dx
					var wz: int = field.origin.y + cz * field.cell_m + dz
					first[Vector2i(wx >> 4, wz >> 4)] = true
	for tile: Vector2i in first:
		_rebuild_tile(tile)
	# The seed dirty-marks every flooded column — the install pass just
	# laid them, so flush the backlog before the first refresh cycle
	# rebuilds the whole skin again.
	if _world.sim != null:
		_world.sim.water_drain_dirty()


func _on_water_changed(columns: PackedVector3Array) -> void:
	for c in columns:
		_pending[Vector2i(int(c.x) >> 4, int(c.z) >> 4)] = true


func _process(_delta: float) -> void:
	if _pending.is_empty():
		return
	var tiles := _pending.keys()
	for i in mini(tiles.size(), MAX_REBUILDS):
		var tile: Vector2i = tiles[i]
		_pending.erase(tile)
		_rebuild_tile(tile)


## Re-lays one tile's skin as a single smoothed mesh — top quads whose
## corner heights are averaged with the neighbouring columns, so a
## drainage gradient reads as a slope instead of a staircase, plus a
## skirt under edges facing a dry or lower bank. No skirts between
## wet columns: the shared corners keep the surface continuous.
func _rebuild_tile(tile: Vector2i) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bx := tile.x * TILE
	var bz := tile.y * TILE
	var corner_cache := {}
	for dz in TILE:
		for dx in TILE:
			var wx := bx + dx
			var wz := bz + dz
			var s := _world.water_surface_at(wx, wz)
			if s <= float(SiteField.DRY) + 1.0:
				continue
			var v00 := Vector3(
				wx, _corner(wx, wz, corner_cache) - SKIN_EPS, wz)
			var v10 := Vector3(
				wx + 1, _corner(wx + 1, wz, corner_cache) - SKIN_EPS,
				wz)
			var v01 := Vector3(
				wx, _corner(wx, wz + 1, corner_cache) - SKIN_EPS,
				wz + 1)
			var v11 := Vector3(
				wx + 1, _corner(wx + 1, wz + 1, corner_cache) - SKIN_EPS,
				wz + 1)
			_tri(st, v00, v11, v10)
			_tri(st, v00, v01, v11)
			_skirt(st, wx, wz, v00, v10, v01, v11)
	st.generate_normals()
	_set_tile(st.commit(), tile)


func _set_tile(mesh: ArrayMesh, tile: Vector2i) -> void:
	var inst: MeshInstance3D = _tiles.get(tile)
	if mesh == null or mesh.get_surface_count() == 0:
		if inst != null:
			inst.queue_free()
			_tiles.erase(tile)
		return
	if inst == null:
		inst = MeshInstance3D.new()
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		inst.material_override = _water_mat()
		add_child(inst)
		_tiles[tile] = inst
	inst.mesh = mesh


## Smoothed height for a corner shared by up to four columns: the mean
## of the wet surfaces, with dry banks contributing their own top
## (sunk a little, and never above the water mean) — a shoreline
## bevel, not a cliff climb.
func _corner(cx: int, cz: int, cache: Dictionary) -> float:
	var key := Vector2i(cx, cz)
	if cache.has(key):
		return cache[key]
	var wet_sum := 0.0
	var wet_n := 0
	var dry_low := INF
	for dx: int in [0, -1]:
		for dz: int in [0, -1]:
			var s := _world.water_surface_at(cx + dx, cz + dz)
			if s > float(SiteField.DRY) + 1.0:
				wet_sum += s
				wet_n += 1
			else:
				var top := float(
					_world.generator_script.terrain_height(
						cx + dx, cz + dz)
					+ 1) - 0.05
				dry_low = minf(dry_low, top)
	var h: float
	if wet_n == 0:
		h = dry_low
	else:
		var wet_mean := wet_sum / wet_n
		h = (wet_sum + minf(dry_low, wet_mean) * (4 - wet_n)) / 4.0
	cache[key] = h
	return h


## A side quad only where an edge faces a dry neighbour lower than the
## smoothed sheet edge — wet neighbours need none, since the shared
## corner heights keep the surface continuous, and a bank whose top
## reaches the sheet edge swallows it outright (no more z-fighting a
## coplanar cliff face).
func _skirt(
	st: SurfaceTool, wx: int, wz: int,
	v00: Vector3, v10: Vector3, v01: Vector3, v11: Vector3
) -> void:
	var bed := float(_world.generator_script.terrain_height(wx, wz) + 1)
	for d: Vector3i in _DIRS:
		var nx: int = wx + d.x
		var nz: int = wz + d.z
		var ns := _world.water_surface_at(nx, nz)
		if ns > float(SiteField.DRY) + 1.0:
			continue # shared body — the smoothed top covers the seam
		var ntop := float(
			_world.generator_script.terrain_height(nx, nz) + 1)
		var a: Vector3
		var b: Vector3
		match d:
			Vector3i(1, 0, 0):
				a = v10; b = v11
			Vector3i(-1, 0, 0):
				a = v01; b = v00
			Vector3i(0, 0, 1):
				a = v11; b = v01
			_:
				a = v00; b = v10
		var edge := minf(a.y, b.y)
		if ntop >= edge:
			continue # buried inside the bank
		var bottom := minf(bed, ntop)
		if edge - bottom < 0.05:
			continue
		var ab := Vector3(a.x, bottom, a.z)
		var bb := Vector3(b.x, bottom, b.z)
		_tri(st, a, b, bb)
		_tri(st, a, bb, ab)


static var _mat: ShaderMaterial


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)


func _water_mat() -> ShaderMaterial:
	if _mat == null:
		_mat = SliceView.alpha(Color(0.16, 0.34, 0.52, 0.6))
	return _mat
