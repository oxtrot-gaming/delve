class_name WaterView
extends Node3D

## The waterline made visible — a skin over every submerged voxel
## column plus a skirt wall wherever a neighbouring column's surface
## sits lower or its bank swallows the edge.
##
## The skin tiles at voxel granularity and lives on per-tile
## multimeshes: the sim's dirty-column stream re-lays only the tiles
## that moved, so a flood front, a pumped drain or a filling pit redraw
## at their footprint instead of re-laying the map. Column surfaces are
## fractional — the sim's cell fill fraction draws the sheet between
## voxel boundaries, which is also what a rising puddle needs to read
## as rising rather than stepping.

var _world: VoxelWorld
var _field: SiteField
## tile Vector2i → {tops: MultiMeshInstance3D, sides: ...} — created
## lazily, freed when the tile goes dry.
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


## Re-lays one tile's skin from the live waterline — top quads at the
## fractional surface plus side skirts on every lower neighbour edge.
func _rebuild_tile(tile: Vector2i) -> void:
	var tops := PackedVector3Array()
	var sides: Array[Transform3D] = []
	var bx := tile.x * TILE
	var bz := tile.y * TILE
	for dz in TILE:
		for dx in TILE:
			var wx := bx + dx
			var wz := bz + dz
			var s := _world.water_surface_at(wx, wz)
			if s <= float(SiteField.DRY) + 1.0:
				continue
			var py := s - SKIN_EPS
			tops.append(Vector3(wx + 0.5, py, wz + 0.5))
			_skirt(sides, wx, wz, py)
	_set_tile(tops, sides, tile)


func _set_tile(
	tops: PackedVector3Array, sides: Array[Transform3D], tile: Vector2i
) -> void:
	var insts: Dictionary = _tiles.get(tile, {})
	if tops.is_empty() and sides.is_empty():
		if insts.has(&"tops"):
			insts[&"tops"].queue_free()
			insts[&"sides"].queue_free()
			_tiles.erase(tile)
		return
	if insts.is_empty():
		insts = {
			&"tops": _make_multimesh(_top_mesh()),
			&"sides": _make_multimesh(_side_mesh()),
		}
		add_child(insts[&"tops"])
		add_child(insts[&"sides"])
		_tiles[tile] = insts
	_fill(insts[&"tops"].multimesh, tops)
	_fill_sides(insts[&"sides"].multimesh, sides)


## Emits a side quad on each edge whose neighbour has no water at this
## surface — down to the lower of this column's bed or the neighbour's
## own surface, so basins and rivers read as water volumes, not
## floating sheets. A dry bank above the surface swallows its own
## skirt.
func _skirt(
	sides: Array[Transform3D], vx: int, vz: int, surface: float
) -> void:
	var bed := float(_world.generator_script.terrain_height(vx, vz) + 1)
	var w := _world.water_surface_at(vx, vz)
	for d in _DIRS:
		var nx: int = vx + d.x
		var nz: int = vz + d.z
		var ns := _world.water_surface_at(nx, nz)
		var nl := int(ns) if ns > float(SiteField.DRY) + 1.0 else SiteField.DRY
		if nl != SiteField.DRY and ns >= w:
			continue # same or higher water — shared body, no wall
		var bottom := bed
		if nl != SiteField.DRY:
			bottom = minf(bed, ns + SKIN_EPS)
		else:
			var ntop := float(
				_world.generator_script.terrain_height(nx, nz) + 1
			)
			if ntop >= surface:
				continue # buried inside the bank
			bottom = minf(bottom, ntop)
		var h := surface - bottom
		if h < 0.05:
			continue
		# QuadMesh faces +Z with width along X; rotate so the normal
		# points outward across the shared edge.
		var theta := atan2(float(d.x), float(d.z))
		var basis := Basis(Vector3.UP, theta).scaled(Vector3(1.0, h, 1.0))
		var centre := Vector3(
			vx + 0.5 + d.x * 0.5, bottom + h * 0.5, vz + 0.5 + d.z * 0.5
		)
		sides.append(Transform3D(basis, centre))


static var _mat: StandardMaterial3D


func _top_mesh() -> Mesh:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2.ONE
	mesh.material = _water_mat()
	return mesh


func _side_mesh() -> Mesh:
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE
	mesh.material = _water_mat()
	return mesh


func _water_mat() -> StandardMaterial3D:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.albedo_color = Color(0.16, 0.34, 0.52, 0.6)
		_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _mat


func _make_multimesh(mesh: Mesh) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	var multimesh := MultiMesh.new()
	multimesh.mesh = mesh
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi.multimesh = multimesh
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mmi


func _fill(multimesh: MultiMesh, spots: PackedVector3Array) -> void:
	multimesh.instance_count = spots.size()
	for k in spots.size():
		multimesh.set_instance_transform(
			k, Transform3D(Basis(), spots[k])
		)


func _fill_sides(multimesh: MultiMesh, sides: Array[Transform3D]) -> void:
	multimesh.instance_count = sides.size()
	for k in sides.size():
		multimesh.set_instance_transform(k, sides[k])
