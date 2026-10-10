class_name SliceView
extends Node3D

## Timberborn-style layer view: a world-space clip plane that discards
## every fragment above a y level, letting the player look into caves,
## buried rooms and anything under a roof. The cut is carried by one
## global shader parameter — every world material (terrain, water,
## decorations, piles) is built through the static factories here so the
## whole scene slices with a single `global_shader_parameter_set`.
##
## Hidden voxels still exist — they keep colliding and keep shading the
## cells beneath them out of the mesher's face list, which would leave
## the cut reading hollow. The cap mesh fixes that: one quad at the cut
## plane for every column whose voxel AT the level is solid — a
## cross-section floor plan of the layer, shaded darker than open faces.
## Cells open at the level get no cap: the real cave floors and walls
## below render through the gap instead.
##
## Controls (Overseer): PgDn lowers the cut a layer, PgUp raises it;
## raising back to the level where slicing began exits the view. While
## slicing, aim raycasts start where the ray crosses the plane so
## designations can only land on cells that actually render.

## Global shader parameter carrying the cut plane (world y). Materials
## discard fragments above it; far past terrain top means "slicing off".
const PARAM := "delve_slice_y"
## Off-value — comfortably above anything the generator emits.
const SLICE_OFF := 1.0e6

## Columns per cap tile side — matches the decoration column-chunks.
const TILE := 16
## Tile builds per frame at most — entering the view spreads the scan
## over frames rather than hitching once.
const MAX_REBUILDS := 48
## Cap tiles build only this far around the camera focus — the site
## field is far bigger than any viewport, so the cut scans what the
## player can actually see and follows them as they pan.
const CAP_RADIUS := 256
## The cap rides this far under the plane so a real top face emitted at
## the same spot (an open-air voxel at the level) wins the depth test.
const CAP_EPS := 0.02
## Cross-sections shade dimmer than natural faces so the flat plan
## doesn't read as surface terrain.
const CAP_DIM := 0.82

var _world: VoxelWorld
## Tile extents from the installed site — cap tiles seed lazily inside.
var _bounds: Rect2i
## tile Vector2i → MeshInstance3D
var _tiles: Dictionary = {}
var _pending: Dictionary = {}
## Tiles whose every column was loaded when built, at the CURRENT
## level — a level move clears the set so near tiles re-scan.
var _built: Dictionary = {}
## tile → process frame to retry — a cap tile that met unloaded
## columns stays unbuilt and requeues on a cooldown, so streaming-in
## terrain fills its holes instead of leaving permanent gaps.
var _retry_at: Dictionary = {}
## The node the cut follows — main assigns the Overseer.
var focus: Node3D
## Highest visible voxel y while slicing, -1 while the view is off.
var top_layer := -1
## The level the view opened at — raising the cut back to it exits.
var _home := -1

func _enter_tree() -> void:
	visible = false


## The cut parameter is a runtime global rather than a project-setting
## entry — the worldgen scene never slices, so the parameter only has
## to exist once a sliceable material is built.
static func ensure_global() -> void:
	if not RenderingServer.global_shader_parameter_get_list().has(PARAM):
		RenderingServer.global_shader_parameter_add(
			PARAM, RenderingServer.GLOBAL_VAR_TYPE_FLOAT, SLICE_OFF
		)


func is_active() -> bool:
	return top_layer >= 0


## The world-space plane height — the top of the highest visible voxel.
func plane() -> float:
	return float(top_layer) + 1.0


func install(field: SiteField, world: VoxelWorld) -> void:
	_world = world
	_bounds = Rect2i(
		field.origin, Vector2i.ONE * field.side * field.cell_m
	)
	if not world.block_edited.is_connected(_on_block_edited):
		world.block_edited.connect(_on_block_edited)


## Moves the cut. [param seed_level] is the voxel layer to open at —
## the ground under the camera focus. Lowering from off opens the view
## one layer under the seed; raising back to the seed closes it.
func adjust(direction: int, seed_level: int) -> void:
	if not is_active():
		if direction >= 0:
			return
		_home = seed_level
		_set_level(maxi(seed_level - 1, 0))
		return
	var next := top_layer + direction
	_set_level(next if next < _home else -1)


func _set_level(layer: int) -> void:
	top_layer = layer
	ensure_global()
	if layer < 0:
		RenderingServer.global_shader_parameter_set(PARAM, SLICE_OFF)
		visible = false
		_pending.clear()
		_retry_at.clear()
		return
	RenderingServer.global_shader_parameter_set(PARAM, float(layer) + 1.0)
	visible = true
	_retry_at.clear()
	# Every cap is stale at the new level — near tiles re-scan.
	_built.clear()


func _process(_delta: float) -> void:
	if not is_active() or _world == null:
		return
	# Keep the cut seeded around the focus, nearest tiles first — the
	# player reads the ground they're standing over before the horizon,
	# and a level move fills the centre before the rim.
	if focus != null:
		var frame := Engine.get_process_frames()
		var ft := Vector2i(
			floori(focus.global_position.x) >> 4,
			floori(focus.global_position.z) >> 4
		)
		var rt := ceili(CAP_RADIUS / float(TILE))
		var order: Array[Vector2i] = []
		for dz in range(-rt, rt + 1):
			for dx in range(-rt, rt + 1):
				var tile := Vector2i(ft.x + dx, ft.y + dz)
				# Outside the site the columns can never stream in —
				# don't burn rebuild budget on permanently empty tiles.
				if _bounds.intersects(
					Rect2i(tile.x * TILE, tile.y * TILE, TILE, TILE)
				):
					order.append(tile)
		order.sort_custom(
			func(a: Vector2i, b: Vector2i) -> bool:
				return a.distance_squared_to(ft) < b.distance_squared_to(ft)
		)
		for tile in order:
			if _built.has(tile) or _retry_at.get(tile, 0) > frame:
				continue
			_pending[tile] = true
	var built := 0
	for tile: Vector2i in _pending.keys():
		if built >= MAX_REBUILDS:
			break
		_pending.erase(tile)
		if _rebuild_tile(tile):
			_built[tile] = true
		built += 1


func _on_block_edited(voxel: Vector3i, _block_id: int) -> void:
	if is_active() and voxel.y == top_layer:
		var tile := Vector2i(voxel.x >> 4, voxel.z >> 4)
		_pending[tile] = true
		_built.erase(tile)


## Lays the cap quads of one 16×16 tile: the cut's cross-section through
## solid columns, nothing where the level is open. Returns false when
## columns weren't streamed yet — the tile stays unbuilt and requeues
## on a cooldown rather than freezing as a hole in the plan.
func _rebuild_tile(tile: Vector2i) -> bool:
	var inst: MeshInstance3D = _tiles.get(tile)
	if inst == null:
		inst = MeshInstance3D.new()
		inst.mesh = ArrayMesh.new()
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		inst.custom_aabb = AABB(
			Vector3(-8192, -512, -8192), Vector3(16384, 1024, 16384)
		)
		add_child(inst)
		_tiles[tile] = inst
	inst.position = Vector3(tile.x * TILE, 0, tile.y * TILE)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y := plane() - CAP_EPS
	var ox: int = tile.x * TILE
	var oz: int = tile.y * TILE
	var unloaded := false
	var quads := 0
	for dz in TILE:
		for dx in TILE:
			var pos := Vector3i(ox + dx, top_layer, oz + dz)
			if not _bounds.has_point(Vector2i(pos.x, pos.z)):
				# Beyond the site — counts as known-empty so an edge
				# tile can still complete.
				continue
			if not _world.is_editable(pos):
				# Not streamed yet — the tile stays unbuilt and the
				# cooldown requeues it until streaming catches up.
				unloaded = true
				continue
			var block_id: int = _world.get_block(pos)
			if block_id == BlockRegistry.Block.AIR:
				continue
			var color: Color = BlockRegistry.block_color(block_id) * CAP_DIM
			color.a = 1.0
			st.set_color(color)
			var a := Vector3(dx, y, dz)
			var b := Vector3(dx, y, dz + 1)
			var c := Vector3(dx + 1, y, dz + 1)
			var d := Vector3(dx + 1, y, dz)
			# CCW from above — the cap faces up.
			for v in [a, b, c, a, c, d]:
				st.set_normal(Vector3.UP)
				st.add_vertex(v)
			quads += 1
	inst.mesh.clear_surfaces()
	if quads > 0:
		st.index()
		st.commit(inst.mesh)
		inst.mesh.surface_set_material(0, _cap_mat())
	if unloaded:
		# ~30 frames between polls — streaming fills the tile in without
		# an edge of unloaded terrain burning a rebuild every frame.
		_retry_at[tile] = Engine.get_process_frames() + 30
		return false
	_retry_at.erase(tile)
	return true


## Opaque per-colour material — terrain blocks, packed piles. The
## loaded shaders ride the resource cache — nothing lives in statics.
static func opaque(color: Color) -> ShaderMaterial:
	ensure_global()
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/slice_opaque.gdshader")
	material.set_shader_parameter(&"albedo", color)
	return material


## Vertex-colour albedo — the decoration multimeshes carry their palette
## in the mesh (grass shades, leaf tones, floor coverings, cap quads).
static func vcolor() -> ShaderMaterial:
	ensure_global()
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/slice_vcolor.gdshader")
	return material


## The cap's own material — vertex colour like the decorations but
## unshadowed: a site-wide flat plane receiving sun shadows at grazing
## angles would grow acne speckle, and a cross-section reads better
## flat and diagrammatic anyway.
static func _cap_mat() -> ShaderMaterial:
	ensure_global()
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/slice_cap.gdshader")
	return material


## Translucent per-colour material — the water skin.
static func alpha(color: Color) -> ShaderMaterial:
	ensure_global()
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/slice_alpha.gdshader")
	material.set_shader_parameter(&"albedo", color)
	return material
